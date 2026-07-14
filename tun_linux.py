"""Interfaz TUN para Linux (/dev/net/tun).

Equivalente de `tun_wintun.py` pero para el servidor Linux de la VM. Misma
API (context manager con read()/write()) para que `vpn_server_linux.py`
funcione igual que el de Windows.

Un dispositivo TUN entrega/recibe paquetes IP (capa 3). Lo que se lee son
paquetes que el kernel quiere enviar por esa interfaz; lo que se escribe se
inyecta como si hubiera llegado.

Requiere Linux y privilegios (root / CAP_NET_ADMIN).
"""

import fcntl
import os
import struct

# Constantes del ioctl de TUN (linux/if_tun.h)
_TUNSETIFF = 0x400454CA
_IFF_TUN = 0x0001      # modo TUN (capa 3, sin cabecera Ethernet)
_IFF_NO_PI = 0x1000    # sin los 4 bytes de "packet information" por paquete


class TunAdapter:
    """Dispositivo TUN de Linux. Usar como context manager."""

    def __init__(self, name: str = "criptovpn"):
        self._name = name
        self._fd = None

    def __enter__(self) -> "TunAdapter":
        self._fd = os.open("/dev/net/tun", os.O_RDWR)
        # Nombre de interfaz (máx 16 bytes) + flags
        ifr = struct.pack("16sH", self._name.encode("ascii"),
                          _IFF_TUN | _IFF_NO_PI)
        fcntl.ioctl(self._fd, _TUNSETIFF, ifr)
        return self

    def __exit__(self, *exc) -> None:
        if self._fd is not None:
            os.close(self._fd)

    def read(self, timeout_ms: int = -1) -> bytes | None:
        """Siguiente paquete IP saliente. timeout_ms<0 = bloquear siempre."""
        if timeout_ms is not None and timeout_ms >= 0:
            import select
            r, _, _ = select.select([self._fd], [], [], timeout_ms / 1000)
            if not r:
                return None
        return os.read(self._fd, 65535)

    def write(self, packet: bytes) -> None:
        """Inyecta un paquete IP en la interfaz."""
        os.write(self._fd, packet)


if __name__ == "__main__":
    # Prueba: crea la interfaz y lee un paquete. Necesita root y que asignes
    # una IP en otra terminal (ip addr add ... ; ip link set criptovpn up).
    print("Creando TUN 'criptovpn' ...")
    with TunAdapter() as tun:
        print("OK. Asigna IP y genera tráfico para ver un paquete.")
        pkt = tun.read(timeout_ms=15000)
        print(f"Leído: {len(pkt)} bytes" if pkt else "Sin tráfico en 15 s.")
