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

# Cerrar la fuga de DNS (kill switch).
#
# El cliente DNS de Windows ATA la consulta a la interfaz cuyo servidor esta
# usando (smart multi-homed name resolution): la manda POR esa interfaz, con el
# socket bindeado, SIN pasar por la tabla de rutas. Medido en este proyecto:
# `tracert 1.1.1.1` sale por 10.9.0.1 (el tunel), pero la consulta DNS al MISMO
# 1.1.1.1 sale en claro por el WiFi. Mismo destino, dos caminos a la vez.
#
# Por eso cambiar el servidor DNS no sirve: solo cambia a QUIEN se le fuga. Si
# no se puede redirigir la consulta, se corta el camino: se bloquea el puerto 53
# saliente en los adaptadores fisicos. La consulta paralela por la fisica muere;
# la que sale por el tunel responde. El tunel usa UDP 51820, no se afecta.
#
# Falla cerrado: si vpn_client.py muere, el DNS deja de resolver hasta correr
# teardown.ps1. Es lo que hace un kill switch de VPN y es la mitad del punto:
# preferimos quedarnos sin DNS antes que filtrarlo.
$fwName = "CriptoVPN kill switch DNS"
$physNames = @(Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.Name -ne $TunAlias } |
    Select-Object -ExpandProperty Name)
# -InterfaceAlias es WildcardPattern[], no string: nombres como
# "Conexion de area local* 2" llevan un * literal que se interpretaria como
# comodin y bloquearia 53 en mas interfaces de las previstas.
$physPatterns = @($physNames | ForEach-Object { [System.Management.Automation.WildcardPattern]::Escape($_) })
Get-NetFirewallRule -DisplayName $fwName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
foreach ($proto in @("UDP", "TCP")) {   # 53/TCP lo usan las respuestas grandes
    New-NetFirewallRule -DisplayName $fwName -Direction Outbound -Protocol $proto `
        -RemotePort 53 -InterfaceAlias $physPatterns -Action Block | Out-Null
}
Write-Host "Kill switch DNS: puerto 53 bloqueado en $($physNames -join ', ')."

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
