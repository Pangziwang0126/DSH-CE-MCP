# YQ CE-MCP installer
# 1. drops the Lua plugin into Cheat Engine's autorun folder
# 2. wires the MCP row into every DeepSeek Harness profile
# 3. starts Cheat Engine and verifies the endpoint
param(
    [switch]$NoLaunch,
    [switch]$NoDsh,
    [int]$Port = 8787
)

$ErrorActionPreference = 'Stop'
$PluginFile = 'YQ-CE-MCP.lua'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path

$MdStart = '# >>> yq-ce-mcp'
$MdEnd   = '# <<< yq-ce-mcp <<<'

function Step($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[+] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }

# ---------------------------------------------------------------- CE lookup
Step 'Locating Cheat Engine'
$candidates = New-Object System.Collections.Generic.List[string]

foreach ($d in (Get-PSDrive -PSProvider FileSystem)) {
    if ($d.Root -notmatch '^[A-Za-z]:\\$') { continue }
    try {
        Get-ChildItem -LiteralPath $d.Root -Directory -Filter 'Cheat Engine*' -ErrorAction SilentlyContinue |
            ForEach-Object { $candidates.Add($_.FullName) }
    } catch { }
}
foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if ($base -and (Test-Path $base)) {
        try {
            Get-ChildItem -LiteralPath $base -Directory -Filter 'Cheat Engine*' -ErrorAction SilentlyContinue |
                ForEach-Object { $candidates.Add($_.FullName) }
        } catch { }
    }
}

$ce = $null
foreach ($c in ($candidates | Select-Object -Unique)) {
    if (-not (Test-Path (Join-Path $c 'autorun'))) { continue }
    if ((Test-Path (Join-Path $c 'cheatengine-x86_64.exe')) -or (Test-Path (Join-Path $c 'cheatengine-i386.exe'))) {
        $ce = $c
        break
    }
}

if ($ce -and -not (Test-Path (Join-Path $ce 'cheatengine-x86_64.exe'))) {
    Warn 'Only the 32-bit Cheat Engine build was found.'
    Warn 'The plugin needs the x86_64 build: the 32-bit Lua binding has no executeCodeLocalEx,'
    Warn 'which is what the built-in HTTP server is built on. Install the 64-bit CE to use it.'
}

if (-not $ce) {
    Warn 'Automatic detection failed.'
    $manual = (Read-Host 'Paste the full path to your Cheat Engine folder').Trim('"').Trim()
    if (-not $manual -or -not (Test-Path (Join-Path $manual 'autorun'))) {
        Write-Host '[-] Not a Cheat Engine folder.' -ForegroundColor Red
        exit 1
    }
    $ce = $manual
}
Ok "Cheat Engine: $ce"

$running = Get-Process -Name 'cheatengine-x86_64', 'cheatengine-i386' -ErrorAction SilentlyContinue
if ($running) { Warn 'Cheat Engine is running; the freshly copied plugin loads on next start.' }

# ---------------------------------------------------------------- port check
# Re-running the installer while it is already live must be a no-op, not an error.
# The first request after an idle spell can be slow: Windows throttles timers in
# a background process, so CE's 20 ms pump may take a moment to wake up.
$existing = $false
for ($try = 1; $try -le 3; $try++) {
    try {
        $h = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/health" -UseBasicParsing -TimeoutSec 6
        if ($h.StatusCode -eq 200) { $existing = $true; break }
    } catch {
        if ($try -lt 3) { Start-Sleep -Milliseconds 500 }
        else { Write-Host "    probe: $($_.Exception.Message)" -ForegroundColor DarkGray }
    }
}

if ($existing) {
    Ok "YQ CE-MCP already answering on port $Port (refreshing files, not restarting CE)"
} else {
    $occupier = $null
    try { $occupier = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue } catch { }
    if ($occupier) {
        $ownerPid = @($occupier)[0].OwningProcess
        $ownerName = (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue).ProcessName
        if ($ownerName -like '*cheat*') {
            Warn "Port $Port is held by $ownerName (pid $ownerPid) but the probe did not answer."
            Warn 'That is Cheat Engine with a stale plugin; restart it after this install finishes.'
            $ceHoldsPort = $true
        } else {
            Warn "Port $Port is taken by $ownerName (pid $ownerPid)."
            Write-Host "[-] Free it first, or re-run with -Port <other>." -ForegroundColor Red
            exit 1
        }
    } else {
        Ok "Port $Port is free"
    }
}

# ---------------------------------------------------------------- copy plugin
$src = Join-Path $Here $PluginFile
if (-not (Test-Path $src)) {
    Write-Host "[-] Missing $PluginFile next to this script." -ForegroundColor Red
    exit 1
}

$content = [IO.File]::ReadAllText($src, [Text.Encoding]::UTF8)
if ($Port -ne 8787) {
    $content = $content -replace 'port\s+=\s+8787,', "port           = $Port,"
    Ok "Patched plugin port to $Port"
}

$dst = Join-Path $ce 'autorun\YQ-CE-MCP.lua'
[IO.File]::WriteAllText($dst, $content, (New-Object Text.UTF8Encoding($false)))
Ok "Installed: $dst"

# status dot icons: the plugin looks next to itself first, then %TEMP%
$icons = 0
foreach ($ico in @('yq-on.ico', 'yq-off.ico')) {
    $s = Join-Path $Here $ico
    if (Test-Path $s) {
        Copy-Item -LiteralPath $s -Destination (Join-Path $ce "autorun\$ico") -Force
        Copy-Item -LiteralPath $s -Destination (Join-Path $env:TEMP $ico) -Force
        $icons++
    }
}
if ($icons -eq 2) { Ok 'Status icons installed (green/red title bar dot)' }
else { Warn 'Status icons missing next to the installer; title bar will show text only' }

# ---------------------------------------------------------------- DSH wiring
function Build-Row([int]$port) {
    return @"
# >>> yq-ce-mcp: Cheat Engine MCP server (streamable-http) >>>
# Tools register on the model as mcp__ce__<tool>, e.g. mcp__ce__memory_read.
# Server side: <Cheat Engine>\autorun\YQ-CE-MCP.lua -> http://127.0.0.1:$port/mcp
# Cheat Engine must be running; otherwise this row degrades to "no tools yet"
# and reconnect retries, it never blocks the host from booting.
- insert:
    - id: yq-ce-mcp
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: ce
        transport: streamable-http
        url: http://127.0.0.1:$port/mcp
        toolCallTimeoutMs: 180000
        failOnStartupError: false
        reconnect:
          enabled: true
          initialDelayMs: 1000
          maxDelayMs: 30000
          maxAttempts: 60
# <<< yq-ce-mcp <<<

"@
}

function Set-CeRow {
    param([string]$PatchFile, [int]$Port)
    $text = [IO.File]::ReadAllText($PatchFile, [Text.Encoding]::UTF8)
    if ($null -eq $text) { $text = '' }

    # a profile patch whose root is a bare empty array cannot take an insert entry
    if ($text.Trim() -eq '[]') { $text = '' }

    $had = $text -match [regex]::Escape($MdStart)
    if ($had) {
        # drop the previous block so re-running never stacks duplicates
        $text = [regex]::Replace($text, '(?ms)^# >>> yq-ce-mcp.*?^# <<< yq-ce-mcp <<<[ \t]*\r?\n?', '')
    }

    $text = $text.TrimEnd()
    $row = Build-Row -port $Port
    $new = if ($text.Length -gt 0) { $text + "`r`n`r`n" + $row } else { $row }

    [IO.File]::WriteAllText($PatchFile, $new, (New-Object Text.UTF8Encoding($false)))
    return $had
}

function Test-Row([string]$PatchFile, [int]$Port) {
    try {
        $t = [IO.File]::ReadAllText($PatchFile, [Text.Encoding]::UTF8)
        if ($t -notmatch [regex]::Escape($MdStart)) { return 'block missing' }
        if ($t -notmatch 'serverName:\s*ce') { return 'serverName missing' }
        if ($t -notmatch [regex]::Escape("127.0.0.1:$Port/mcp")) { return 'url port mismatch' }
        $n = ([regex]::Matches($t, 'id:\s*yq-ce-mcp')).Count
        if ($n -ne 1) { return "expected 1 row, found $n" }
        return 'ok'
    } catch { return "read error: $($_.Exception.Message)" }
}

if (-not $NoDsh) {
    Step 'Wiring DeepSeek Harness'
    $dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }

    if (-not (Test-Path $dshHome)) {
        Warn "No DSH home at $dshHome - skipping (use mcp.json for other clients)."
    } else {
        $profilesDir = Join-Path $dshHome 'profiles'
        $patched = 0
        $skipped = 0

        if (Test-Path $profilesDir) {
            foreach ($prof in (Get-ChildItem -LiteralPath $profilesDir -Directory -ErrorAction SilentlyContinue)) {
                $patch = Join-Path $prof.FullName 'cordis.patch.yml'
                if (-not (Test-Path $patch)) { $skipped++; continue }

                $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                Copy-Item -LiteralPath $patch -Destination "$patch.bak-$stamp" -Force

                $replaced = Set-CeRow -PatchFile $patch -Port $Port
                $verdict = Test-Row -PatchFile $patch -Port $Port
                if ($verdict -eq 'ok') {
                    $verb = if ($replaced) { 'updated' } else { 'added' }
                    Ok ("{0}: row {1} in {2}\cordis.patch.yml" -f $prof.Name, $verb, $prof.FullName)
                    $patched++
                } else {
                    Warn ("{0}: verification failed - {1}" -f $prof.Name, $verdict)
                    Warn ("restore from {0}.bak-{1}" -f $patch, $stamp)
                }
            }
        }

        if ($patched -eq 0) {
            Warn 'No usable DSH profile found - only the Cheat Engine side was installed.'
        } elseif ($skipped -gt 0) {
            Warn "$skipped profile(s) had no cordis.patch.yml and were left alone."
        }

        $dsh = Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue
        if ($dsh -and $patched -gt 0) {
            Ok 'DSH is running; the patch layer is watched, the tools appear without a restart.'
        }
    }
}

# ---------------------------------------------------------------- launch CE
if (-not $NoLaunch -and -not $existing) {
    $exe = Join-Path $ce 'cheatengine-x86_64.exe'
    if (-not (Test-Path $exe)) { $exe = Join-Path $ce 'cheatengine-i386.exe' }
    if (-not $running) {
        Step 'Starting Cheat Engine'
        Start-Process -FilePath $exe
    }
    Start-Sleep -Seconds 10
}

# ---------------------------------------------------------------- verify
Step 'Verifying endpoint'
$live = $false
for ($i = 0; $i -lt 6; $i++) {
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/health" -UseBasicParsing -TimeoutSec 3
        if ($r.StatusCode -eq 200) { $live = $true; break }
    } catch { Start-Sleep -Seconds 2 }
}

if ($live) {
    Ok "Server is live: http://127.0.0.1:$Port/mcp"
} else {
    Warn 'Endpoint did not answer.'
    Write-Host "    log: $env:TEMP\yq-ce-mcp.log"
    Write-Host '    If Cheat Engine was already running, close it and run this installer again.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '  Cheat Engine side : ' -NoNewline
Write-Host "http://127.0.0.1:$Port/mcp" -ForegroundColor White
Write-Host '  DeepSeek Harness  : ' -NoNewline
if ($patched -gt 0) { Write-Host 'wired - ask the agent to "read memory at notepad.exe"' -ForegroundColor White }
else { Write-Host 'not wired (no DSH profile found)' -ForegroundColor DarkGray }
Write-Host '  Tools             : 30, registered as mcp__ce__*'
Write-Host ''
