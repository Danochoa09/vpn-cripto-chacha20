# setup_server_nonat.ps1  -  Configura el lado SERVIDOR del túnel cifrado
# (sin NAT / sin internet compartido). Ejecutar como Administrador DESPUES de
# arrancar `python vpn_server.py` (el adaptador CriptoVPN solo existe mientras
# el proceso corre).
#
#   powershell -ExecutionPolicy Bypass -File setup_server_nonat.ps1
#
# Deja el TUN en 10.9.0.1/24 y abre el firewall para el túnel.

$ErrorActionPreference = "Stop"
$TunAlias = "CriptoVPN"
$TunIP    = "10.9.0.1"

Write-Host "Esperando el adaptador '$TunAlias' (arranca vpn_server.py primero)..."
$adapter = $null
for ($i = 0; $i -lt 30; $i++) {
    $adapter = Get-NetAdapter -Name $TunAlias -ErrorAction SilentlyContinue
    if ($adapter -and $adapter.Status -eq "Up") { break }
    Start-Sleep -Milliseconds 500
}
if (-not $adapter) { throw "No apareció '$TunAlias'. ¿Corriste vpn_server.py como Admin?" }

# IP del túnel (idempotente: quita cualquier IPv4 previa del TUN)
Get-NetIPAddress -InterfaceAlias $TunAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress -InterfaceAlias $TunAlias -IPAddress $TunIP -PrefixLength 24 | Out-Null
Write-Host "IP del túnel: $TunIP/24"

# Firewall: túnel UDP + ICMP (ping) entrantes
if (-not (Get-NetFirewallRule -DisplayName "CriptoVPN UDP" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "CriptoVPN UDP" -Direction Inbound `
        -Protocol UDP -LocalPort 51820 -Action Allow | Out-Null
}
if (-not (Get-NetFirewallRule -DisplayName "CriptoVPN ICMP" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "CriptoVPN ICMP" -Direction Inbound `
        -Protocol ICMPv4 -IcmpType 8 -Action Allow | Out-Null
}
Write-Host "Firewall: UDP 51820 + ICMP permitidos."

Write-Host ""
Write-Host "SERVIDOR listo (túnel 10.9.0.1). IP para que el cliente te alcance:"
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.InterfaceAlias -notlike "*CriptoVPN*" -and $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -ne "127.0.0.1" } |
    Select-Object InterfaceAlias, IPAddress | Format-Table -AutoSize
Write-Host "En el cliente: python vpn_client.py <esa-IP>  (o la puerta de enlace del hotspot)"
