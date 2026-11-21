# Removes the YQ CE-MCP plugin and unwires it from DeepSeek Harness.
param(
    [switch]$NoDsh,
    [switch]$NoCe
)

$ErrorActionPreference = 'SilentlyContinue'
$MdStart = '# >>> yq-ce-mcp'

function Ok($m)   { Write-Host "[+] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }

# ---------------------------------------------------------------- Cheat Engine
if (-not $NoCe) {
$targets = New-Object System.Collections.Generic.List[string]
foreach ($d in (Get-PSDrive -PSProvider FileSystem)) {
    if ($d.Root -notmatch '^[A-Za-z]:\\$') { continue }
    Get-ChildItem -LiteralPath $d.Root -Directory -Filter 'Cheat Engine*' -ErrorAction SilentlyContinue |
        ForEach-Object { $targets.Add($_.FullName) }
}
foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if ($base -and (Test-Path $base)) {
        Get-ChildItem -LiteralPath $base -Directory -Filter 'Cheat Engine*' -ErrorAction SilentlyContinue |
            ForEach-Object { $targets.Add($_.FullName) }
    }
}

$removed = 0
foreach ($t in ($targets | Select-Object -Unique)) {
    foreach ($name in @('YQ-CE-MCP.lua', 'yq-on.ico', 'yq-off.ico')) {
        $f = Join-Path $t "autorun\$name"
        if (Test-Path -LiteralPath $f) {
            Remove-Item -LiteralPath $f -Force
            Ok "removed: $f"
            $removed++
        }
    }
}
foreach ($name in @('yq-on.ico', 'yq-off.ico')) {
    Remove-Item -LiteralPath (Join-Path $env:TEMP $name) -Force -ErrorAction SilentlyContinue
}
if ($removed -eq 0) { Warn 'No installed plugin found.' }
}

# ---------------------------------------------------------------- DSH wiring
if (-not $NoDsh) {
    $dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
    $profilesDir = Join-Path $dshHome 'profiles'

    if (Test-Path $profilesDir) {
        foreach ($prof in (Get-ChildItem -LiteralPath $profilesDir -Directory -ErrorAction SilentlyContinue)) {
            $patch = Join-Path $prof.FullName 'cordis.patch.yml'
            if (-not (Test-Path $patch)) { continue }

            $text = [IO.File]::ReadAllText($patch, [Text.Encoding]::UTF8)
            if ($text -notmatch [regex]::Escape($MdStart)) { continue }

            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            Copy-Item -LiteralPath $patch -Destination "$patch.bak-$stamp" -Force

            $text = [regex]::Replace($text, '(?ms)^# >>> yq-ce-mcp.*?^# <<< yq-ce-mcp <<<[ \t]*\r?\n?', '')
            $text = $text.TrimEnd() + "`r`n"
            [IO.File]::WriteAllText($patch, $text, (New-Object Text.UTF8Encoding($false)))
            Ok "unwired DSH profile: $($prof.Name)"
        }
    }
}

Write-Host ''
Warn 'Restart Cheat Engine (and DeepSeek Harness) to drop the server and its tools.'
