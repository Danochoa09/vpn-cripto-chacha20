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

# Restaurar IPv6: setup_client.ps1 lo desactiva en el adaptador físico para que
# el tráfico v6 no salga sin cifrar por fuera del túnel (que es solo IPv4).
# Lo reactiva donde esté apagado; si lo tenías desactivado a propósito en algún
# adaptador, vuelve a quedar activo.
Get-NetAdapterBinding -ComponentID ms_tcpip6 |
    Where-Object { -not $_.Enabled } | Enable-NetAdapterBinding
Clear-DnsClientCache

# Las IPs y el adaptador desaparecen solos al cerrar Python (Wintun los
# elimina). La ruta /32 al servidor también se va con el adaptador físico.

Write-Host "Configuración de VPN revertida. Reinicia si la red quedó rara."
