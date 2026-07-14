# setup_server.ps1  -  Configura el lado SERVIDOR de la VPN (vía ICS).
# Ejecutar como Administrador, DESPUES de arrancar `python vpn_server.py`
# (el adaptador "CriptoVPN" solo existe mientras el proceso corre).
#
#   powershell -ExecutionPolicy Bypass -File setup_server.ps1
#
# Usa Internet Connection Sharing (ICS) en vez de New-NetNat, porque la clase
# NAT (MSFT_NetNat) no está disponible en muchas imágenes de Windows/VM.
# ICS FUERZA la subred interna a 192.168.137.0/24: el servidor queda en
# 192.168.137.1 y el cliente debe usar 192.168.137.2.

$ErrorActionPreference = "Stop"

$TunAlias = "CriptoVPN"
$UdpPort  = 51820

Write-Host "Esperando el adaptador '$TunAlias' (arranca vpn_server.py primero)..."
$adapter = $null
for ($i = 0; $i -lt 30; $i++) {
    $adapter = Get-NetAdapter -Name $TunAlias -ErrorAction SilentlyContinue
    if ($adapter -and $adapter.Status -eq "Up") { break }
    Start-Sleep -Milliseconds 500
}
if (-not $adapter) { throw "No apareció el adaptador '$TunAlias'. ¿Corriste vpn_server.py como Admin?" }
Write-Host "Adaptador encontrado (ifIndex $($adapter.ifIndex))."

# Interfaz física con internet (la de la ruta por defecto)
$defRoute = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
    Where-Object { $_.NextHop -ne "0.0.0.0" } | Sort-Object RouteMetric | Select-Object -First 1
if (-not $defRoute) { throw "No hay ruta por defecto: el servidor no tiene internet." }
$wanAlias = (Get-NetAdapter -InterfaceIndex $defRoute.ifIndex).Name
Write-Host "Interfaz WAN (internet): $wanAlias"

# Asegurar el servicio de ICS
Set-Service SharedAccess -StartupType Automatic
Start-Service SharedAccess

# Habilitar ICS: compartir la WAN (público) hacia el túnel (privado)
$share = New-Object -ComObject HNetCfg.HNetShare
function Get-Conn($name) {
    foreach ($c in $share.EnumEveryConnection) {
        if ($share.NetConnectionProps($c).Name -eq $name) { return $c }
    }
    return $null
}

$wanConn = Get-Conn $wanAlias
$tunConn = Get-Conn $TunAlias
if (-not $wanConn) { throw "No encontré la conexión WAN '$wanAlias' en ICS." }
if (-not $tunConn) { throw "No encontré la conexión '$TunAlias' en ICS." }

# Quitar cualquier compartición previa para empezar limpio
foreach ($c in $share.EnumEveryConnection) {
    $cfg = $share.INetSharingConfigurationForINetConnection($c)
    if ($cfg.SharingEnabled) { $cfg.DisableSharing() }
}

# 0 = público (la que tiene internet), 1 = privado (la red interna/túnel)
$share.INetSharingConfigurationForINetConnection($wanConn).EnableSharing(0)
$share.INetSharingConfigurationForINetConnection($tunConn).EnableSharing(1)
Write-Host "ICS habilitado: '$wanAlias' -> '$TunAlias'."

# IP forwarding en el túnel (ICS suele activarlo, reforzamos)
Set-NetIPInterface -InterfaceAlias $TunAlias -Forwarding Enabled -ErrorAction SilentlyContinue
Set-NetIPInterface -InterfaceAlias $TunAlias -NlMtu 1400 -ErrorAction SilentlyContinue

# Firewall: permitir el puerto UDP del túnel
if (-not (Get-NetFirewallRule -DisplayName "CriptoVPN UDP" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "CriptoVPN UDP" -Direction Inbound `
        -Protocol UDP -LocalPort $UdpPort -Action Allow | Out-Null
}
Write-Host "Firewall: UDP $UdpPort permitido."

Write-Host ""
Write-Host "SERVIDOR listo. El túnel usa 192.168.137.0/24 (servidor = 192.168.137.1)."
Write-Host "IP de este equipo en la LAN (pásasela al cliente):"
Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias $wanAlias |
    Select-Object -ExpandProperty IPAddress
Write-Host "En el cliente: python vpn_client.py <esa-IP>"
