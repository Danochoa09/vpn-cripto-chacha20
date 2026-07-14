# VPN real (Windows ↔ Windows) con ChaCha20-Poly1305

Dos portátiles unen un **túnel UDP cifrado** que transporta **paquetes IP
reales** a través de una interfaz TUN (Wintun), como una VPN de verdad. A
diferencia de `../vpn_sim/` (chat de demostración), aquí viaja tráfico IP
completo (ping, transferencias, etc.), no texto.

```
[Cliente]  app --> TUN --> cifra ChaCha20-Poly1305 --> UDP :51820 --> [Servidor]
[Cliente]  app <-- TUN <-- descifra/verifica     <--     UDP     <-- cifra <-- TUN
```

> **Nota sobre "compartir internet".** La idea original era que el servidor
> diera salida a internet (NAT) al cliente. En Windows 11 **cliente** eso no
> es viable con estas herramientas: la clase NAT en-caja (`MSFT_NetNat`) no
> existe, ICS no se deja binclar a un adaptador Wintun (error `0x80040201`) y
> RRAS solo está en Windows Server. Por eso la demo funcional es el **túnel
> cifrado máquina-a-máquina** (abajo), que ya prueba lo esencial de una VPN:
> confidencialidad, integridad y anti-replay sobre tráfico IP real. El
> internet compartido queda documentado como limitación del entorno, no del
> diseño criptográfico. Ver "Compartir internet" al final.

## Requisitos

- **Ambos equipos**: Windows, Python 3.11+, `pip install cryptography`,
  y `wintun.dll` junto a los scripts (`.\get_wintun.ps1` lo descarga).
- **Misma red local**: el cliente debe alcanzar una IP del servidor (WiFi o
  Ethernet compartido). En la prueba real el cliente va por WiFi.
- **Administrador** en ambos (crear el adaptador TUN necesita privilegios).

## Archivos

| Archivo | Rol |
|---|---|
| `tun_wintun.py` | Interfaz TUN vía `wintun.dll` (ctypes): leer/escribir paquetes IP |
| `tunnel_crypto.py` | ChaCha20-Poly1305 + anti-replay: `[8B contador][ciphertext+tag]` |
| `test_crypto.py` | Pruebas: roundtrip, integridad, replay, fuera de orden |
| `vpn_server.py` | TUN + UDP: descifra/verifica lo entrante, cifra las respuestas |
| `vpn_client.py` | TUN + UDP: cifra lo saliente, descifra/verifica lo entrante |
| `get_wintun.ps1` | Descarga `wintun.dll` |
| `demo/secreto.txt` | Archivo con "secreto" (contraseña/tarjeta/token falsos) para la prueba de Wireshark |
| `setup_server_nonat.ps1` | Un comando: IP del TUN (10.9.0.1) + firewall del túnel |
| `setup_client_nonat.ps1` | Un comando: IP del TUN (10.9.0.2) + prueba de ping |
| `setup_server.ps1`, `setup_client.ps1`, `teardown.ps1` | Solo para el intento de internet compartido (NAT/ICS); ver la sección final. No se usan en la demo básica |

## Puesta en marcha (túnel cifrado, sin NAT) — PROBADO

Túnel en la subred **`10.9.0.0/24`** (servidor `10.9.0.1`, cliente
`10.9.0.2`). Se elige `10.9.0.x` para no chocar con la red WiFi/hotspot que
une las laptops (p. ej. el Mobile Hotspot de Windows usa `192.168.137.x`).

Cada equipo necesita dos terminales de Administrador: una para el proceso
Python (queda corriendo) y otra para configurar la IP.

**Atajo (recomendado para la exposición):** en vez de teclear los pasos S2/C2
a mano, usa los scripts de un comando tras arrancar el Python de cada lado:
`setup_server_nonat.ps1` en el servidor y `setup_client_nonat.ps1` en el
cliente. Los pasos manuales de abajo son el equivalente, por si quieres
entenderlos o depurar.

### 0. En ambos equipos (una vez)
```
pip install cryptography
powershell -ExecutionPolicy Bypass -File get_wintun.ps1
```

### S1. Servidor — arrancar el túnel (Admin nº1, dejar corriendo)
```
python vpn_server.py
```
Debe imprimir `[SERVIDOR] TUN lista (LUID 0x...)`.

### S2. Servidor — IP del túnel y firewall (Admin nº2)
```
New-NetIPAddress -InterfaceAlias CriptoVPN -IPAddress 10.9.0.1 -PrefixLength 24
New-NetFirewallRule -DisplayName "CriptoVPN UDP"  -Direction Inbound -Protocol UDP    -LocalPort 51820 -Action Allow
New-NetFirewallRule -DisplayName "CriptoVPN ICMP" -Direction Inbound -Protocol ICMPv4 -IcmpType 8 -Action Allow
```
Averigua la IP por la que el cliente alcanza al servidor. Si el cliente está
unido al hotspot del servidor, es la **puerta de enlace** que ve el cliente
(típico `192.168.137.1`). Si ambos están en el mismo router, es la IPv4 WiFi
del servidor:
```
ipconfig
```

### C1. Cliente — arrancar el túnel (Admin nº1, dejar corriendo)
Con `wintun.dll`, `cryptography` y los `.py` copiados. `<IP_SERVIDOR>` = la
puerta de enlace / IP WiFi del servidor:
```
python vpn_client.py <IP_SERVIDOR>
```
Debe imprimir `[CLIENTE] TUN lista (LUID 0x...)`.

### C2. Cliente — IP del túnel y prueba (Admin nº2)
```
New-NetIPAddress -InterfaceAlias CriptoVPN -IPAddress 10.9.0.2 -PrefixLength 24
ping 10.9.0.1
```
**Respuesta al ping = VPN cifrada funcionando** entre las dos laptops. (El
primer intento puede dar "tiempo de espera agotado" mientras el TUN levanta;
los siguientes responden.)

Prueba extra:
- Bidireccional: desde el servidor, `ping 10.9.0.2`.
- Transferir por el túnel: servidor `python -m http.server 8000 --bind 10.9.0.1`;
  cliente abre `http://10.9.0.1:8000`. Todo viaja cifrado.

### Cerrar
Ctrl+C en los procesos Python de ambos equipos. Al cerrar Wintun, el
adaptador `CriptoVPN` y su IP desaparecen solos. Para quitar las reglas de
firewall: `Get-NetFirewallRule -DisplayName "CriptoVPN*" | Remove-NetFirewallRule`.

## Demostrar el cifrado en la defensa

Elegir la interfaz correcta en Wireshark. El túnel cifrado viaja por el
adaptador que une las dos laptops: si el cliente está en el **hotspot** del
servidor, ese adaptador NO es "Wi-Fi" sino una **"Conexión de área local\* N"**
(el AP virtual, `192.168.137.x`). El tráfico **descifrado** aparece en el
adaptador **`CriptoVPN`** (`10.9.0.x`). Para hallar el del hotspot: lanza un
ping continuo y mira cuál "Conexión de área local\*" dibuja actividad.

- **Contraste ping** (mismo paquete, dos caras): captura a la vez en la
  interfaz del hotspot (`udp.port == 51820`) y en `CriptoVPN` (`icmp`), y haz
  `ping 10.9.0.1` desde el cliente.
  - Hotspot → UDP con `[contador][ciphertext+tag]`, ilegible.
  - `CriptoVPN` → `Echo (ping) request/reply` en claro entre `10.9.0.x`.
- Cambia un byte de `KEY` en un solo lado: el túnel deja de funcionar →
  confidencialidad e integridad dependen de la clave compartida.
- `python test_crypto.py`: muestra en vivo el rechazo de bit-flip (Poly1305)
  y de replay (reinyección), los ataques que un cifrado sin AEAD no frena.

### Prueba estrella: texto plano vs cifrado con un "secreto"

La demo más contundente. Se sirve el archivo `demo/secreto.txt` (contiene
contraseña, tarjeta y token falsos) por HTTP y se compara cómo se ve en la
red **sin** y **con** el túnel. Misma interfaz de captura (el hotspot); lo
único que cambia es la IP del `curl`.

Preparación (una vez, en el SERVIDOR):
```
New-NetFirewallRule -DisplayName "HTTP demo" -Direction Inbound -Protocol TCP -LocalPort 8000 -Action Allow
```

**Par 3 — SIN VPN (se lee el secreto):**
- Servidor, en la carpeta del archivo:
  ```
  cd vpn_real\demo
  python -m http.server 8000 --bind 192.168.137.1
  ```
- Cliente: captura en la interfaz del hotspot, filtro `tcp.port == 8000`, y:
  ```
  curl http://192.168.137.1:8000/secreto.txt
  ```
- Clic derecho en un paquete → **Seguir → Flujo HTTP**: se lee
  `CONTRASENA: unal2026`, la tarjeta y el token **en claro**. Guardar como
  `sin_vpn.pcapng`.

**Par 4 — CON VPN (solo ciphertext):**  (túnel vivo: `vpn_server.py` +
`vpn_client.py` corriendo)
- Servidor, otra terminal, misma carpeta:
  ```
  python -m http.server 8000 --bind 10.9.0.1
  ```
- Cliente: captura en la **misma** interfaz del hotspot, filtro
  `udp.port == 51820`, y:
  ```
  curl http://10.9.0.1:8000/secreto.txt
  ```
- **Seguir → Flujo UDP**: puro ruido cifrado. Cambia el filtro a
  `tcp.port == 8000` → no aparece nada. Guardar como `con_vpn.pcapng`.

**Golpe de gracia:** en cada captura, **Edición → Buscar paquete** → modo
*Cadena*, ámbito "Bytes del paquete" → `CONTRASENA`.
- `sin_vpn.pcapng`: **la encuentra** (viaja en claro).
- `con_vpn.pcapng`: **no la encuentra** (cifrada).

Misma búsqueda, resultado opuesto = prueba irrefutable del cifrado.

> **Nota honesta (dila en la defensa):** este contraste solo funciona con el
> servidor HTTP local (`10.9.0.1`). Navegar una web real de internet NO se ve
> distinto con la VPN encendida o apagada, porque (a) este túnel no reenvía
> tráfico a internet —el NAT no es viable en Windows cliente— así que el
> tráfico web no entra al túnel, y (b) los sitios reales ya usan HTTPS (TLS),
> ilegibles en Wireshark incluso sin VPN.

## Cifrado: ChaCha20-Poly1305 + anti-replay (estilo WireGuard)
Cada paquete se cifra, se autentica y lleva un número de secuencia:

- **Confidencialidad + integridad**: Poly1305 añade un tag de 16 bytes.
  Alterar un bit del contador, del ciphertext o del tag hace fallar el
  descifrado (`InvalidTag`) y el paquete se descarta.
- **Nonce por contador**: el nonce se deriva de un contador de 64 bits
  monótono, no es aleatorio → nunca se repite (cero riesgo de colisión).
- **Clave por dirección**: subclaves HKDF distintas para cliente→servidor y
  servidor→cliente, así ambos pueden empezar el contador en 0 sin colisionar.
- **Anti-replay**: el receptor lleva una ventana deslizante (RFC 6479) de los
  contadores vistos. Un datagrama reinyectado o demasiado viejo se rechaza
  (`ReplayError`), incluso si su tag es válido. La comprobación va DESPUÉS de
  autenticar, para que nadie pueda envenenar la ventana con contadores falsos.

Demo para la defensa (roundtrip, bit-flip, replay, fuera de orden):
```
python test_crypto.py
```

## Qué lo diferencia de una VPN real (dilas en la defensa)

Esto implementa **bien el núcleo criptográfico** (ChaCha20-Poly1305 + nonce
por contador + anti-replay, igual que WireGuard), pero una VPN de producción
(WireGuard, OpenVPN, IPsec) tiene muchas capas más que aquí se omiten por
simplicidad:

| Aspecto | Este proyecto | VPN real |
|---|---|---|
| **Intercambio de claves** | Clave maestra fija en el código | Handshake con Diffie-Hellman efímero (X25519) |
| **Forward secrecy** | No (clave estática) | Sí: claves de sesión que rotan, capturar hoy no descifra lo viejo |
| **Autenticación de extremos** | Ninguna: quien tenga la clave entra | Claves públicas/certificados por peer; identidad verificada |
| **Rekeying** | Nunca; el contador de 64 bits es el único límite | Renegocia claves cada cierto tiempo/volumen |
| **Handshake / sesión** | No hay; el server aprende la IP del 1er paquete | Handshake criptográfico con protección anti-DoS (cookies) |
| **Multi-cliente** | Un solo cliente a la vez | Muchos peers, cada uno con su IP de túnel y sus claves |
| **Salida a internet (NAT)** | No (bloqueado en Windows cliente) | NAT/routing completo, split-tunnel, DNS push |
| **Reintentos / keepalive** | Un keepalive básico | Keepalives, detección de peer muerto, reconexión, roaming de IP |
| **PMTU / fragmentación** | MTU fija manual (~1400) | Descubrimiento de MTU y manejo de fragmentación |
| **IPv6** | Solo IPv4 | IPv4 + IPv6 |
| **Rendimiento** | Python en espacio de usuario (lento) | Kernel/driver optimizado, cifrado acelerado por hardware |
| **Robustez / servicio** | Script que hay que lanzar a mano como Admin | Servicio del sistema, arranque automático, config declarativa |
| **Agilidad criptográfica** | Un solo algoritmo fijo | Suites negociables, rotación de algoritmos |
| **Ofuscación / anti-censura** | No | Opcional (disfrazar tráfico como HTTPS, etc.) |
| **Multiplataforma** | Solo Windows (Wintun) | Windows, Linux, macOS, móviles |

Las tres diferencias más importantes para mencionar:

1. **Sin intercambio de claves ni forward secrecy.** La clave está en el
   fuente; cualquiera que lo vea puede descifrar todo, presente y pasado.
   WireGuard negocia claves efímeras por sesión (X25519), así que capturar el
   tráfico hoy no sirve si mañana se filtra la clave.
2. **Sin autenticación de extremos.** No se verifica *quién* es el otro lado;
   solo que comparte la clave. Una VPN real autentica cada peer por su clave
   pública o certificado.
3. **No enruta a internet.** Es un túnel punto a punto entre dos máquinas, no
   una puerta de salida (ver la sección siguiente).

Lo que **sí** está a la altura de una VPN real: el cifrado autenticado por
paquete (ChaCha20-Poly1305), el nonce por contador que nunca se repite, las
claves separadas por dirección y la protección anti-replay con ventana
deslizante. Ese es el corazón criptográfico y está bien hecho.

## Compartir internet (por qué no se logró y qué haría falta)

El objetivo extra —que el cliente navegue por internet a través del
servidor— quedó bloqueado por el **entorno**, no por la criptografía:

- `New-NetNat` falla con *"Clase no válida"*: la clase WMI `MSFT_NetNat` no
  existe en este Windows 11 (`Get-CimClass ... MSFT_NetNat` → *No encontrado*).
- **ICS** (Internet Connection Sharing) falla con `0x80040201` al intentar
  compartir hacia el adaptador **Wintun**: ICS no acepta ese tipo de medio.
- **RRAS** (`netsh routing ip nat`) solo existe en Windows **Server**, no en
  ediciones cliente.

Para que funcionara habría que **hacer NAT en el servidor**, con alguna de:
1. Un Windows con `MSFT_NetNat` disponible (p. ej. otra build/edición), y
   entonces sí: `New-NetNat -InternalIPInterfaceAddressPrefix 192.168.137.0/24`
   + `Set-NetIPInterface -Forwarding Enabled` en el TUN y en la WAN.
2. Usar **Linux** como servidor: `iptables -t nat -A POSTROUTING -o <wan>
   -j MASQUERADE` + `sysctl net.ipv4.ip_forward=1`. Camino limpio.
3. Un servidor real (VPS/Windows Server) con RRAS.

Los scripts `setup_server.ps1` / `setup_client.ps1` implementan ese intento
(ICS + rutas + DNS) y se dejan como referencia, pero **no** son necesarios
para la demo del túnel cifrado, que es autosuficiente.
