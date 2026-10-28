$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$framework = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319'
$compiler = Join-Path $framework 'csc.exe'
if (!(Test-Path -LiteralPath $compiler)) { throw '.NET Framework 4.8 is required.' }
$out = Join-Path $root 'dist'
New-Item -ItemType Directory -Force -Path $out | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'Assets/AppIcon.ico') -Destination (Join-Path $out 'AppIcon.ico') -Force
$references = @('System.dll','System.Core.dll','System.Net.Http.dll','System.Web.Extensions.dll','System.Drawing.dll','System.Windows.Forms.dll','WPF/WindowsBase.dll','WPF/PresentationCore.dll','WPF/PresentationFramework.dll','System.Xaml.dll')
$argsList = @('/nologo','/langversion:5','/warnaserror','/target:winexe','/platform:anycpu','/optimize+','/utf8output',('/out:' + (Join-Path $out 'StockDashboard.exe')),('/win32icon:' + (Join-Path $out 'AppIcon.ico')),('/win32manifest:' + (Join-Path $root 'app.manifest')))
foreach ($reference in $references) { $argsList += '/reference:' + (Join-Path $framework $reference) }
$argsList += Get-ChildItem (Join-Path $root 'Sources') -Filter '*.cs' | ForEach-Object FullName
& $compiler $argsList
if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }
Copy-Item -LiteralPath (Join-Path $root 'App.config') -Destination (Join-Path $out 'StockDashboard.exe.config') -Force
Copy-Item -LiteralPath (Join-Path $root 'README.md') -Destination (Join-Path $out 'README.md') -Force
Write-Output ('Built: ' + (Join-Path $out 'StockDashboard.exe'))
