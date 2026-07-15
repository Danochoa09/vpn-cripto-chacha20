"""Servidor VPN (portátil que comparte internet).

Dos hilos sobre una misma interfaz TUN y un socket UDP:

  UP   : recibe datagramas UDP del cliente -> descifra -> escribe en TUN.
         El sistema (con NAT+forwarding) los enruta hacia internet.
  DOWN : lee paquetes de la TUN (respuestas de internet hacia el cliente)
         -> cifra -> envía por UDP al cliente.

Aprende la dirección UDP del cliente del primer datagrama recibido.

Uso (Administrador):
    python vpn_server.py
Antes hay que crear/configurar el adaptador y el NAT: ver setup_server.ps1.
"""

import socket
import threading

from tun_wintun import TunAdapter
from tunnel_crypto import Tunnel, InvalidTag, ReplayError

LISTEN_ADDR = ("0.0.0.0", 51820)  # puerto UDP del túnel


class Peer:
    """Dirección UDP del cliente, compartida entre hilos."""
    def __init__(self):
        self.addr = None
        self.lock = threading.Lock()

    def set(self, addr):
        with self.lock:
            if self.addr != addr:
                print(f"[SERVIDOR] Cliente en {addr[0]}:{addr[1]}")
            self.addr = addr

    def get(self):
        with self.lock:
            return self.addr


def up_loop(sock: socket.socket, tun: TunAdapter, peer: Peer,
            tunnel: Tunnel) -> None:
    while True:
        datagram, addr = sock.recvfrom(65535)
        try:
            packet = tunnel.open_(datagram)  # tag + descifrado + anti-replay
        except InvalidTag:
            print(f"[SERVIDOR] paquete alterado/ajeno descartado de {addr[0]}")
            continue
        except ReplayError:
            print(f"[SERVIDOR] replay descartado de {addr[0]}")
            continue
        # Solo tras autenticar aprendemos la dirección del cliente: si no,
        # cualquier UDP ajeno al puerto redirigiría el tráfico de bajada.
        peer.set(addr)
        # Un paquete IP válido mide >= 20 bytes (encabezado IPv4). Los
        # keepalive del cliente (1 byte) caen aquí y se ignoran.
        if len(packet) < 20:
            continue
        tun.write(packet)


def down_loop(sock: socket.socket, tun: TunAdapter, peer: Peer,
              tunnel: Tunnel) -> None:
    while True:
        packet = tun.read()
        if packet is None:
            continue
        addr = peer.get()
        if addr is None:
            continue  # aún no sabemos a quién responder
        sock.sendto(tunnel.seal(packet), addr)


def main() -> None:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(LISTEN_ADDR)
    print(f"[SERVIDOR] Túnel UDP escuchando en {LISTEN_ADDR[1]}")

    peer = Peer()
    tunnel = Tunnel(role="server")
    with TunAdapter(name="CriptoVPN") as tun:
        print(f"[SERVIDOR] TUN lista (LUID {tun.luid():#x}).")
        t = threading.Thread(target=down_loop, args=(sock, tun, peer, tunnel),
                             daemon=True)
        t.start()
        up_loop(sock, tun, peer, tunnel)


if __name__ == "__main__":
    main()
