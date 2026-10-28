$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework/v4.0.30319/csc.exe' }
$testDirectory = Join-Path $root 'work/tracking-tests'
[void](New-Item -ItemType Directory -Force -Path $testDirectory)
$testExe = Join-Path $testDirectory 'TrackingTests.exe'
& $compiler /nologo /langversion:5 /target:exe /r:System.Web.Extensions.dll "/out:$testExe" (Join-Path $root 'Sources/Tracking.cs') (Join-Path $root 'Tests/TrackingTests.cs')
if ($LASTEXITCODE -ne 0) { throw 'Tracking test compilation failed.' }
& $testExe
if ($LASTEXITCODE -ne 0) { throw 'Tracking tests failed.' }
