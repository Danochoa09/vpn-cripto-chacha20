# setup_client.ps1  -  Configura el lado CLIENTE de la VPN.
# Ejecutar como Administrador, DESPUES de arrancar `python vpn_client.py <IP_SERVIDOR>`.
#
#   powershell -ExecutionPolicy Bypass -File setup_client.ps1 -ServerIP <IP_SERVIDOR>
#
# Deja al cliente con IP de túnel 10.9.0.2 y TODO el tráfico de internet
# saliendo por el túnel (salvo el que va al propio servidor).
#
# <IP_SERVIDOR> = la IP de la LAPTOP anfitriona que el cliente alcanza por
# WiFi/hotspot. VirtualBox reenvía su UDP 51820 a la VM Linux que hace el NAT.

param(
    [Parameter(Mandatory = $true)] [string] $ServerIP,
    [string] $Dns = "1.1.1.1"
)

$ErrorActionPreference = "Stop"

# Túnel 10.9.0.0/24; el servidor (VM Linux) es 10.9.0.1.
$TunAlias = "CriptoVPN"
$TunIP    = "10.9.0.2"
$Prefix   = 24
$Gateway  = "10.9.0.1"   # IP del servidor dentro del túnel

Write-Host "Esperando el adaptador '$TunAlias' (arranca vpn_client.py primero)..."
$adapter = $null
for ($i = 0; $i -lt 30; $i++) {
    $adapter = Get-NetAdapter -Name $TunAlias -ErrorAction SilentlyContinue
    if ($adapter -and $adapter.Status -eq "Up") { break }
    Start-Sleep -Milliseconds 500
}
if (-not $adapter) { throw "No apareció el adaptador '$TunAlias'. ¿Corriste vpn_client.py como Admin?" }
Write-Host "Adaptador encontrado (ifIndex $($adapter.ifIndex))."

# IP del túnel
Get-NetIPAddress -InterfaceAlias $TunAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress -InterfaceAlias $TunAlias -IPAddress $TunIP -PrefixLength $Prefix | Out-Null
Set-NetIPInterface -InterfaceAlias $TunAlias -NlMtu 1400 -ErrorAction SilentlyContinue
Write-Host "IP del túnel: $TunIP/$Prefix"

# Ruta fija hacia el SERVIDOR por la red física (evita el bucle:
# los datagramas UDP del túnel NO deben entrar al propio túnel).
$phys = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
    Where-Object { $_.NextHop -ne "0.0.0.0" } | Sort-Object RouteMetric | Select-Object -First 1
if (-not $phys) { throw "No hay ruta física por defecto." }
$physGw = $phys.NextHop
$physIdx = $phys.ifIndex
# Idempotente: quita la ruta previa si existe. Con cmdlets, no con `route
# delete`: el stderr de un exe nativo se vuelve error terminante por el
# $ErrorActionPreference = "Stop" y abortaba el script en la 1ra corrida.
Get-NetRoute -DestinationPrefix "$ServerIP/32" -ErrorAction SilentlyContinue |
    Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
New-NetRoute -DestinationPrefix "$ServerIP/32" -InterfaceIndex $physIdx -NextHop $physGw | Out-Null
Write-Host "Ruta al servidor $ServerIP vía red física ($physGw)."

# Redirigir TODO internet por el túnel: dos rutas /1 que ganan a la default
# sin borrarla (truco clásico de VPN).
New-NetRoute -DestinationPrefix "0.0.0.0/1"   -InterfaceAlias $TunAlias -NextHop $Gateway | Out-Null
New-NetRoute -DestinationPrefix "128.0.0.0/1" -InterfaceAlias $TunAlias -NextHop $Gateway | Out-Null
Write-Host "Tráfico de internet redirigido por el túnel (gateway $Gateway)."

# DNS por el túnel (si no, las consultas DNS podrían filtrarse o fallar)
Set-DnsClientServerAddress -InterfaceAlias $TunAlias -ServerAddresses $Dns
Set-NetIPInterface -InterfaceAlias $TunAlias -InterfaceMetric 1 -ErrorAction SilentlyContinue
Write-Host "DNS del túnel: $Dns"

# Cerrar la fuga de DNS por IPv4. El hotspot entrega su propia IP como DNS por
# DHCP (192.168.137.1), que esta en la MISMA subred que el cliente: la ruta
# conectada /24 gana a las /1 del tunel, asi que esa consulta sale on-link, en
# claro, con la VPN arriba. Verificado en Wireshark: Dst 192.168.137.1.
#
# No se pelea con el resolver de Windows (que consulta por varias interfaces a
# la vez): se hace que TODO camino lleve al tunel. Con $Dns tambien en los
# adaptadores fisicos, cualquier consulta va dirigida a $Dns -- y la ruta a $Dns
# es la 0.0.0.0/1 por el tunel. El enrutamiento es global; el resolver no lo
# esquiva. Si el tunel cae, $Dns sigue siendo alcanzable por la ruta fisica, asi
# que no se rompe la resolucion.
#
# Se guarda el DNS previo de cada adaptador en .dns_backup para que teardown.ps1
# restaure exactamente lo que habia (estatico o DHCP), no un estado impuesto.
$dnsBackup = Join-Path $PSScriptRoot ".dns_backup"
$lines = @()
foreach ($a in Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.Name -ne $TunAlias }) {
    # Get-DnsClientServerAddress devuelve los servidores EFECTIVOS sin decir de
    # donde salen. El valor NameServer del registro solo contiene los ESTATICOS:
    # vacio => el DNS venia por DHCP. Sin esta distincion, teardown restauraria
    # como estatico un DNS que era de DHCP, cambiando la config del equipo a sus
    # espaldas.
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($a.InterfaceGuid)"
    $static = (Get-ItemProperty -Path $key -Name NameServer -ErrorAction SilentlyContinue).NameServer
    $lines += "$($a.Name)|$static"
    Set-DnsClientServerAddress -InterfaceAlias $a.Name -ServerAddresses $Dns
}
$lines | Set-Content -Path $dnsBackup -Encoding utf8
Write-Host "DNS $Dns forzado en los adaptadores físicos (cierra la fuga on-link)."

# Cerrar la fuga IPv6. Las rutas de arriba son IPv4 (0.0.0.0/1 + 128.0.0.0/1),
# asi que el IPv6 no tiene ruta al tunel y Windows lo sacaria por la fisica sin
# cifrar: el DNS se fuga en claro aunque la VPN este arriba (verificado en
# Wireshark: EtherType 0x86dd con el tunel activo). Es la fuga clasica; la misma
# que tiene WireGuard con AllowedIPs=0.0.0.0/0 sin ::/0.
#
# Se bloquea en vez de tunelizarlo porque el nodo de salida (la VM, tras el NAT
# de VirtualBox) no tiene IPv6: transportarlo cambiaria la fuga por un agujero
# negro. Es lo que hacen los clientes VPN comerciales.
#
# En TODOS los adaptadores activos, no solo el de la ruta por defecto: basta una
# interfaz con v6 viva para que la fuga siga abierta.
#
# Se registra en .ipv6_disabled cuales se tocaron, para que teardown.ps1 pueda
# restaurar SOLO esos y no encienda IPv6 en adaptadores donde ya estaba apagado
# a proposito.
$stateFile = Join-Path $PSScriptRoot ".ipv6_disabled"
$disabled = @()
foreach ($a in Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.Name -ne $TunAlias }) {
    $b = Get-NetAdapterBinding -InterfaceAlias $a.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
    if (-not $b -or -not $b.Enabled) { continue }   # ya apagado: ni lo tocamos ni lo registramos
    Disable-NetAdapterBinding -InterfaceAlias $a.Name -ComponentID ms_tcpip6
    # Verificar de verdad. Sin esto el script podria anunciar "IPv6 desactivado"
    # con la fuga abierta, que es peor que no intentarlo: te haria confiar.
    $now = Get-NetAdapterBinding -InterfaceAlias $a.Name -ComponentID ms_tcpip6
    if ($now.Enabled) {
        throw "No se pudo desactivar IPv6 en '$($a.Name)'. El trafico v6 (DNS incluido) se fugaria SIN CIFRAR fuera del tunel. Aborta: no uses la VPN hasta resolverlo."
    }
    $disabled += $a.Name
}
$disabled | Set-Content -Path $stateFile -Encoding utf8
Clear-DnsClientCache
if ($disabled) {
    Write-Host "IPv6 desactivado y verificado en: $($disabled -join ', ')"
} else {
    Write-Host "IPv6 ya estaba desactivado en todos los adaptadores activos."
}

Write-Host ""
Write-Host "CLIENTE listo. Prueba:  ping 10.9.0.1   luego   ping 1.1.1.1   luego  nslookup google.com"
Write-Host "Verifica que no haya fuga: en el host, filtro Wireshark  'dns'  -> vacío."
