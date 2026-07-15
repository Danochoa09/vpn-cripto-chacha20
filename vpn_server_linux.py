"""Servidor VPN para Linux (la VM que hace NAT hacia internet).

Idéntico en lógica a `vpn_server.py` (Windows) pero usando el TUN de Linux.
El cifrado (`tunnel_crypto.py`) es el mismo. El NAT no lo hace este proceso:
lo hace el kernel con iptables MASQUERADE (ver setup_vm.sh). Aquí solo:

  UP   : UDP del cliente -> descifra/verifica -> escribe en la TUN. El kernel
         (con ip_forward + MASQUERADE) lo enruta hacia internet.
  DOWN : lee de la TUN las respuestas -> cifra -> UDP al cliente.

Uso (root):
    sudo python3 vpn_server_linux.py
Antes: crear la TUN con IP y activar NAT con setup_vm.sh.
"""

import socket
import threading

from tun_linux import TunAdapter
from tunnel_crypto import Tunnel, InvalidTag, ReplayError

LISTEN_ADDR = ("0.0.0.0", 51820)
TUN_NAME = "criptovpn"


class Peer:
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


def up_loop(sock, tun, peer, tunnel):
    while True:
        datagram, addr = sock.recvfrom(65535)
        try:
            packet = tunnel.open_(datagram)   # tag + descifrado + anti-replay
        except InvalidTag:
            print(f"[SERVIDOR] paquete alterado/ajeno descartado de {addr[0]}")
            continue
        except ReplayError:
            print(f"[SERVIDOR] replay descartado de {addr[0]}")
            continue
        # Solo tras autenticar aprendemos la dirección del cliente: si no,
        # cualquier UDP ajeno al puerto redirigiría el tráfico de bajada.
        peer.set(addr)
        if len(packet) < 20:   # keepalive del cliente u otro no-IP
            continue
        tun.write(packet)


def down_loop(sock, tun, peer, tunnel):
    while True:
        packet = tun.read()
        if packet is None:
            continue
        addr = peer.get()
        if addr is None:
            continue
        sock.sendto(tunnel.seal(packet), addr)


def main():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(LISTEN_ADDR)
    print(f"[SERVIDOR] Túnel UDP escuchando en {LISTEN_ADDR[1]}")

    peer = Peer()
    tunnel = Tunnel(role="server")
    with TunAdapter(name=TUN_NAME) as tun:
        print(f"[SERVIDOR] TUN '{TUN_NAME}' lista.")
        threading.Thread(target=down_loop, args=(sock, tun, peer, tunnel),
                         daemon=True).start()
        up_loop(sock, tun, peer, tunnel)


if __name__ == "__main__":
    main()
