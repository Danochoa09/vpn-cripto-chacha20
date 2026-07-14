#!/bin/bash
# setup_vm.sh  -  Configura la VM Linux como servidor VPN con NAT a internet.
# Ejecutar con sudo DESPUES de arrancar el servidor Python, que crea la TUN.
# Orden: en una terminal `sudo python3 vpn_server_linux.py`, y en otra
# `sudo bash setup_vm.sh`.
#
# Deja: TUN 'criptovpn' con IP 10.9.0.1/24, ip_forward activo y MASQUERADE
# para que el tráfico del cliente (10.9.0.0/24) salga a internet por la WAN.

set -e

TUN="criptovpn"
TUN_IP="10.9.0.1/24"
SUBNET="10.9.0.0/24"

# Interfaz de salida a internet (la de la ruta por defecto; en la VM con NAT
# de VirtualBox suele ser enp0s3 / eth0).
WAN=$(ip route show default | awk '/default/ {print $5; exit}')
if [ -z "$WAN" ]; then
    echo "No encontré la interfaz WAN (ruta por defecto). ¿La VM tiene internet?" >&2
    exit 1
fi
echo "Interfaz WAN: $WAN"

# Esperar a que exista la TUN (la crea vpn_server_linux.py)
echo "Esperando la interfaz '$TUN' (arranca vpn_server_linux.py primero)..."
for i in $(seq 1 30); do
    if ip link show "$TUN" >/dev/null 2>&1; then break; fi
    sleep 0.5
done
if ! ip link show "$TUN" >/dev/null 2>&1; then
    echo "No apareció '$TUN'. ¿Corriste 'sudo python3 vpn_server_linux.py'?" >&2
    exit 1
fi

# IP del túnel y subir la interfaz
ip addr flush dev "$TUN" 2>/dev/null || true
ip addr add "$TUN_IP" dev "$TUN"
ip link set "$TUN" up
echo "TUN '$TUN' -> $TUN_IP"

# Enrutamiento + NAT
sysctl -w net.ipv4.ip_forward=1 >/dev/null
echo "ip_forward activado"

# Limpia reglas previas nuestras (idempotente) y añade MASQUERADE + forward
iptables -t nat -C POSTROUTING -s "$SUBNET" -o "$WAN" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s "$SUBNET" -o "$WAN" -j MASQUERADE
iptables -C FORWARD -i "$TUN" -o "$WAN" -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -i "$TUN" -o "$WAN" -j ACCEPT
iptables -C FORWARD -i "$WAN" -o "$TUN" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -i "$WAN" -o "$TUN" -m state --state RELATED,ESTABLISHED -j ACCEPT
echo "NAT (MASQUERADE) $SUBNET -> $WAN listo"

echo ""
echo "SERVIDOR (VM) listo. El cliente Windows debe apuntar al puerto UDP 51820"
echo "de la LAPTOP anfitriona (VirtualBox lo reenvía a esta VM)."
