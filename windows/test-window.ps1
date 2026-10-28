$ErrorActionPreference = 'Stop'
$framework = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319'
$testDirectory = Join-Path $PSScriptRoot 'work/window-tests'
New-Item -ItemType Directory -Force -Path $testDirectory | Out-Null
$references = @('System.dll','System.Core.dll','System.Net.Http.dll','System.Web.Extensions.dll','System.Drawing.dll','System.Windows.Forms.dll','WPF/WindowsBase.dll','WPF/PresentationCore.dll','WPF/PresentationFramework.dll','System.Xaml.dll')
$argsList = @('/nologo','/langversion:5','/target:exe','/main:WindowTests',('/out:' + (Join-Path $testDirectory 'WindowTests.exe')))
foreach ($reference in $references) { $argsList += '/reference:' + (Join-Path $framework $reference) }
$argsList += Get-ChildItem (Join-Path $PSScriptRoot 'Sources') -Filter '*.cs' | ForEach-Object FullName
$argsList += Join-Path $PSScriptRoot 'Tests/WindowTests.cs'
& (Join-Path $framework 'csc.exe') $argsList
if ($LASTEXITCODE -ne 0) { throw 'Window test compilation failed.' }
& (Join-Path $testDirectory 'WindowTests.exe')
if ($LASTEXITCODE -ne 0) { throw 'Window integration tests failed.' }
