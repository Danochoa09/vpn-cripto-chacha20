# get_wintun.ps1  -  Descarga wintun.dll (amd64) junto a los scripts.
#   powershell -ExecutionPolicy Bypass -File get_wintun.ps1

$ErrorActionPreference = "Stop"
$ver = "0.14.1"
$url = "https://www.wintun.net/builds/wintun-$ver.zip"
$zip = Join-Path $env:TEMP "wintun.zip"
$out = Join-Path $env:TEMP "wintun_extract"

Write-Host "Descargando $url ..."
Invoke-WebRequest -Uri $url -OutFile $zip
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
Expand-Archive -Path $zip -DestinationPath $out -Force

$dll = Join-Path $out "wintun\bin\amd64\wintun.dll"
if (-not (Test-Path $dll)) { throw "No se encontró wintun.dll en el zip." }
Copy-Item $dll -Destination (Join-Path $PSScriptRoot "wintun.dll") -Force
Write-Host "wintun.dll copiado a $PSScriptRoot"
Write-Host "SHA256:"
(Get-FileHash (Join-Path $PSScriptRoot "wintun.dll") -Algorithm SHA256).Hash
