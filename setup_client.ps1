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
route delete $ServerIP 2>$null | Out-Null
New-NetRoute -DestinationPrefix "$ServerIP/32" -InterfaceIndex $physIdx -NextHop $physGw | Out-Null
Write-Host "Ruta al servidor $ServerIP vía red física ($physGw)."

# Redirigir TODO internet por el túnel: dos rutas /1 que ganan a la default
# sin borrarla (truco clásico de VPN).
New-NetRoute -DestinationPrefix "0.0.0.0/1"   -InterfaceAlias $TunAlias -NextHop $Gateway | Out-Null
New-NetRoute -DestinationPrefix "128.0.0.0/1" -InterfaceAlias $TunAlias -NextHop $Gateway | Out-Null
Write-Host "Tráfico de internet redirigido por el túnel (gateway $Gateway)."

# DNS por el túnel (si no, las consultas DNS podrían filtrarse o fallar)
Set-DnsClientServerAddress -InterfaceAlias $TunAlias -ServerAddresses $Dns
Write-Host "DNS del túnel: $Dns"

Write-Host ""
Write-Host "CLIENTE listo. Prueba:  ping 10.9.0.1   luego   ping 1.1.1.1   luego  nslookup google.com"
