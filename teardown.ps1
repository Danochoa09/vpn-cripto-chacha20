# teardown.ps1  -  Revierte la configuración de red de la VPN.
# Ejecutar como Administrador en cualquiera de los dos equipos tras cerrar Python.
#
#   powershell -ExecutionPolicy Bypass -File teardown.ps1

$ErrorActionPreference = "SilentlyContinue"

# Desactivar ICS (solo aplica en el servidor)
try {
    $share = New-Object -ComObject HNetCfg.HNetShare
    foreach ($c in $share.EnumEveryConnection) {
        $cfg = $share.INetSharingConfigurationForINetConnection($c)
        if ($cfg.SharingEnabled) { $cfg.DisableSharing() }
    }
} catch {}

# Quitar rutas /1 del cliente
Get-NetRoute -DestinationPrefix "0.0.0.0/1"   | Remove-NetRoute -Confirm:$false
Get-NetRoute -DestinationPrefix "128.0.0.0/1" | Remove-NetRoute -Confirm:$false

# Quitar regla de firewall
Get-NetFirewallRule -DisplayName "CriptoVPN UDP" | Remove-NetFirewallRule

# Restaurar IPv6 SOLO en los adaptadores que setup_client.ps1 desactivó, según
# el registro que dejó. Reactivarlo en todos los que estén apagados encendería
# IPv6 donde el usuario lo tenía apagado a propósito: revertir es deshacer lo
# nuestro, no imponer un estado.
#
# El $ErrorActionPreference de arriba es SilentlyContinue, así que aquí se
# verifica a mano: un restore fallido en silencio dejaría el equipo sin IPv6
# para siempre y sin avisar.
$stateFile = Join-Path $PSScriptRoot ".ipv6_disabled"
if (Test-Path $stateFile) {
    foreach ($line in Get-Content $stateFile) {
        $name = $line.Trim()
        if (-not $name) { continue }
        Enable-NetAdapterBinding -InterfaceAlias $name -ComponentID ms_tcpip6
        $b = Get-NetAdapterBinding -InterfaceAlias $name -ComponentID ms_tcpip6
        if ($b -and -not $b.Enabled) {
            Write-Warning "No se pudo reactivar IPv6 en '$name'. Hazlo a mano como Admin: Enable-NetAdapterBinding -InterfaceAlias '$name' -ComponentID ms_tcpip6"
        } else {
            Write-Host "IPv6 restaurado en '$name'."
        }
    }
    Remove-Item $stateFile -Force
} else {
    Write-Host "Sin registro '.ipv6_disabled': no se toca el IPv6 de ningún adaptador."
}
Clear-DnsClientCache

# Las IPs y el adaptador desaparecen solos al cerrar Python (Wintun los
# elimina). La ruta /32 al servidor también se va con el adaptador físico.

Write-Host "Configuración de VPN revertida. Reinicia si la red quedó rara."
