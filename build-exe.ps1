# Builds YQ-CE-MCP-Setup.exe: one file, double-click to install.
# Uses the .NET Framework C# compiler that ships with Windows - no SDK needed.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$files = @(
    'YQ-CE-MCP.lua', 'yq-on.ico', 'yq-off.ico',
    'install.ps1', 'install.bat', 'uninstall.ps1', 'uninstall.bat',
    'bridge.py', 'mcp.json', 'README.md', 'test_mcp.py'
)

$csc = $null
foreach ($v in @('v4.0.30319', 'v3.5', 'v2.0.50727')) {
    $p = Join-Path $env:WINDIR "Microsoft.NET\Framework64\$v\csc.exe"
    if (Test-Path $p) { $csc = $p; break }
}
if (-not $csc) { throw 'csc.exe not found under %WINDIR%\Microsoft.NET\Framework64' }
Write-Host "[*] compiler: $csc" -ForegroundColor Cyan

$out = Join-Path $here 'YQ-CE-MCP-Setup.exe'
if (Test-Path $out) { Remove-Item $out -Force }

$cscArgs = @('/nologo', '/target:exe', '/platform:anycpu', '/reference:System.dll', "/out:$out")
foreach ($f in $files) {
    $p = Join-Path $here $f
    if (-not (Test-Path $p)) { throw "missing payload: $f" }
    $cscArgs += "/resource:$p"
}
$cscArgs += (Join-Path $here 'installer.cs')

& $csc @cscArgs
if ($LASTEXITCODE -ne 0) { throw "csc exited with $LASTEXITCODE" }

$size = (Get-Item $out).Length
Write-Host ("[+] built: {0}  ({1:N0} bytes)" -f $out, $size) -ForegroundColor Green
