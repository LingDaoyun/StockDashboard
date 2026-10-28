$ErrorActionPreference = 'Stop'
$framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
if (-not (Test-Path -LiteralPath (Join-Path $framework 'csc.exe'))) {
    $framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319'
}
$testDirectory = Join-Path $PSScriptRoot 'work\desktop-tests'
New-Item -ItemType Directory -Force -Path $testDirectory | Out-Null
$references = @('System.dll', 'System.Core.dll', 'System.Xaml.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll', 'WPF\WindowsBase.dll', 'WPF\PresentationCore.dll', 'WPF\PresentationFramework.dll')
foreach ($testName in @('DesktopGeometryTests', 'DesktopLifecycleTests')) {
    $testExecutable = Join-Path $testDirectory ($testName + '.exe')
    $compilerArguments = @('/nologo', '/warnaserror', '/langversion:5', '/target:exe', ('/out:' + $testExecutable))
    foreach ($reference in $references) { $compilerArguments += '/reference:' + (Join-Path $framework $reference) }
    $compilerArguments += Join-Path $PSScriptRoot 'Sources\DesktopIntegration.cs'
    $compilerArguments += Join-Path (Join-Path $PSScriptRoot 'Tests') ($testName + '.cs')
    & (Join-Path $framework 'csc.exe') $compilerArguments
    if ($LASTEXITCODE -ne 0) { throw "$testName compilation failed." }
    & $testExecutable
    if ($LASTEXITCODE -ne 0) { throw "$testName failed." }
}
