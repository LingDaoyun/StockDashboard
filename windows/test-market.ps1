param([switch]$Live)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
$exe = Join-Path $root 'work/MarketDataTests.exe'
& $compiler /nologo /langversion:5 /target:exe /main:StockDashboard.MarketDataTests "/out:$exe" /r:System.Net.Http.dll /r:System.Web.Extensions.dll (Join-Path $root 'Sources/MarketData.cs') (Join-Path $root 'Tests/MarketDataTests.cs')
if ($LASTEXITCODE -ne 0) { throw 'Market data test compilation failed' }
if ($Live) { & $exe --live } else { & $exe }
if ($LASTEXITCODE -ne 0) { throw 'Market data tests failed' }
