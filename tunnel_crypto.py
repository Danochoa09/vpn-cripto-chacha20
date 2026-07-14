"""Cifrado del túnel: ChaCha20-Poly1305 (AEAD) con anti-replay.

Cada datagrama que cruza la red es:  [8 bytes contador][ciphertext + tag(16B)]

Diseño (igual que WireGuard):

  - AEAD ChaCha20-Poly1305: confidencialidad + autenticación. Alterar un bit
    del contador, del ciphertext o del tag hace fallar el descifrado.

  - Nonce = 4 bytes 0 + contador de 64 bits (little-endian). El contador es
    monótono y único por emisor, así que el nonce NUNCA se repite. Mejor que
    un nonce aleatorio: cero riesgo de colisión.

  - Una clave por sentido (cliente->servidor y servidor->cliente), derivadas
    de la clave compartida con HKDF. Necesario porque ambos extremos empiezan
    el contador en 0: con una sola clave producirían el mismo nonce en el
    primer paquete = reuso catastrófico. Con claves distintas, cada (clave,
    contador) es único.

  - Anti-replay: el receptor lleva una ventana deslizante de los contadores
    ya vistos (RFC 6479). Un datagrama repetido o demasiado viejo se rechaza.
    La verificación de replay se hace DESPUÉS de autenticar, para que un
    atacante no pueda envenenar la ventana con contadores falsos.
"""

from cryptography.exceptions import InvalidTag  # re-exportado
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

COUNTER_SIZE = 8   # 64 bits en el datagrama
TAG_SIZE = 16      # Poly1305
WINDOW_SIZE = 64   # ventana anti-replay
_MAX_COUNTER = 1 << 64

# Clave compartida de demo. Cliente y servidor DEBEN tener la misma.
# En producción se negocia (X25519); aquí va fija por simplicidad.
KEY = bytes.fromhex(
    "603deb1015ca71be2b73aef0857d7781"
    "1f352c073b6108d72d9810a30914dff4"
)


def _derive(info: bytes) -> bytes:
    """Subclave de 32 bytes a partir de la clave compartida (HKDF-SHA256)."""
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=None,
                info=info).derive(KEY)


_KEY_C2S = _derive(b"cripto-vpn cliente->servidor")
_KEY_S2C = _derive(b"cripto-vpn servidor->cliente")


class ReplayError(Exception):
    """Contador repetido o fuera de la ventana anti-replay."""


class _ReplayWindow:
    """Ventana deslizante de contadores vistos (RFC 6479, bitmap)."""

    def __init__(self, size: int = WINDOW_SIZE):
        self._size = size
        self._mask = (1 << size) - 1
        self._highest = -1
        self._bitmap = 0  # bit i => se vio el contador (highest - i)

    def check_and_update(self, seq: int) -> bool:
        if seq < 0:
            return False
        if self._highest < 0:                       # primer paquete
            self._highest, self._bitmap = seq, 1
            return True
        if seq > self._highest:                     # más nuevo: desplazar
            shift = seq - self._highest
            if shift >= self._size:
                self._bitmap = 1
            else:
                self._bitmap = ((self._bitmap << shift) | 1) & self._mask
            self._highest = seq
            return True
        offset = self._highest - seq                # dentro o detrás de la ventana
        if offset >= self._size:
            return False                            # demasiado viejo
        bit = 1 << offset
        if self._bitmap & bit:
            return False                            # ya visto = replay
        self._bitmap |= bit
        return True


class Tunnel:
    """Estado criptográfico de un extremo del túnel.

    role="client" cifra con la clave c->s y descifra con la s->c;
    role="server" al revés. El contador de envío y la ventana de recepción
    tocan estados distintos, así que un hilo emisor y uno receptor pueden
    usar el mismo Tunnel sin locks.
    """

    def __init__(self, role: str):
        if role == "client":
            send_key, recv_key = _KEY_C2S, _KEY_S2C
        elif role == "server":
            send_key, recv_key = _KEY_S2C, _KEY_C2S
        else:
            raise ValueError("role debe ser 'client' o 'server'")
        self._send = ChaCha20Poly1305(send_key)
        self._recv = ChaCha20Poly1305(recv_key)
        self._send_counter = 0
        self._window = _ReplayWindow()

    def seal(self, packet: bytes) -> bytes:
        """Cifra+autentica un paquete y antepone el contador. Listo para UDP."""
        counter = self._send_counter
        if counter >= _MAX_COUNTER:
            raise OverflowError("contador agotado; hay que renegociar la clave")
        self._send_counter += 1
        nonce = b"\x00\x00\x00\x00" + counter.to_bytes(COUNTER_SIZE, "little")
        ciphertext = self._send.encrypt(nonce, packet, None)
        return counter.to_bytes(COUNTER_SIZE, "little") + ciphertext

    def open_(self, datagram: bytes) -> bytes:
        """Verifica tag, descifra y comprueba anti-replay. Devuelve el paquete.

        Lanza InvalidTag si el datagrama fue alterado/no es auténtico, o
        ReplayError si el contador ya se había visto o es demasiado viejo.
        """
        counter_bytes = datagram[:COUNTER_SIZE]
        counter = int.from_bytes(counter_bytes, "little")
        nonce = b"\x00\x00\x00\x00" + counter_bytes
        packet = self._recv.decrypt(nonce, datagram[COUNTER_SIZE:], None)
        # Solo tras autenticar comprobamos replay (evita envenenar la ventana).
        if not self._window.check_and_update(counter):
            raise ReplayError(f"contador {counter} repetido o fuera de ventana")
        return packet


__all__ = ["Tunnel", "InvalidTag", "ReplayError",
           "COUNTER_SIZE", "TAG_SIZE", "WINDOW_SIZE", "KEY"]
