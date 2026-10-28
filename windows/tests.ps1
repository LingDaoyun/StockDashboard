param([switch]$Live)
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'test-market.ps1') -Live:$Live
& (Join-Path $PSScriptRoot 'test-tracking.ps1')
& (Join-Path $PSScriptRoot 'test-window.ps1')
& (Join-Path $PSScriptRoot 'test-desktop.ps1')
Write-Output 'All Windows test suites passed.'
