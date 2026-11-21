[CmdletBinding()]
param(
    [string]$GameRoot
)

$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot 'Importer.ps1'
if ([string]::IsNullOrWhiteSpace($GameRoot)) {
    & $helper
} else {
    & $helper -GameRoot $GameRoot
}
