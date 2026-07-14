"""Cliente VPN (portátil que quiere internet a través del servidor).

Dos hilos sobre la interfaz TUN y un socket UDP hacia el servidor:

  OUT : lee paquetes IP de la TUN (todo lo que el equipo quiere enviar a
        internet, si la ruta por defecto apunta al túnel) -> cifra ->
        envía por UDP al servidor.
  IN  : recibe datagramas del servidor -> descifra -> escribe en la TUN.

Uso (Administrador):
    python vpn_client.py <IP_DEL_SERVIDOR>
Antes hay que crear/configurar el adaptador y las rutas: ver setup_client.ps1.
"""

import socket
import sys
import threading

from tun_wintun import TunAdapter
from tunnel_crypto import Tunnel, InvalidTag, ReplayError

SERVER_PORT = 51820


def out_loop(sock: socket.socket, tun: TunAdapter, server_addr,
             tunnel: Tunnel) -> None:
    while True:
        packet = tun.read()
        if packet is None:
            continue
        sock.sendto(tunnel.seal(packet), server_addr)


def in_loop(sock: socket.socket, tun: TunAdapter, tunnel: Tunnel) -> None:
    while True:
        datagram, _ = sock.recvfrom(65535)
        try:
            packet = tunnel.open_(datagram)  # tag + descifrado + anti-replay
        except InvalidTag:
            print("[CLIENTE] paquete alterado/ajeno descartado")
            continue
        except ReplayError:
            print("[CLIENTE] replay descartado")
            continue
        if len(packet) < 20:
            continue
        tun.write(packet)


def main() -> None:
    if len(sys.argv) != 2:
        print("Uso: python vpn_client.py <IP_DEL_SERVIDOR>")
        sys.exit(1)
    server_addr = (sys.argv[1], SERVER_PORT)

    tunnel = Tunnel(role="client")
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    # Un envío inicial para que el servidor aprenda nuestra dirección UDP
    # (aunque aún no haya tráfico de la TUN).
    sock.sendto(tunnel.seal(b"\x00"), server_addr)
    print(f"[CLIENTE] Túnel hacia {server_addr[0]}:{server_addr[1]}")

    with TunAdapter(name="CriptoVPN") as tun:
        print(f"[CLIENTE] TUN lista (LUID {tun.luid():#x}).")
        t = threading.Thread(target=in_loop, args=(sock, tun, tunnel),
                             daemon=True)
        t.start()
        out_loop(sock, tun, server_addr, tunnel)


if __name__ == "__main__":
    main()
