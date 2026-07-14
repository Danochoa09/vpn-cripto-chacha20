# setup_client_nonat.ps1  -  Configura el lado CLIENTE del túnel cifrado
# (sin NAT). Ejecutar como Administrador DESPUES de arrancar
# `python vpn_client.py <IP_SERVIDOR>`.
#
#   powershell -ExecutionPolicy Bypass -File setup_client_nonat.ps1
#
# Deja el TUN en 10.9.0.2/24 y prueba el túnel con ping a 10.9.0.1.

$ErrorActionPreference = "Stop"
$TunAlias = "CriptoVPN"
$TunIP    = "10.9.0.2"
$ServerTunIP = "10.9.0.1"

Write-Host "Esperando el adaptador '$TunAlias' (arranca vpn_client.py primero)..."
$adapter = $null
for ($i = 0; $i -lt 30; $i++) {
    $adapter = Get-NetAdapter -Name $TunAlias -ErrorAction SilentlyContinue
    if ($adapter -and $adapter.Status -eq "Up") { break }
    Start-Sleep -Milliseconds 500
}
if (-not $adapter) { throw "No apareció '$TunAlias'. ¿Corriste vpn_client.py como Admin?" }

Get-NetIPAddress -InterfaceAlias $TunAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress -InterfaceAlias $TunAlias -IPAddress $TunIP -PrefixLength 24 | Out-Null
Write-Host "IP del túnel: $TunIP/24"

Write-Host ""
Write-Host "Probando el túnel: ping $ServerTunIP ..."
Start-Sleep -Seconds 1   # dar un momento a que el TUN levante
if (Test-Connection -ComputerName $ServerTunIP -Count 4 -Quiet) {
    Write-Host "OK: VPN cifrada funcionando (respuesta desde $ServerTunIP)."
} else {
    Write-Host "Sin respuesta. Revisa: vpn_server.py corriendo, IP_SERVIDOR correcta,"
    Write-Host "firewall del servidor (UDP 51820 + ICMP), y misma WiFi/hotspot."
}
