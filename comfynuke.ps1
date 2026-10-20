#Requires -Version 5.1
<#
.SYNOPSIS
  ComfyNuke: installs, updates and repairs ComfyUI + ComfyUI-for-Nuke on Windows.

.DESCRIPTION
  Design rules (why it is built this way):
  - Self-contained: everything lives in one folder (default C:\ComfyNuke) with its own
    Git, uv and Python. Nothing system-wide is installed or upgraded, no admin rights needed.
  - Pinned: versions come from versions.json (tested pins). Nothing is upgraded unless
    the user picks it in `update`, one component at a time.
  - Reversible: every install/update/rollback takes a snapshot first (git commits,
    pip freeze, menu.py), so `rollback` can return to any earlier state.
  - Traceable: each run writes a log to %LOCALAPPDATA%\ComfyNuke\logs and prints a
    list of what was installed, updated, backed up or removed.

.EXAMPLE
  .\comfynuke.ps1              # interactive menu
  .\comfynuke.ps1 install      # install or repair
  .\comfynuke.ps1 update       # choose what to update (tested versions)
  .\comfynuke.ps1 update -Latest   # also offer newest upstream versions (untested)
  .\comfynuke.ps1 install -DryRun  # show the plan, change nothing
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'install', 'update', 'status', 'start', 'rollback', 'doctor', 'uninstall', 'models', 'hf-login', 'self-update', 'help')]
    [string]$Command = 'menu',
    [string]$Root,       # install folder; remembered after the first install
    [switch]$Latest,     # update: also offer upstream versions newer than the tested pins
    [switch]$DryRun,     # show the plan only
    [switch]$Yes         # take the default answer for every question (testing)
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# ----------------------------------------------------------------------------
# Constants
# ----------------------------------------------------------------------------
$AppVersion = '0.1.0'
$RepoSlug   = 'amsyeung/comfyui-nuke-setup'      # GitHub repo used by self-update
$AppDir     = $PSScriptRoot
$Manifest   = Get-Content -Raw -Encoding UTF8 (Join-Path $AppDir 'versions.json') | ConvertFrom-Json
$DataDir    = Join-Path $env:LOCALAPPDATA 'ComfyNuke'
$LogDir     = Join-Path $DataDir 'logs'
$ConfigFile = Join-Path $DataDir 'config.json'   # remembers where ComfyNuke was installed
$NukeHome   = if ($env:HOME) { Join-Path $env:HOME '.nuke' } else { Join-Path $env:USERPROFILE '.nuke' }
$DefaultRoot = 'C:\ComfyNuke'
$Port       = 8188
$BlockStart = '# >>> comfynuke >>>'
$BlockEnd   = '# <<< comfynuke <<<'

$Changes = New-Object System.Collections.ArrayList
$ClearedEnv = @()   # PYTHON*/UV_* variables found in this user's environment (ignored)
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$RunId   = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFile = Join-Path $LogDir "$RunId-$Command.log"

# ----------------------------------------------------------------------------
# Logging, change list and prompts
# ----------------------------------------------------------------------------
function Write-Log([string]$Message, [string]$Level = 'INFO') {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    switch ($Level) {
        'STEP'  { Write-Host ''; Write-Host "==> $Message" -ForegroundColor Cyan }
        'OK'    { Write-Host "    $Message" -ForegroundColor Green }
        'WARN'  { Write-Host "    ! $Message" -ForegroundColor Yellow }
        'ERROR' { Write-Host "    x $Message" -ForegroundColor Red }
        'DEBUG' { Write-Host "    $Message" -ForegroundColor DarkGray }
        default { Write-Host "    $Message" }
    }
}

# Kind is shown to the user: Install / Update / Config / Backup / Restore / Delete
function Add-Change([string]$Kind, [string]$Item, [string]$Detail) {
    [void]$Changes.Add([pscustomobject]@{ Kind = $Kind; Item = $Item; Detail = $Detail })
    Write-Log ('[{0}] {1}  {2}' -f $Kind, $Item, $Detail) 'OK'
}

function Show-Summary {
    Write-Host ''
    Write-Host '==================== Changes in this run ====================' -ForegroundColor Cyan
    $lines = @()
    if ($Changes.Count -eq 0) {
        $lines = @('(no changes)')
    } else {
        $lines = $Changes | ForEach-Object { '{0,-8} {1,-28} {2}' -f $_.Kind, $_.Item, $_.Detail }
    }
    $lines | ForEach-Object { Write-Host "  $_" }
    Add-Content -LiteralPath $LogFile -Value (@('', '--- summary ---') + $lines) -Encoding UTF8
    # history.log keeps one block per run next to the install, so changes stay easy to trace
    if ($script:Root -and (Test-Path $script:Root) -and $Changes.Count -gt 0) {
        $hist = @('', "[$RunId] $Command (app $AppVersion, manifest $($Manifest.manifestVersion))") + ($lines | ForEach-Object { "  $_" })
        Add-Content -LiteralPath (Join-Path $script:Root 'history.log') -Value $hist -Encoding UTF8
    }
    Write-Host ''
    Write-Host "  Full log: $LogFile" -ForegroundColor DarkGray
}

function Read-YesNo([string]$Question, [bool]$Default = $false) {
    if ($Yes) { return $Default }
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $a = "$(Read-Host "    $Question $hint")".Trim().ToLower()
        Add-Content -LiteralPath $LogFile -Value "    Q: $Question -> '$a'" -Encoding UTF8
        if ($a -eq '') { return $Default }
        if ($a -in @('y', 'yes')) { return $true }
        if ($a -in @('n', 'no')) { return $false }
        Write-Host '    Please type y (yes) or n (no)'
    }
}

function Read-Text([string]$Question, [string]$Default) {
    if ($Yes) { return $Default }
    $a = "$(Read-Host "    $Question [$Default]")".Trim()
    Add-Content -LiteralPath $LogFile -Value "    Q: $Question -> '$a'" -Encoding UTF8
    if ($a -eq '') { return $Default }
    return $a.Trim('"')
}

# ----------------------------------------------------------------------------
# Running external programs (output goes to the console and the log)
# ----------------------------------------------------------------------------
function Invoke-Native([string]$Exe, [string[]]$ArgList = @(), [string]$WorkDir) {
    Write-Log ('> {0} {1}' -f (Split-Path $Exe -Leaf), ($ArgList -join ' ')) 'DEBUG'
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # native stderr must not abort the script (PowerShell 5.1)
    if ($WorkDir) { Push-Location $WorkDir }
    try {
        & $Exe @ArgList 2>&1 | ForEach-Object {
            $t = "$_"
            if ($t.Trim()) {
                Add-Content -LiteralPath $LogFile -Value "      $t" -Encoding UTF8
                Write-Host "      $t" -ForegroundColor DarkGray
            }
        }
        $code = $LASTEXITCODE
    } finally {
        if ($WorkDir) { Pop-Location }
        $ErrorActionPreference = $old
    }
    if ($code -ne 0) { throw ('{0} failed (exit code {1}), see the log for details' -f (Split-Path $Exe -Leaf), $code) }
}

function Get-NativeOutput([string]$Exe, [string[]]$ArgList = @(), [switch]$AllowFail) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & $Exe @ArgList 2>$null; $code = $LASTEXITCODE }
    catch { $out = @(); $code = 1 }
    finally { $ErrorActionPreference = $old }
    if ($code -ne 0 -and -not $AllowFail) { throw ('{0} {1} failed' -f (Split-Path $Exe -Leaf), ($ArgList -join ' ')) }
    if ($code -ne 0) { return @() }
    return @($out | ForEach-Object { "$_" })
}

function Save-Download([string]$Url, [string]$OutFile, [string]$Sha256) {
    Write-Log "Downloading $Url" 'DEBUG'
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path $curl) {
        Invoke-Native $curl @('-L', '--fail', '--retry', '3', '--silent', '--show-error', '-o', $OutFile, $Url)
    } else {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
    }
    if ($Sha256) {
        $hash = (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash.ToLower()
        if ($hash -ne $Sha256.ToLower()) {
            Remove-Item -LiteralPath $OutFile -Force
            throw "The downloaded file failed its safety check (SHA256 mismatch): $Url"
        }
    }
}

# tar.exe (built into Windows 10 1803+) unpacks large zips much faster than Expand-Archive
function Expand-Zip([string]$Zip, [string]$Dest) {
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (Test-Path $tar) { Invoke-Native $tar @('-xf', $Zip, '-C', $Dest) }
    else { Expand-Archive -LiteralPath $Zip -DestinationPath $Dest -Force }
}

# ----------------------------------------------------------------------------
# Paths, settings and state
# ----------------------------------------------------------------------------
function Get-SavedRoot {
    if (Test-Path $ConfigFile) { return (Get-Content -Raw -Encoding UTF8 $ConfigFile | ConvertFrom-Json).root }
    return $null
}

function Set-Paths {
    # Another Python on this PC must never leak in: PYTHONHOME/PYTHONPATH change even a venv's
    # Python, and UV_* settings change where packages come from. Cleared for this process only.
    $found = @(Get-ChildItem env: | Where-Object { $_.Name -match '^(PYTHON|UV_)' -or $_.Name -in @('VIRTUAL_ENV', 'CONDA_PREFIX') } | ForEach-Object { $_.Name })
    foreach ($n in $found) { Remove-Item -LiteralPath "env:$n" -ErrorAction SilentlyContinue }
    if ($found.Count) { $script:ClearedEnv = @($script:ClearedEnv + $found | Select-Object -Unique) }
    $env:PYTHONUTF8 = '1'
    $script:P = @{
        Tools     = Join-Path $Root 'tools'
        Git       = Join-Path $Root 'tools\git\cmd\git.exe'
        Comfy     = Join-Path $Root 'ComfyUI'
        Venv      = Join-Path $Root 'ComfyUI\.venv'
        Py        = Join-Path $Root 'ComfyUI\.venv\Scripts\python.exe'
        Snapshots = Join-Path $Root 'snapshots'
        Backups   = Join-Path $Root 'backups'
        App       = Join-Path $Root 'app'
        State     = Join-Path $Root 'state.json'
        Constrain = Join-Path $Root 'tools\torch-constraints.txt'
        NukeLibs  = Join-Path $NukeHome 'comfynuke_libs'
        MenuPy    = Join-Path $NukeHome 'menu.py'
    }
    # Private tools only: uv keeps Python and its cache inside the install folder
    $env:UV_PYTHON_INSTALL_DIR = Join-Path $Root 'tools\python'
    $env:UV_CACHE_DIR          = Join-Path $Root 'tools\uv-cache'
    $env:UV_PYTHON_PREFERENCE  = 'only-managed'
    $env:UV_NO_PROGRESS        = '1'
    # Never put python.exe in ~\.local\bin (on PATH) or register it in the Windows registry
    $env:UV_PYTHON_INSTALL_BIN      = '0'
    $env:UV_PYTHON_INSTALL_REGISTRY = '0'
    $env:GIT_TERMINAL_PROMPT   = '0'
    # Git settings for this process only (never written to the user's global config)
    $env:GIT_CONFIG_COUNT   = '2'
    $env:GIT_CONFIG_KEY_0   = 'core.longpaths'; $env:GIT_CONFIG_VALUE_0 = 'true'
    $env:GIT_CONFIG_KEY_1   = 'advice.detachedHead'; $env:GIT_CONFIG_VALUE_1 = 'false'
    $env:PATH = (Join-Path $Root 'tools\git\cmd') + ';' + $env:PATH
}

function Get-UvExe {
    $f = Get-ChildItem -LiteralPath (Join-Path $Root 'tools\uv') -Recurse -Filter 'uv.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { return $f.FullName }
    return $null
}

function Set-Prop($Obj, [string]$Name, $Value) {
    $Obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Read-State {
    if (Test-Path $P.State) { return Get-Content -Raw -Encoding UTF8 $P.State | ConvertFrom-Json }
    return [pscustomobject]@{
        appVersion = $AppVersion; manifestVersion = ''; root = $Root
        installedAt = (Get-Date).ToString('s'); updatedAt = ''
        tools = [pscustomobject]@{}; python = ''; torch = [pscustomobject]@{}
        repos = [pscustomobject]@{}; nukeLibs = [pscustomobject]@{}
    }
}

function Save-State($State) {
    Set-Prop $State 'appVersion' $AppVersion
    Set-Prop $State 'updatedAt' (Get-Date).ToString('s')
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $P.State -Encoding UTF8
}

function Get-RepoDir([string]$Template) {
    return ($Template -replace '\{comfy\}', $P.Comfy -replace '\{nuke\}', $NukeHome) -replace '/', '\'
}

# ----------------------------------------------------------------------------
# Detection: GPU, Nuke, running processes
# ----------------------------------------------------------------------------
function ConvertTo-Number([string]$s) {
    $d = 0.0
    if ([double]::TryParse("$s".Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    return 0.0
}

function Get-GpuInfo {
    $smi = (Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue).Source
    if (-not $smi) {
        $c = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
        if (Test-Path $c) { $smi = $c }
    }
    if ($smi) {
        $line = Get-NativeOutput $smi @('--query-gpu=name,driver_version,compute_cap,memory.total', '--format=csv,noheader,nounits') -AllowFail | Select-Object -First 1
        $f = @("$line" -split ',\s*')
        if ($f.Count -ge 4) {
            $cc = ConvertTo-Number $f[2]
            if ($cc -eq 0) {
                # Old drivers cannot report compute capability: guess from the name
                $cc = 8.6
                if ($f[0] -match 'RTX\s*50\d\d|Blackwell') { $cc = 12.0 }
                elseif ($f[0] -match 'GTX|Quadro P|Tesla P') { $cc = 6.1 }
            }
            return [pscustomobject]@{
                Vendor = 'NVIDIA'; Name = $f[0]; Driver = (ConvertTo-Number $f[1])
                ComputeCap = $cc; VramGB = [math]::Round((ConvertTo-Number $f[3]) / 1024, 1)
            }
        }
    }
    $cards = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'Microsoft|Remote|Virtual' })
    $card = $cards | Select-Object -First 1
    $vendor = 'None'
    if ($card) {
        if ($card.Name -match 'NVIDIA') { $vendor = 'NVIDIA-NoDriver' }
        elseif ($card.Name -match 'AMD|Radeon') { $vendor = 'AMD' }
        elseif ($card.Name -match 'Intel') { $vendor = 'Intel' }
        else { $vendor = 'Other' }
    }
    $name = if ($card) { $card.Name } else { '(not detected)' }
    return [pscustomobject]@{ Vendor = $vendor; Name = $name; Driver = 0; ComputeCap = 0; VramGB = 0 }
}

function Select-TorchVariant($Gpu) {
    $variants = @($Manifest.torch.variants)
    if ($Gpu.Vendor -ne 'NVIDIA') { return $variants | Where-Object { $_.name -eq 'cpu' } | Select-Object -First 1 }
    foreach ($v in $variants) {
        if ($v.name -eq 'cpu') { continue }
        if ($Gpu.Driver -ge $v.minDriver -and $Gpu.ComputeCap -ge $v.minComputeCap -and $Gpu.ComputeCap -le $v.maxComputeCap) { return $v }
    }
    return $null   # NVIDIA card but the driver is too old for every CUDA build
}

function Find-Nuke {
    $found = @()
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $base -or -not (Test-Path $base)) { continue }
        foreach ($d in Get-ChildItem -LiteralPath $base -Directory -Filter 'Nuke*' -ErrorAction SilentlyContinue) {
            $exe = Get-ChildItem -LiteralPath $d.FullName -Filter 'Nuke*.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
            $py = Join-Path $d.FullName 'python.exe'
            if (-not $exe -or -not (Test-Path $py)) { continue }
            $ver = Get-NativeOutput $py @('-c', "import sys; print('%d.%d' % sys.version_info[:2])") -AllowFail | Select-Object -First 1
            $major = 0
            if ($d.Name -match 'Nuke(\d+)') { $major = [int]$Matches[1] }
            $found += [pscustomobject]@{ Name = $d.Name; Dir = $d.FullName; Major = $major; Python = "$ver".Trim() }
        }
    }
    return $found
}

# Which device PyTorch will use, written to screen and log (for "why is it slow?" questions)
function Write-ComputeDevice {
    if (-not (Test-Path $P.Py)) { return '' }
    $code = "import torch; c = torch.cuda.is_available(); print(('cuda|' + torch.cuda.get_device_name(0)) if c else 'cpu|', torch.__version__)"
    $out = "$(Get-NativeOutput $P.Py @('-c', $code) -AllowFail | Select-Object -First 1)"
    if ($out -match '^cuda\|(.+) (\S+)$') {
        Write-Log "Compute device: GPU (CUDA) — $($Matches[1]), torch $($Matches[2])" 'OK'
        return 'cuda'
    }
    if ($out -match '^cpu\| (\S+)$') {
        Write-Log "Compute device: CPU (your graphics card is not being used, so generating will be very slow), torch $($Matches[1])" 'WARN'
        return 'cpu'
    }
    Write-Log 'Compute device: unknown (PyTorch could not be loaded)' 'WARN'
    return ''
}

# Live GPU load from nvidia-smi
function Write-GpuLoad {
    $smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
    if (-not (Test-Path $smi)) { return }
    $line = Get-NativeOutput $smi @('--query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,driver_version', '--format=csv,noheader,nounits') -AllowFail | Select-Object -First 1
    $f = @("$line" -split ',\s*')
    if ($f.Count -ge 6) { Write-Log ("Graphics card status: {0}, usage {1}%, VRAM {2}/{3} MB, {4}°C, driver {5}" -f $f[0], $f[1], $f[2], $f[3], $f[4], $f[5]) }
}

# What a running ComfyUI reports about itself (the most reliable answer to "GPU or CPU?")
function Write-ComfyDevice {
    try { $s = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/system_stats" -TimeoutSec 2 } catch { return }
    foreach ($d in @($s.devices)) {
        $kind = if ($d.type -eq 'cpu') { 'WARN' } else { 'OK' }
        Write-Log ("ComfyUI is using: {0} ({1}), VRAM free {2:N1}/{3:N1} GB" -f $d.name, $d.type, ($d.vram_free / 1GB), ($d.vram_total / 1GB)) $kind
    }
}

# Logs are small, but keep them bounded: 90 days and at most 200 files
function Remove-OldLogs {
    $logs = @(Get-ChildItem -LiteralPath $LogDir -Filter '*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    $cutoff = (Get-Date).AddDays(-90)
    $old = @($logs | Select-Object -Skip 200) + @($logs | Select-Object -First 200 | Where-Object { $_.LastWriteTime -lt $cutoff })
    if ($old.Count) {
        $old | Remove-Item -Force -ErrorAction SilentlyContinue
        Write-Log "Cleaned up $($old.Count) old logs (older than 90 days or beyond the newest 200)" 'DEBUG'
    }
}

# ComfyUI declares its minimum Python in pyproject.toml; check it before moving to a new commit
function Test-PythonRequirement([string]$Dir, [string]$Commit, [string]$Python) {
    if (-not $Python) { return $true }
    $toml = (Get-NativeOutput $P.Git @('-C', $Dir, 'show', "${Commit}:pyproject.toml") -AllowFail) -join "`n"
    $m = [regex]::Match($toml, 'requires-python\s*=\s*"\s*>=\s*(\d+\.\d+)')
    if (-not $m.Success) { return $true }
    $script:RequiredPython = $m.Groups[1].Value
    return ([version]($Python -replace '^(\d+\.\d+).*', '$1') -ge [version]$m.Groups[1].Value)
}

function Get-RunningBlockers {
    $list = @()
    $nuke = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^Nuke\d' })
    if ($nuke.Count) { $list += 'Nuke is running' }
    if ($Root) {
        $py = @(Get-Process python, pythonw -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase) })
        if ($py.Count) { $list += 'ComfyUI is running (the black window)' }
    }
    return $list
}

function Wait-ForClosedApps {
    while ($true) {
        $b = @(Get-RunningBlockers)
        if ($b.Count -eq 0) { return }
        Write-Log ('Please close first: ' + ($b -join ', ') + ', then press Enter to continue') 'WARN'
        if ($Yes) { throw 'Some programs are still running, cannot continue' }
        [void](Read-Host '    Press Enter after closing')
    }
}

# ----------------------------------------------------------------------------
# Building blocks
# ----------------------------------------------------------------------------
function Install-Tool([string]$Name) {
    $t = $Manifest.tools.$Name
    $dest = Join-Path $P.Tools $Name
    $dl = Join-Path $P.Tools '_download'
    New-Item -ItemType Directory -Force -Path $dl | Out-Null
    $zip = Join-Path $dl "$Name-$($t.version).zip"
    Save-Download $t.url $zip $t.sha256
    $staging = "$dest.new"
    if (Test-Path $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    Expand-Zip $zip $staging
    $existed = Test-Path $dest
    if ($existed) { Remove-Item -LiteralPath $dest -Recurse -Force }   # only our own private copy
    Rename-Item -LiteralPath $staging -NewName $Name
    Remove-Item -LiteralPath $zip -Force
    $kind = if ($existed) { 'Update' } else { 'Install' }
    Add-Change $kind $Name "$($t.version) (private copy for ComfyNuke, does not affect your system)"
}

function Install-Python($State) {
    $uv = Get-UvExe
    $ver = $Manifest.tools.python.version
    Invoke-Native $uv @('python', 'install', '--no-bin', '--no-registry', $ver)
    if (Test-Path $P.Venv) {
        Remove-Item -LiteralPath $P.Venv -Recurse -Force
        Add-Change 'Delete' 'ComfyUI Python environment' 'Old environment (rebuilt right away)'
    }
    Invoke-Native $uv @('venv', '--seed', '--python', $ver, $P.Venv)
    Set-Prop $State 'python' $ver
    Set-Prop $State 'torch' ([pscustomobject]@{})   # a new environment needs torch again
    Add-Change 'Install' 'Python' "$ver (used only by ComfyUI)"
}

function Install-Torch($State, $Variant) {
    $uv = Get-UvExe
    Write-Log 'Downloading PyTorch (about 2-3 GB). The screen may not change for several minutes; this is normal.' 'WARN'
    Invoke-Native $uv @('pip', 'install', '--python', $P.Py, "torch==$($Variant.torch)", 'torchvision', 'torchaudio', '--index-url', $Variant.index)
    # Pin the exact torch build so later requirement installs never swap it out
    $freeze = Get-NativeOutput $uv @('pip', 'freeze', '--python', $P.Py)
    $freeze | Where-Object { $_ -match '^(torch|torchvision|torchaudio)==' } | Set-Content -LiteralPath $P.Constrain -Encoding ASCII
    $old = $State.torch.version
    Set-Prop $State 'torch' ([pscustomobject]@{ variant = $Variant.name; version = $Variant.torch; index = $Variant.index })
    $kind = if ($old) { 'Update' } else { 'Install' }
    Add-Change $kind 'PyTorch' "$($Variant.torch) ($($Variant.name))"
}

function Install-Requirements([string]$Dir, [string]$Label) {
    $req = Join-Path $Dir 'requirements.txt'
    if (-not (Test-Path $req)) { return }
    $args2 = @('pip', 'install', '--python', $P.Py, '-r', $req)
    if (Test-Path $P.Constrain) { $args2 += @('--constraint', $P.Constrain) }
    Invoke-Native (Get-UvExe) $args2
    Write-Log "Python packages for $Label are ready" 'OK'
}

# Clone or move a git repo to an exact commit. Local edits are stashed, never lost.
function Sync-Repo([string]$Key, [string]$Commit, [string]$Ref, $State) {
    $r = $Manifest.repos.$Key
    $dir = Get-RepoDir $r.dir
    $git = $P.Git
    $before = $null
    if (Test-Path (Join-Path $dir '.git')) {
        $before = (Get-NativeOutput $git @('-C', $dir, 'rev-parse', 'HEAD') -AllowFail | Select-Object -First 1)
        if ($before -eq $Commit) { Write-Log "$($r.label) is already at $Ref" 'DEBUG'; return $false }
        $dirty = Get-NativeOutput $git @('-C', $dir, 'status', '--porcelain', '--ignore-submodules') -AllowFail
        if ($dirty) {
            Invoke-Native $git @('-C', $dir, 'stash', 'push', '--include-untracked', '-m', "comfynuke-$RunId")
            Add-Change 'Backup' $r.label "Your local changes were set aside (git stash: comfynuke-$RunId)"
        }
        Invoke-Native $git @('-C', $dir, 'fetch', '--tags', '--force', 'origin')
        if ($r.requirements -and -not (Test-PythonRequirement $dir $Commit $State.python)) {
            throw ("{0} {1} needs Python {2} or newer, but this install has {3}. Please update Python first (wait for a new tested version in versions.json), or pick a version that has been tested." -f $r.label, $Ref, $script:RequiredPython, $State.python)
        }
    } else {
        if (Test-Path $dir) {
            # A folder that is not ours (e.g. an old manual install): keep it as a backup
            $bak = "$dir.backup-$RunId"
            Rename-Item -LiteralPath $dir -NewName (Split-Path $bak -Leaf)
            Add-Change 'Backup' $r.label "Old folder renamed to $(Split-Path $bak -Leaf)"
        }
        New-Item -ItemType Directory -Force -Path (Split-Path $dir -Parent) | Out-Null
        Invoke-Native $git @('clone', '--filter=blob:none', '--no-checkout', $r.url, $dir)
    }
    Invoke-Native $git @('-C', $dir, 'checkout', '--force', '--quiet', $Commit)
    if ($r.submodules) { Invoke-Native $git @('-C', $dir, 'submodule', 'update', '--init', '--recursive', '--force') }
    if ($r.requirements) { Install-Requirements $dir $r.label }
    Set-Prop $State.repos $Key ([pscustomobject]@{ ref = $Ref; commit = $Commit })
    $kind = if ($before) { 'Update' } else { 'Install' }
    Add-Change $kind $r.label "$Ref ($($Commit.Substring(0, 8)))"
    return $true
}

# websocket-client etc. for Nuke's own Python, installed into ~/.nuke (no admin needed)
function Install-NukeLibs($State, [string[]]$PyVersions, [switch]$Force) {
    $uv = Get-UvExe
    foreach ($v in $PyVersions) {
        $key = 'py' + ($v -replace '\.', '')
        $dir = Join-Path $P.NukeLibs $key
        $want = ($Manifest.nukeLibs -join ',')
        if (-not $Force -and (Test-Path $dir) -and $State.nukeLibs.$key -eq $want) { continue }
        $tmp = "$dir.new"
        if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
        Invoke-Native $uv (@('pip', 'install', '--target', $tmp, '--python', $P.Py, '--python-version', $v,
                '--python-platform', 'x86_64-pc-windows-msvc', '--only-binary', ':all:', '--quiet') + @($Manifest.nukeLibs))
        $existed = Test-Path $dir
        if ($existed) { Remove-Item -LiteralPath $dir -Recurse -Force }
        Rename-Item -LiteralPath $tmp -NewName $key
        Set-Prop $State.nukeLibs $key $want
        $kind = if ($existed) { 'Update' } else { 'Install' }
        Add-Change $kind "Nuke connection packages (Python $v)" ($Manifest.nukeLibs -join ', ')
    }
}

function Get-MenuBlock {
    $lib = ($P.NukeLibs -replace '\\', '/')
    $in = ((Join-Path $P.Comfy 'input') -replace '\\', '/')
    $out = ((Join-Path $P.Comfy 'output') -replace '\\', '/')
    return @"
$BlockStart
# Managed by ComfyNuke (https://github.com/$RepoSlug). Changes inside this block are overwritten.
try:
    import os, sys
    _cn_lib = '$lib/py%d%d' % sys.version_info[:2]
    if os.path.isdir(_cn_lib) and _cn_lib not in sys.path:
        sys.path.insert(0, _cn_lib)  # ahead of any PYTHONPATH packages, so the pinned versions win
    os.environ.setdefault('NUKE_COMFYUI_URL', '127.0.0.1:$Port')
    os.environ.setdefault('INPUT_DIRECTORY', '$in')
    os.environ.setdefault('OUTPUT_DIRECTORY', '$out')
    import comfyui2nuke as comfyui
    comfyui.setup()
except Exception as _cn_err:
    import traceback
    traceback.print_exc()
    print('[ComfyNuke] ComfyUI menu not loaded: %s' % _cn_err)
$BlockEnd
"@
}

function Set-MenuBlock {
    New-Item -ItemType Directory -Force -Path $NukeHome | Out-Null
    $old = ''
    if (Test-Path $P.MenuPy) { $old = [IO.File]::ReadAllText($P.MenuPy) }
    $pattern = '(?s)\r?\n?' + [regex]::Escape($BlockStart) + '.*?' + [regex]::Escape($BlockEnd) + '\r?\n?'
    $base = [regex]::Replace($old, $pattern, "`n").TrimEnd()
    $new = $base + $(if ($base) { "`n`n" } else { '' }) + (Get-MenuBlock).Replace("`r`n", "`n") + "`n"
    if ($new -eq $old) { return }
    if ($old) {
        New-Item -ItemType Directory -Force -Path $P.Backups | Out-Null
        Copy-Item -LiteralPath $P.MenuPy -Destination (Join-Path $P.Backups "menu.py.$RunId") -Force
        Add-Change 'Backup' 'menu.py' "backups\menu.py.$RunId"
    }
    [IO.File]::WriteAllText($P.MenuPy, $new, (New-Object Text.UTF8Encoding $false))
    Add-Change 'Config' 'Nuke menu.py' 'Added the ComfyUI menu (only the marked section is touched)'
}

function Remove-MenuBlock {
    if (-not (Test-Path $P.MenuPy)) { return }
    $old = [IO.File]::ReadAllText($P.MenuPy)
    if ($old -notmatch [regex]::Escape($BlockStart)) { return }
    New-Item -ItemType Directory -Force -Path $P.Backups | Out-Null
    Copy-Item -LiteralPath $P.MenuPy -Destination (Join-Path $P.Backups "menu.py.$RunId") -Force
    $pattern = '(?s)\r?\n?' + [regex]::Escape($BlockStart) + '.*?' + [regex]::Escape($BlockEnd) + '\r?\n?'
    [IO.File]::WriteAllText($P.MenuPy, ([regex]::Replace($old, $pattern, "`n").TrimEnd() + "`n"), (New-Object Text.UTF8Encoding $false))
    Add-Change 'Delete' 'Nuke menu.py' 'Removed the ComfyNuke section (original file backed up)'
}

# Creates or fixes a shortcut; returns $true when something changed
function Set-Shortcut([string]$Path, [string]$Target, [string]$WorkDir, [string]$Icon) {
    $ws = New-Object -ComObject WScript.Shell
    $s = $ws.CreateShortcut($Path)
    $want = "$Icon,0"
    if ((Test-Path $Path) -and $s.TargetPath -eq $Target -and $s.IconLocation -eq $want) { return $false }
    $s.TargetPath = $Target
    $s.WorkingDirectory = $WorkDir
    $s.IconLocation = $want
    $s.Save()
    return $true
}

# Builds a multi-size .ico from a PNG (PNG-compressed entries, supported since Windows Vista)
function ConvertTo-Ico([string]$Png, [string]$Ico) {
    Add-Type -AssemblyName System.Drawing
    $src = [Drawing.Image]::FromFile($Png)
    try {
        $entries = foreach ($s in 256, 64, 48, 32, 16) {
            $bmp = New-Object Drawing.Bitmap $s, $s
            $g = [Drawing.Graphics]::FromImage($bmp)
            $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.DrawImage($src, 0, 0, $s, $s)
            $g.Dispose()
            $ms = New-Object IO.MemoryStream
            $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
            , @($s, $ms.ToArray())
        }
    } finally { $src.Dispose() }
    $w = New-Object IO.BinaryWriter ([IO.File]::Create($Ico))
    try {
        $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$entries.Count)
        $offset = 6 + 16 * $entries.Count
        foreach ($e in $entries) {
            $px = [byte]($e[0] % 256)   # 0 means 256 in the ICO format
            $w.Write($px); $w.Write($px); $w.Write([byte]0); $w.Write([byte]0)
            $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$e[1].Length); $w.Write([uint32]$offset)
            $offset += $e[1].Length
        }
        foreach ($e in $entries) { $w.Write([byte[]]$e[1]) }
    } finally { $w.Close() }
}

# Icons: ComfyNuke's own (shipped in assets\), and ComfyUI's logo taken from the installed ComfyUI
function Get-LauncherIcons {
    $dir = Join-Path $P.App 'assets'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $tool = Join-Path $dir 'comfynuke.ico'
    if (-not (Test-Path $tool)) { $tool = Join-Path $AppDir 'assets\comfynuke.ico' }
    $comfy = Join-Path $dir 'comfyui.ico'
    if (-not (Test-Path $comfy)) {
        $static = Join-Path $P.Venv 'Lib\site-packages\comfyui_frontend_package\static\assets'
        $png = Join-Path $static 'images\comfy-icon-512.png'
        try {
            if (Test-Path $png) { ConvertTo-Ico $png $comfy }
            elseif (Test-Path (Join-Path $static 'favicon.ico')) { Copy-Item -LiteralPath (Join-Path $static 'favicon.ico') -Destination $comfy }
        } catch { Write-Log "Could not make the ComfyUI icon: $($_.Exception.Message)" 'DEBUG' }
        if (-not (Test-Path $comfy)) { $comfy = $tool }
    }
    return @{ Tool = $tool; Comfy = $comfy }
}

function Install-Launchers {
    # Keep a copy of this tool inside the install folder so it works after the download is deleted
    if ((Resolve-Path $AppDir).Path.TrimEnd('\') -ne $P.App.TrimEnd('\')) {
        New-Item -ItemType Directory -Force -Path $P.App | Out-Null
        foreach ($f in @('comfynuke.ps1', 'model_sorter.py', 'model_download.py', 'versions.json', 'ComfyNuke.bat', 'README.md', 'CHANGELOG.md')) {
            $src = Join-Path $AppDir $f
            if (Test-Path $src) { Copy-Item -LiteralPath $src -Destination $P.App -Force }
        }
        if (Test-Path (Join-Path $AppDir 'assets')) { Copy-Item -Path (Join-Path $AppDir 'assets') -Destination $P.App -Recurse -Force }
        Add-Change 'Install' 'ComfyNuke app' "$AppVersion → $($P.App)"
    }
    $startBat = Join-Path $Root 'Start ComfyUI.bat'
    $bat = @"
@echo off
rem Starts the ComfyUI server for Nuke. Keep this window open while working in Nuke.
title ComfyUI - keep this window open while using Nuke
set OPENCV_IO_ENABLE_OPENEXR=1
rem Ignore any other Python setup on this PC (PYTHONHOME/PYTHONPATH would break ComfyUI's own Python)
set PYTHONHOME=
set PYTHONPATH=
set PYTHONSTARTUP=
set PYTHONUSERBASE=
set PYTHONEXECUTABLE=
set VIRTUAL_ENV=
set PYTHONNOUSERSITE=1
cd /d "%~dp0ComfyUI"
rem Moves models the browser downloads into ComfyUI\models (runs in this window and stops with it)
if exist "%~dp0app\model_sorter.py" start "" /b ".venv\Scripts\python.exe" "%~dp0app\model_sorter.py" --comfy "%~dp0ComfyUI" --log-dir "%LOCALAPPDATA%\ComfyNuke\logs"
".venv\Scripts\python.exe" main.py --listen 127.0.0.1 --port $Port %*
echo.
echo ComfyUI has stopped. If this was unexpected, run ComfyNuke ^> Doctor.
pause
"@
    $toolBat = Join-Path $Root 'ComfyNuke.bat'
    $tool = "@echo off`r`npowershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"%~dp0app\comfynuke.ps1`" %*`r`n"
    $wrote = $false
    foreach ($pair in @(@($startBat, $bat), @($toolBat, $tool))) {
        $text = $pair[1].Replace("`r`n", "`n").Replace("`n", "`r`n")
        if ((Test-Path $pair[0]) -and ([IO.File]::ReadAllText($pair[0]) -eq $text)) { continue }
        [IO.File]::WriteAllText($pair[0], $text, (New-Object Text.ASCIIEncoding))
        $wrote = $true
    }
    $menuDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'ComfyNuke'
    $desktop = [Environment]::GetFolderPath('Desktop')
    $icons = Get-LauncherIcons
    $links = @(
        @((Join-Path $menuDir 'Start ComfyUI.lnk'), $startBat, $icons.Comfy),
        @((Join-Path $menuDir 'ComfyNuke.lnk'), $toolBat, $icons.Tool),
        @((Join-Path $desktop 'Start ComfyUI.lnk'), $startBat, $icons.Comfy)
    )
    New-Item -ItemType Directory -Force -Path $menuDir | Out-Null
    $iconsChanged = $false
    foreach ($l in $links) {
        if (Set-Shortcut $l[0] $l[1] $Root $l[2]) { $wrote = $true; $iconsChanged = $true }
    }
    if ($iconsChanged) {
        # Ask Explorer to refresh its icon cache so new icons show without signing out
        try { Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\ie4uinit.exe') -ArgumentList '-show' -WindowStyle Hidden -Wait } catch { }
    }
    if ($wrote) { Add-Change 'Config' 'Shortcuts' 'Desktop: "Start ComfyUI", Start menu: "ComfyNuke"' }
}

# Snapshot = everything needed to come back to this exact state
function New-Snapshot([string]$Reason, $State) {
    if (-not (Test-Path $P.Py)) { return }
    New-Item -ItemType Directory -Force -Path $P.Snapshots | Out-Null
    $repos = [ordered]@{}
    $dirs = @()
    foreach ($k in $Manifest.repos.PSObject.Properties.Name) { $dirs += , @($k, (Get-RepoDir $Manifest.repos.$k.dir)) }
    # Nodes the user added later (e.g. through ComfyUI-Manager) are recorded too
    $cn = Join-Path $P.Comfy 'custom_nodes'
    if (Test-Path $cn) {
        foreach ($d in Get-ChildItem -LiteralPath $cn -Directory) {
            if (Test-Path (Join-Path $d.FullName '.git')) { $dirs += , @("custom_nodes/$($d.Name)", $d.FullName) }
        }
    }
    foreach ($pair in $dirs) {
        if ($repos.Contains($pair[0]) -or -not (Test-Path (Join-Path $pair[1] '.git'))) { continue }
        $c = Get-NativeOutput $P.Git @('-C', $pair[1], 'rev-parse', 'HEAD') -AllowFail | Select-Object -First 1
        if ($c) { $repos[$pair[0]] = [ordered]@{ dir = $pair[1]; commit = $c } }
    }
    $id = Get-Date -Format 'yyyyMMdd-HHmmss'
    Get-NativeOutput (Get-UvExe) @('pip', 'freeze', '--python', $P.Py) | Set-Content -LiteralPath (Join-Path $P.Snapshots "$id-pip.txt") -Encoding UTF8
    if (Test-Path $P.MenuPy) { Copy-Item -LiteralPath $P.MenuPy -Destination (Join-Path $P.Snapshots "$id-menu.py") }
    [ordered]@{
        id = $id; reason = $Reason; appVersion = $AppVersion; manifestVersion = $Manifest.manifestVersion
        python = $State.python; torch = $State.torch; repos = $repos
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $P.Snapshots "$id.json") -Encoding UTF8
    Write-Log "Restore point $id created ($Reason)" 'OK'
    # Keep the newest 20 snapshots
    $old = @(Get-ChildItem -LiteralPath $P.Snapshots -Filter '*.json' | Sort-Object Name -Descending | Select-Object -Skip 20)
    foreach ($f in $old) {
        $base = $f.BaseName
        Get-ChildItem -LiteralPath $P.Snapshots -Filter "$base*" | Remove-Item -Force
        Add-Change 'Delete' 'Old restore point' "$base (only the newest 20 are kept)"
    }
}

# ----------------------------------------------------------------------------
# Preflight: check the machine and explain the plan before touching anything
# ----------------------------------------------------------------------------
function Get-Preflight {
    $gpu = Get-GpuInfo
    $nukes = @(Find-Nuke)
    $variant = Select-TorchVariant $gpu
    $drive = (Split-Path $Root -Qualifier).TrimEnd(':')
    $free = [math]::Round(((Get-PSDrive -Name $drive -ErrorAction SilentlyContinue).Free / 1GB), 1)
    $issues = @(); $warnings = @()
    if (-not [Environment]::Is64BitOperatingSystem) { $issues += 'Needs 64-bit Windows' }
    if ([Environment]::OSVersion.Version.Build -lt 17763) { $issues += 'Your Windows version is too old (Windows 10 1809 or newer is needed)' }
    if ($free -lt 25) { $issues += "$($drive): only $free GB free, at least 25 GB is needed (models take extra space)" }
    if ($Root -match '[^\x20-\x7E]') { $warnings += 'The install folder path has non-English or special characters, which can break some tools. An English-only path is recommended' }
    if ($gpu.Vendor -eq 'NVIDIA' -and -not $variant) {
        $issues += "Your NVIDIA driver is too old ($($gpu.Driver)). Please update it first from nvidia.com or the NVIDIA app"
    }
    if ($gpu.Vendor -eq 'NVIDIA-NoDriver') { $issues += 'An NVIDIA graphics card was found but no driver is installed. Please install the NVIDIA driver first' }
    if ($gpu.Vendor -in @('AMD', 'Intel', 'Other', 'None')) { $warnings += 'No NVIDIA graphics card found: ComfyUI will run in CPU mode. You can test the workflow, but generating will be very slow' }
    if ($gpu.Vendor -eq 'NVIDIA' -and $gpu.VramGB -gt 0 -and $gpu.VramGB -lt 8) { $warnings += "Only $($gpu.VramGB) GB of video memory: big models (SDXL/Flux/video) may not run" }
    if ($nukes.Count -eq 0) { $warnings += 'Nuke not found (C:\Program Files\Nuke*). You can still install; once Nuke is installed, run "Install / Repair" again' }
    foreach ($n in $nukes) {
        if ($n.Major -gt 0 -and $n.Major -lt $Manifest.minNukeMajor) { $warnings += "$($n.Name) is too old, only Nuke $($Manifest.minNukeMajor) or newer is supported" }
    }
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) { $warnings += 'Running as administrator is not needed; a normal user account is recommended' }
    try { Invoke-WebRequest -Uri 'https://github.com' -Method Head -TimeoutSec 15 -UseBasicParsing | Out-Null }
    catch { $issues += 'Cannot reach github.com, please check your internet connection' }
    return [pscustomobject]@{ Gpu = $gpu; Nukes = $nukes; Variant = $variant; FreeGB = $free; Issues = $issues; Warnings = $warnings }
}

function Show-Preflight($Pre) {
    Write-Log 'PC check' 'STEP'
    $g = $Pre.Gpu
    Write-Log ("Graphics card: {0}  Driver: {1}  VRAM: {2} GB" -f $g.Name, $g.Driver, $g.VramGB)
    $vname = if ($Pre.Variant) { "$($Pre.Variant.torch) ($($Pre.Variant.name))" } else { '—' }
    Write-Log "PyTorch to be used: $vname"
    if ($Pre.Nukes.Count) { foreach ($n in $Pre.Nukes) { Write-Log "Nuke: $($n.Name) (Python $($n.Python))" } }
    Write-Log "Install location: $Root ($($Pre.FreeGB) GB free)"
    $sysGit = (Get-Command git.exe -ErrorAction SilentlyContinue).Source
    $sysPy = (Get-Command python.exe -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch 'WindowsApps' }).Source
    Write-Log ("System Git: {0}; system Python: {1} (neither will be changed)" -f $(if ($sysGit) { 'yes' } else { 'no' }), $(if ($sysPy) { 'yes' } else { 'no' }))
    if ($script:ClearedEnv.Count) { Write-Log ("Python-related settings found on this PC and ignored by ComfyNuke: " + ($script:ClearedEnv -join ', ')) 'DEBUG' }
    foreach ($w in $Pre.Warnings) { Write-Log $w 'WARN' }
    foreach ($i in $Pre.Issues) { Write-Log $i 'ERROR' }
}

function Get-NukePyVersions($Pre) {
    $v = @($Pre.Nukes | Where-Object { $_.Python -match '^3\.\d+$' -and ($_.Major -eq 0 -or $_.Major -ge $Manifest.minNukeMajor) } | ForEach-Object { $_.Python } | Select-Object -Unique)
    if ($v.Count -eq 0) { $v = @('3.9', '3.10', '3.11', '3.12', '3.13') }   # no Nuke yet: cover every supported version
    return $v
}

# ----------------------------------------------------------------------------
# Commands
# ----------------------------------------------------------------------------
function Invoke-Install {
    $saved = Get-SavedRoot
    if (-not $script:Root) {
        if ($saved) { $script:Root = $saved }
        else { $script:Root = Read-Text 'Where should it be installed? (Models are big, so pick a drive with plenty of space, e.g. D:\ComfyNuke)' $DefaultRoot }
    }
    $script:Root = [IO.Path]::GetFullPath($script:Root).TrimEnd('\')
    Set-Paths
    $pre = Get-Preflight
    Show-Preflight $pre
    if ($pre.Issues.Count) { throw 'Please fix the problems shown in red above, then run this again' }

    $state = Read-State
    $isRepair = Test-Path $P.State
    Write-Log 'Plan' 'STEP'
    if ($isRepair) {
        Write-Log 'Already installed: this run will "repair" it, putting back anything that is missing without upgrading anything (to upgrade, use "Check for updates")'
    } else {
        Write-Log '1. Download private copies of Git, uv and Python (kept inside the install folder, your system is not affected)'
        Write-Log "2. Install ComfyUI $($Manifest.repos.comfyui.ref) and PyTorch (about 5 GB, takes 10–30 minutes)"
        Write-Log '3. Install two ComfyUI nodes: VideoHelperSuite and HQ-Image-Save'
        Write-Log "4. Install the Nuke plugin $($Manifest.repos.comfyui2nuke.ref) into $NukeHome and add its menu to menu.py"
        Write-Log '5. Create the desktop shortcut "Start ComfyUI"'
        Write-Log 'First you are asked for a Hugging Face token (needed to download most models; you can skip it).'
    }
    if ($DryRun) { Write-Log '(DryRun: only showing the plan, nothing was changed)' 'WARN'; return }
    if (-not (Read-YesNo 'Ready to start?' $true)) { return }
    Wait-ForClosedApps

    # Asked first, so the long part of the install can then run without anyone watching
    Write-Log 'Hugging Face sign-in' 'STEP'
    Set-HfSignIn

    New-Item -ItemType Directory -Force -Path $Root, $P.Tools | Out-Null
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    @{ root = $Root } | ConvertTo-Json | Set-Content -LiteralPath $ConfigFile -Encoding UTF8
    if (Test-Path $P.Py) { New-Snapshot 'before repair' $state }

    Write-Log 'Tools' 'STEP'
    foreach ($t in @('uv', 'git')) {
        $ok = if ($t -eq 'uv') { [bool](Get-UvExe) } else { Test-Path $P.Git }
        if (-not $ok) { Install-Tool $t; Set-Prop $state.tools $t $Manifest.tools.$t.version; Save-State $state }
    }

    Write-Log 'Python environment' 'STEP'
    if (-not (Test-Path $P.Py)) {
        # ComfyUI must be cloned first: the venv lives inside its folder
        $c = $Manifest.repos.comfyui
        $saved = $state.repos.comfyui
        $commit = if ($saved) { $saved.commit } else { $c.commit }
        $ref = if ($saved) { $saved.ref } else { $c.ref }
        if (-not (Test-Path (Join-Path $P.Comfy '.git'))) {
            $req = $c.requirements; $c.requirements = $false   # requirements need the venv; installed below
            Sync-Repo 'comfyui' $commit $ref $state | Out-Null
            $c.requirements = $req
        }
        Install-Python $state
        Save-State $state
    }

    Write-Log 'PyTorch' 'STEP'
    $hasTorch = Get-NativeOutput $P.Py @('-c', 'import torch; print(torch.__version__)') -AllowFail
    if (-not $hasTorch) {
        Install-Torch $state $pre.Variant
        Save-State $state
    } else { Write-Log "torch $hasTorch is already installed" 'DEBUG' }

    Write-Log 'ComfyUI and nodes' 'STEP'
    foreach ($k in $Manifest.repos.PSObject.Properties.Name) {
        $r = $Manifest.repos.$k
        $saved = $state.repos.$k
        # Repair keeps whatever version is installed; only a missing repo gets the tested pin
        $commit = if ($saved) { $saved.commit } else { $r.commit }
        $ref = if ($saved) { $saved.ref } else { $r.ref }
        $changed = Sync-Repo $k $commit $ref $state
        if (-not $changed -and $r.requirements) { Install-Requirements (Get-RepoDir $r.dir) $r.label }
        Save-State $state
    }
    # The model downloader needs huggingface_hub; ComfyUI normally brings it, put it back if it is missing
    if (-not (Get-NativeOutput $P.Py @('-c', 'import huggingface_hub; print(1)') -AllowFail)) {
        $hfArgs = @('pip', 'install', '--python', $P.Py, 'huggingface_hub')
        if (Test-Path $P.Constrain) { $hfArgs += @('--constraint', $P.Constrain) }
        Invoke-Native (Get-UvExe) $hfArgs
        Add-Change 'Install' 'huggingface_hub' 'needed by "Download missing models"'
    }

    Write-Log 'Nuke connection' 'STEP'
    Install-NukeLibs $state (Get-NukePyVersions $pre)
    Set-MenuBlock
    Install-Launchers
    Set-Prop $state 'manifestVersion' $(if ($state.manifestVersion) { $state.manifestVersion } else { $Manifest.manifestVersion })
    Save-State $state

    Write-Log 'Checks' 'STEP'
    $device = Write-ComputeDevice
    Write-GpuLoad
    if ($pre.Gpu.Vendor -eq 'NVIDIA' -and $device -ne 'cuda') { Write-Log 'PyTorch cannot see your graphics card (CUDA). Please run "Doctor" and send the zip it creates to whoever helped you install' 'WARN' }
    New-Snapshot $(if ($isRepair) { 'after repair' } else { 'first install' }) $state

    Write-Host ''
    Write-Log 'All done! How to use it:' 'STEP'
    Write-Log '1. Double-click "Start ComfyUI" on your desktop (keep the black window open)'
    Write-Log '2. Open Nuke → the node menu now has ComfyUI → click "Update all ComfyUI" first'
    Write-Log ('3. Put your models (checkpoints etc.) in: ' + (Join-Path $P.Comfy 'models'))
}

function Get-UpstreamTarget([string]$Url, [string]$Track, [string]$Branch) {
    $lines = Get-NativeOutput $P.Git @('ls-remote', '--tags', $Url) -AllowFail
    if ($Track -ne 'tag') {
        $head = Get-NativeOutput $P.Git @('ls-remote', $Url, "refs/heads/$Branch") -AllowFail | Select-Object -First 1
        if ($head) { return [pscustomobject]@{ ref = $Branch; commit = ($head -split '\s+')[0] } }
        return $null
    }
    $tags = @{}
    foreach ($l in $lines) {
        $sha, $name = $l -split '\s+'
        $name = $name -replace '^refs/tags/', ''
        if ($name.EndsWith('^{}')) { $tags[$name.TrimEnd('^{}')] = $sha }     # peeled = real commit
        elseif (-not $tags.ContainsKey($name)) { $tags[$name] = $sha }
    }
    $best = $tags.Keys | Where-Object { $_ -match '^v?\d+(\.\d+){1,3}$' } |
        Sort-Object { [version]($_ -replace '^v', '') } | Select-Object -Last 1
    if ($best) { return [pscustomobject]@{ ref = $best; commit = $tags[$best] } }
    return $null
}

function Get-UpdateCandidates($State, $Pre) {
    $list = @()
    foreach ($t in @('uv', 'git')) {
        $have = $State.tools.$t; $want = $Manifest.tools.$t.version
        if ($have -ne $want) { $list += [pscustomobject]@{ Key = "tool:$t"; Label = $t; From = $have; To = $want; Tested = $true; Risk = 'Low (just a tool)'; Target = $null } }
    }
    if ($State.python -ne $Manifest.tools.python.version) {
        $list += [pscustomobject]@{ Key = 'python'; Label = 'Python'; From = $State.python; To = $Manifest.tools.python.version; Tested = $true; Risk = 'Medium: rebuilds the Python environment (takes 10–30 minutes)'; Target = $null }
    }
    $v = $Pre.Variant
    if ($v -and ($State.torch.version -ne $v.torch -or $State.torch.variant -ne $v.name)) {
        $list += [pscustomobject]@{ Key = 'torch'; Label = 'PyTorch'; From = "$($State.torch.version) $($State.torch.variant)"; To = "$($v.torch) $($v.name)"; Tested = $true; Risk = 'Medium: about a 3 GB download'; Target = $v }
    }
    foreach ($k in $Manifest.repos.PSObject.Properties.Name) {
        $r = $Manifest.repos.$k; $have = $State.repos.$k
        $fromText = if ($have) { "$($have.ref) $($have.commit.Substring(0, 8))" } else { '(not installed)' }
        if (-not $have -or $have.commit -ne $r.commit) {
            $list += [pscustomobject]@{ Key = "repo:$k"; Label = $r.label; From = $fromText; To = "$($r.ref) $($r.commit.Substring(0, 8))"; Tested = $true; Risk = $r.risk; Target = [pscustomobject]@{ ref = $r.ref; commit = $r.commit } }
        }
        if ($Latest) {
            $up = Get-UpstreamTarget $r.url $r.track $r.ref
            if ($up -and $up.commit -ne $r.commit -and (-not $have -or $up.commit -ne $have.commit)) {
                $list += [pscustomobject]@{ Key = "repo:$k"; Label = "$($r.label) (newest version, not tested)"; From = $fromText; To = "$($up.ref) $($up.commit.Substring(0, 8))"; Tested = $false; Risk = "Higher: $($r.risk)"; Target = $up }
            }
        }
    }
    $libsOutdated = @($State.nukeLibs.PSObject.Properties | Where-Object { $_.Value -ne ($Manifest.nukeLibs -join ',') })
    if ($libsOutdated.Count) {
        $list += [pscustomobject]@{ Key = 'nukelibs'; Label = 'Nuke connection packages'; From = 'old'; To = 'new'; Tested = $true; Risk = 'Low'; Target = $null }
    }
    return $list
}

function Get-LatestAppRelease {
    try {
        $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$RepoSlug/releases/latest" -TimeoutSec 15 -Headers @{ 'User-Agent' = 'ComfyNuke' }
        $ver = [version]($r.tag_name -replace '^v', '')
        if ($ver -gt [version]$AppVersion) { return $r }
    } catch { Write-Log "Could not check for a new ComfyNuke version: $($_.Exception.Message)" 'DEBUG' }
    return $null
}

function Invoke-SelfUpdate([switch]$Relaunch) {
    Use-InstalledRoot
    $rel = Get-LatestAppRelease
    if (-not $rel) { Write-Log "ComfyNuke app is up to date ($AppVersion)" 'OK'; return $false }
    $asset = $rel.assets | Where-Object { $_.name -eq 'ComfyNuke.zip' } | Select-Object -First 1
    if (-not $asset) { Write-Log 'The new version has no ComfyNuke.zip, skipping' 'WARN'; return $false }
    Write-Log "A new ComfyNuke version is available: $($rel.tag_name) (you have $AppVersion)" 'STEP'
    Write-Log "What's new: $($rel.html_url)"
    if (-not (Read-YesNo 'Update the ComfyNuke app itself? (ComfyUI and Nuke will not be changed)' $true)) { return $false }
    $tmp = Join-Path $env:TEMP "comfynuke-$RunId"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $zip = Join-Path $tmp 'ComfyNuke.zip'
    $sha = if ($asset.digest) { $asset.digest -replace '^sha256:', '' } else { $null }
    Save-Download $asset.browser_download_url $zip $sha
    Expand-Zip $zip (Join-Path $tmp 'x')
    $src = Get-ChildItem -LiteralPath (Join-Path $tmp 'x') -Recurse -Filter 'comfynuke.ps1' | Select-Object -First 1
    if (-not $src) { throw 'The downloaded file is incomplete' }
    if (Test-Path $P.App) {
        $bak = Join-Path $P.Backups "app-$AppVersion-$RunId"
        New-Item -ItemType Directory -Force -Path $bak | Out-Null
        Copy-Item -Path (Join-Path $P.App '*') -Destination $bak -Recurse -Force
        Add-Change 'Backup' 'ComfyNuke app' "backups\$(Split-Path $bak -Leaf)"
    }
    New-Item -ItemType Directory -Force -Path $P.App | Out-Null
    Copy-Item -Path (Join-Path $src.DirectoryName '*') -Destination $P.App -Recurse -Force
    Add-Change 'Update' 'ComfyNuke app' "$AppVersion → $($rel.tag_name)"
    Remove-Item -LiteralPath $tmp -Recurse -Force
    if ($Relaunch) {
        Show-Summary
        Write-Log 'Restarting with the new version...' 'STEP'
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $P.App 'comfynuke.ps1') update
        exit $LASTEXITCODE
    }
    return $true
}

function Use-InstalledRoot {
    if (-not $script:Root) { $script:Root = Get-SavedRoot }
    if (-not $script:Root -or -not (Test-Path $script:Root)) { throw 'Not installed yet. Please choose "Install / Repair" first.' }
    Set-Paths
}

function Invoke-Update {
    Use-InstalledRoot
    if (-not $DryRun) { [void](Invoke-SelfUpdate -Relaunch) }
    $state = Read-State
    $pre = Get-Preflight
    Show-Preflight $pre
    $cands = @(Get-UpdateCandidates $state $pre)
    Write-Log 'Available updates' 'STEP'
    if ($cands.Count -eq 0) { Write-Log 'Everything is already on the tested versions, nothing to update. (Add -Latest to see the newest untested versions)' 'OK'; return }
    Write-Host ''
    for ($i = 0; $i -lt $cands.Count; $i++) {
        $c = $cands[$i]
        $color = if ($c.Tested) { 'White' } else { 'Yellow' }
        Write-Host ('    [{0}] {1}' -f ($i + 1), $c.Label) -ForegroundColor $color
        Write-Host ('        {0}  →  {1}    Risk: {2}' -f $c.From, $c.To, $c.Risk) -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Log 'Tip: if you have a Nuke project in progress, it is best to skip the "High" risk items for now. A restore point is created automatically before updating, so you can roll back at any time.' 'WARN'
    if ($DryRun) { Write-Log '(DryRun: nothing was changed)' 'WARN'; return }
    $answer = Read-Text 'Type the numbers to update (e.g. 1,3; all = every tested one; just press Enter = update nothing)' ''
    if (-not $answer) { Write-Log 'No updates chosen' 'OK'; return }
    $picked = @()
    if ($answer -eq 'all') { $picked = @($cands | Where-Object { $_.Tested }) }
    else {
        foreach ($n in ($answer -split '[,\s]+' | Where-Object { $_ -match '^\d+$' })) {
            $idx = [int]$n - 1
            if ($idx -ge 0 -and $idx -lt $cands.Count) { $picked += $cands[$idx] }
        }
    }
    # The same component cannot be updated to two versions at once
    $picked = @($picked | Group-Object Key | ForEach-Object { $_.Group | Select-Object -Last 1 })
    if ($picked.Count -eq 0) { Write-Log 'No valid choice' 'WARN'; return }
    # Tested versions are tested as a set: a newer ComfyUI may rely on the newer Python/PyTorch/tools next to it
    if ($picked | Where-Object { $_.Tested -and $_.Key -like 'repo:*' }) {
        $deps = @($cands | Where-Object { $_.Tested -and $_.Key -in @('tool:uv', 'tool:git', 'python', 'torch') -and $picked.Key -notcontains $_.Key })
        if ($deps.Count) {
            Write-Log ('The tested new versions need these updated together: ' + (($deps | ForEach-Object { $_.Label }) -join ', ') + ' (added automatically)') 'WARN'
            $picked += $deps
        }
    }
    Write-Log ('Will update: ' + (($picked | ForEach-Object { $_.Label }) -join ', '))
    if (-not (Read-YesNo 'Are you sure?' $true)) { return }
    Wait-ForClosedApps
    New-Snapshot 'before update' $state

    foreach ($c in ($picked | Sort-Object { if ($_.Key -like 'tool:*') { 0 } elseif ($_.Key -eq 'python') { 1 } elseif ($_.Key -eq 'torch') { 2 } else { 3 } })) {
        Write-Log "Updating $($c.Label)" 'STEP'
        switch -Wildcard ($c.Key) {
            'tool:*' {
                $t = $c.Key.Substring(5)
                Install-Tool $t; Set-Prop $state.tools $t $Manifest.tools.$t.version
            }
            'python' {
                Install-Python $state
                Install-Torch $state $pre.Variant
                foreach ($k in $Manifest.repos.PSObject.Properties.Name) {
                    if ($Manifest.repos.$k.requirements) { Install-Requirements (Get-RepoDir $Manifest.repos.$k.dir) $Manifest.repos.$k.label }
                }
            }
            'torch' { Install-Torch $state $c.Target }
            'repo:*' { [void](Sync-Repo $c.Key.Substring(5) $c.Target.commit $c.Target.ref $state) }
            'nukelibs' { Install-NukeLibs $state (Get-NukePyVersions $pre) -Force }
        }
        Save-State $state
    }
    if ($picked | Where-Object { $_.Tested }) { Set-Prop $state 'manifestVersion' $Manifest.manifestVersion }
    Save-State $state
    New-Snapshot 'after update' $state
    Invoke-Native (Get-UvExe) @('cache', 'prune')   # drop downloads of versions no longer used
    if ($picked | Where-Object { $_.Key -in @('python', 'torch') }) { [void](Write-ComputeDevice) }
}

function Invoke-Rollback {
    Use-InstalledRoot
    $snaps = @(Get-ChildItem -LiteralPath $P.Snapshots -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if ($snaps.Count -eq 0) { Write-Log 'There are no restore points yet' 'WARN'; return }
    Write-Log 'Restore points (newest first)' 'STEP'
    $items = @()
    for ($i = 0; $i -lt $snaps.Count; $i++) {
        $s = Get-Content -Raw -Encoding UTF8 $snaps[$i].FullName | ConvertFrom-Json
        $items += $s
        $comfy = if ($s.repos.comfyui) { $s.repos.comfyui.commit.Substring(0, 8) } else { '-' }
        $plug = if ($s.repos.comfyui2nuke) { $s.repos.comfyui2nuke.commit.Substring(0, 8) } else { '-' }
        Write-Host ('    [{0}] {1}  {2}   ComfyUI {3} / Nuke plugin {4} / torch {5}' -f ($i + 1), $s.id, $s.reason, $comfy, $plug, $s.torch.version)
    }
    if ($DryRun) { return }
    $n = Read-Text 'Type the number to roll back to (just press Enter = cancel)' ''
    if (-not ($n -match '^\d+$') -or [int]$n -lt 1 -or [int]$n -gt $items.Count) { return }
    $snap = $items[[int]$n - 1]
    if (-not (Read-YesNo "Roll back to $($snap.id) ($($snap.reason))?" $false)) { return }
    Wait-ForClosedApps
    $state = Read-State
    New-Snapshot 'before rollback' $state
    foreach ($prop in $snap.repos.PSObject.Properties) {
        $dir = $prop.Value.dir
        if (-not (Test-Path (Join-Path $dir '.git'))) { Write-Log "$($prop.Name) no longer exists, skipping" 'WARN'; continue }
        $head = Get-NativeOutput $P.Git @('-C', $dir, 'rev-parse', 'HEAD') -AllowFail | Select-Object -First 1
        if ($head -eq $prop.Value.commit) { continue }
        $dirty = Get-NativeOutput $P.Git @('-C', $dir, 'status', '--porcelain', '--ignore-submodules') -AllowFail
        if ($dirty) { Invoke-Native $P.Git @('-C', $dir, 'stash', 'push', '--include-untracked', '-m', "comfynuke-$RunId") }
        Invoke-Native $P.Git @('-C', $dir, 'fetch', '--tags', '--force', 'origin')
        Invoke-Native $P.Git @('-C', $dir, 'checkout', '--force', '--quiet', $prop.Value.commit)
        Invoke-Native $P.Git @('-C', $dir, 'submodule', 'update', '--init', '--recursive', '--force')
        $label = $prop.Name
        $m = $Manifest.repos.($prop.Name)
        if ($m) {
            $label = $m.label
            $ref = if ($m.commit -eq $prop.Value.commit) { $m.ref } else { 'snapshot' }
            Set-Prop $state.repos $prop.Name ([pscustomobject]@{ ref = $ref; commit = $prop.Value.commit })
        }
        Add-Change 'Restore' $label $prop.Value.commit.Substring(0, 8)
    }
    $pip = Join-Path $P.Snapshots "$($snap.id)-pip.txt"
    if (Test-Path $pip) {
        $idx = if ($snap.torch.index) { $snap.torch.index } else { 'https://download.pytorch.org/whl/cpu' }
        Invoke-Native (Get-UvExe) @('pip', 'sync', '--python', $P.Py, $pip, '--extra-index-url', $idx, '--index-strategy', 'unsafe-best-match')
        Add-Change 'Restore' 'Python packages' "Same as $($snap.id)"
        Get-Content $pip | Where-Object { $_ -match '^(torch|torchvision|torchaudio)==' } | Set-Content -LiteralPath $P.Constrain -Encoding ASCII
        Set-Prop $state 'torch' $snap.torch
        Invoke-Native (Get-UvExe) @('cache', 'prune')
    }
    Save-State $state
}

function Test-ComfyRunning {
    try { Invoke-RestMethod -Uri "http://127.0.0.1:$Port/system_stats" -TimeoutSec 2 | Out-Null; return $true } catch { return $false }
}

function Invoke-Status {
    Use-InstalledRoot
    $state = Read-State
    Write-Log 'ComfyNuke status' 'STEP'
    Write-Log "Tool version: $AppVersion  Tested version list: $($Manifest.manifestVersion) (installed: $($state.manifestVersion))"
    Write-Log "Install location: $Root"
    Write-Log "Python: $($state.python)  PyTorch: $($state.torch.version) $($state.torch.variant)"
    foreach ($k in $Manifest.repos.PSObject.Properties.Name) {
        $have = $state.repos.$k
        $txt = if ($have) { "$($have.ref) ($($have.commit.Substring(0, 8)))" } else { 'not installed' }
        $mark = if ($have -and $have.commit -eq $Manifest.repos.$k.commit) { '' } else { '  ← differs from the tested version' }
        Write-Log "$($Manifest.repos.$k.label): $txt$mark"
    }
    Write-Log ("Nuke connection packages: " + (($state.nukeLibs.PSObject.Properties.Name) -join ', '))
    $menuOk = (Test-Path $P.MenuPy) -and ([IO.File]::ReadAllText($P.MenuPy) -match [regex]::Escape($BlockStart))
    Write-Log ("menu.py setup: " + $(if ($menuOk) { 'yes' } else { 'no (please run "Install / Repair")' }))
    Write-Log ("ComfyUI server: " + $(if (Test-ComfyRunning) { "running (http://127.0.0.1:$Port)" } else { 'not started' }))
    $hf = Get-SavedHfAccount
    Write-Log ("Hugging Face: " + $(if ($hf) { "signed in as $($hf.Name) (token `"$($hf.TokenName)`"" + $(if ($hf.CanWrite) { ', can write: a Read-only token is safer)' } else { ', read-only)' }) } else { 'not signed in (option 9)' }))
    Write-ComfyDevice
    [void](Write-ComputeDevice)
    Write-GpuLoad
}

function Invoke-Start {
    Use-InstalledRoot
    if (Test-ComfyRunning) { Write-Log "ComfyUI is already running: http://127.0.0.1:$Port" 'OK'; Write-ComfyDevice; return }
    [void](Write-ComputeDevice)
    Write-GpuLoad
    Start-Process -FilePath (Join-Path $Root 'Start ComfyUI.bat') -WorkingDirectory $Root
    Write-Log 'The ComfyUI window has opened. The first start takes longer; when you see "To see the GUI go to" it is ready.' 'OK'
}

function Invoke-Doctor {
    Use-InstalledRoot
    $state = Read-State
    Write-Log 'Doctor' 'STEP'
    $checks = @(
        @('Private Git', (Test-Path $P.Git)),
        @('uv', [bool](Get-UvExe)),
        @('Python environment', (Test-Path $P.Py)),
        @('ComfyUI', (Test-Path (Join-Path $P.Comfy 'main.py'))),
        @('Nuke plugin', (Test-Path (Join-Path $NukeHome 'comfyui2nuke\__init__.py'))),
        @('Nuke plugin submodule nuke_util', ((Get-ChildItem (Join-Path $NukeHome 'comfyui2nuke\nuke_util') -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0)),
        @('menu.py setup', ((Test-Path $P.MenuPy) -and ([IO.File]::ReadAllText($P.MenuPy) -match [regex]::Escape($BlockStart)))),
        @('ComfyUI server running', (Test-ComfyRunning))
    )
    foreach ($c in $checks) { Write-Log ('{0}  {1}' -f $(if ($c[1]) { '[OK]' } else { '[X] ' }), $c[0]) $(if ($c[1]) { 'OK' } else { 'WARN' }) }
    [void](Write-ComputeDevice)
    Write-GpuLoad
    Write-ComfyDevice
    # Where the disk space goes
    foreach ($d in @(@('Models', (Join-Path $P.Comfy 'models')), @('uv download cache', (Join-Path $Root 'tools\uv-cache')), @('Python environment', $P.Venv), @('log', $LogDir))) {
        if (-not (Test-Path $d[1])) { continue }
        $bytes = (Get-ChildItem -LiteralPath $d[1] -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        Write-Log ('Disk space: {0} {1:N1} GB' -f $d[0], ($bytes / 1GB))
    }
    # Support bundle: logs and settings only (no models, images or projects)
    $bundle = Join-Path $env:TEMP "comfynuke-support-$RunId"
    New-Item -ItemType Directory -Force -Path $bundle | Out-Null
    Get-ChildItem -LiteralPath $LogDir -Filter '*.log' | Sort-Object Name -Descending | Select-Object -First 15 | Copy-Item -Destination $bundle
    foreach ($f in @($P.State, (Join-Path $Root 'history.log'), $P.MenuPy)) { if (Test-Path $f) { Copy-Item -LiteralPath $f -Destination $bundle } }
    Get-ChildItem -LiteralPath (Join-Path $P.Comfy 'user') -Filter '*.log' -ErrorAction SilentlyContinue | Copy-Item -Destination $bundle
    $pre = Get-Preflight
    $info = @(
        "ComfyNuke $AppVersion / manifest $($Manifest.manifestVersion)",
        "Windows $([Environment]::OSVersion.Version)",
        "GPU: $($pre.Gpu.Name) driver $($pre.Gpu.Driver) cc $($pre.Gpu.ComputeCap) vram $($pre.Gpu.VramGB)GB",
        ('Nuke: ' + (($pre.Nukes | ForEach-Object { "$($_.Name) py$($_.Python)" }) -join '; ')),
        "Free: $($pre.FreeGB) GB", "Root: $Root", "NukeHome: $NukeHome"
    )
    $info | Set-Content -LiteralPath (Join-Path $bundle 'system.txt') -Encoding UTF8
    if (Test-Path $P.Py) { Get-NativeOutput (Get-UvExe) @('pip', 'freeze', '--python', $P.Py) -AllowFail | Set-Content -LiteralPath (Join-Path $bundle 'pip-freeze.txt') -Encoding UTF8 }
    $zip = Join-Path ([Environment]::GetFolderPath('Desktop')) "ComfyNuke-support-$RunId.zip"
    Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath $zip -Force
    Remove-Item -LiteralPath $bundle -Recurse -Force
    Write-Log "Created $(Split-Path $zip -Leaf) on your desktop. If something goes wrong, send it to whoever helped you install (it only contains logs and settings, no images or projects)" 'OK'
}

# ---- Hugging Face sign-in ----------------------------------------------------------------
# The token is stored where every Hugging Face tool looks for it (the user's profile, readable only
# by this Windows user), never in an environment variable, a ComfyNuke file or a log.
function Get-HfTokenPath {
    if ($env:HF_TOKEN_PATH) { return $env:HF_TOKEN_PATH }
    $hfHome = if ($env:HF_HOME) { $env:HF_HOME } else { Join-Path $env:USERPROFILE '.cache\huggingface' }
    return Join-Path $hfHome 'token'
}

# Who a token belongs to and whether it can write; $null when Hugging Face rejects it
function Get-HfAccount([string]$Token) {
    try { $r = Invoke-RestMethod -Uri 'https://huggingface.co/api/whoami-v2' -Headers @{ Authorization = "Bearer $Token" } -TimeoutSec 20 }
    catch { return $null }
    $t = $r.auth.accessToken
    $canWrite = $t.role -eq 'write' -or (@($t.fineGrained.scoped | ForEach-Object { $_.permissions }) -match '\.write$').Count -gt 0
    return [pscustomobject]@{ Name = $r.name; TokenName = $t.displayName; Role = $t.role; CanWrite = $canWrite }
}

function Get-SavedHfAccount {
    $path = Get-HfTokenPath
    if (-not (Test-Path $path)) { return $null }
    return Get-HfAccount ([IO.File]::ReadAllText($path).Trim())
}

function Set-HfSignIn([switch]$Change) {
    $acct = Get-SavedHfAccount
    if ($acct -and -not $Change) {
        Write-Log "Signed in to Hugging Face as $($acct.Name) (token `"$($acct.TokenName)`")" 'OK'
        if ($acct.CanWrite) { Write-Log 'This token can also change things on that Hugging Face account. A Read-only token is safer (menu option 9 replaces it).' 'WARN' }
        return
    }
    if ((Test-Path (Get-HfTokenPath)) -and -not $acct -and -not $Change) { Write-Log 'The saved Hugging Face sign-in no longer works; please sign in again.' 'WARN' }
    Write-Log 'Most models download from Hugging Face, which needs a free account and an access token:'
    Write-Log '  1. Sign in at https://huggingface.co and open Settings > Access Tokens > Create new token.'
    Write-Log '  2. Choose "Fine-grained" with the "Read-Only" preset, name it (e.g. comfynuke) and create it.'
    Write-Log '  3. Copy the token (it starts with hf_) and paste it below. Nothing shows while you paste; then press Enter.'
    if ($Yes) { Write-Log 'Skipped (-Yes). Option 9 signs in later.' 'WARN'; return }
    for ($try = 1; $try -le 3; $try++) {
        $secure = Read-Host '    Hugging Face token (or just Enter to skip for now)' -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr).Trim() }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        if (-not $token) { Write-Log 'Skipped. You can sign in later with option 9, or when "Download missing models" asks.' 'WARN'; return }
        $acct = Get-HfAccount $token
        if (-not $acct) { Write-Log 'Hugging Face did not accept that token. Check that you copied all of it, then paste it again.' 'WARN'; continue }
        if ($acct.CanWrite -and -not (Read-YesNo 'This token can also change or delete things on your Hugging Face account. A Read-only token is safer. Use it anyway?' $false)) { continue }
        $path = Get-HfTokenPath
        New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
        [IO.File]::WriteAllText($path, $token, (New-Object Text.UTF8Encoding $false))
        Add-Change 'Config' 'Hugging Face sign-in' "$($acct.Name), token `"$($acct.TokenName)`" (saved in $path)"
        return
    }
    Write-Log 'Not signed in. You can try again later with option 9.' 'WARN'
}

function Invoke-HfLogin { Set-HfSignIn -Change }

# Downloads a workflow's missing models with resume and fresh links (model_download.py does the work).
# Runs straight in this window, not through Invoke-Native, so its questions and progress bars work.
function Invoke-Models {
    Use-InstalledRoot
    if (-not (Test-Path $P.Py)) { throw 'ComfyUI is not installed yet. Choose "Install / Repair" first.' }
    $script = Join-Path $P.App 'model_download.py'
    if (-not (Test-Path $script)) { $script = Join-Path $AppDir 'model_download.py' }
    if (-not (Test-Path $script)) { throw 'model_download.py is missing. Choose "Install / Repair" to put it back.' }
    Write-Log "Starting the model downloader ($script)" 'DEBUG'
    # Start-Process keeps the console attached (a plain call inside a function would swallow its output)
    $argList = @("`"$script`"", '--comfy', "`"$($P.Comfy)`"", '--log-dir', "`"$LogDir`"")
    if ($env:COMFYNUKE_TEST_INPUT) {
        $proc = Start-Process -FilePath $P.Py -ArgumentList $argList -NoNewWindow -Wait -PassThru -RedirectStandardInput $env:COMFYNUKE_TEST_INPUT
    } else {
        $proc = Start-Process -FilePath $P.Py -ArgumentList $argList -NoNewWindow -Wait -PassThru
    }
    Write-Log "Model downloader finished (exit code $($proc.ExitCode)); details in the *-model-download.log file" 'DEBUG'
}

function Invoke-Uninstall {
    Use-InstalledRoot
    Write-Log 'Uninstall' 'STEP'
    Write-Log 'This will: remove the ComfyUI menu and plugin from Nuke (moved to a backup folder) and delete the shortcuts.'
    Write-Log "This will not: delete $Root (it holds your models; delete it yourself once you are sure you do not need them)."
    if ($DryRun) { return }
    if (-not (Read-YesNo 'Are you sure you want to uninstall?' $false)) { return }
    Wait-ForClosedApps
    Remove-MenuBlock
    $bak = Join-Path $P.Backups "uninstalled-$RunId"
    foreach ($d in @((Join-Path $NukeHome 'comfyui2nuke'), $P.NukeLibs)) {
        if (Test-Path $d) {
            New-Item -ItemType Directory -Force -Path $bak | Out-Null
            Move-Item -LiteralPath $d -Destination $bak
            Add-Change 'Delete' (Split-Path $d -Leaf) "Moved from .nuke to $bak"
        }
    }
    $menuDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'ComfyNuke'
    foreach ($l in @($menuDir, (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Start ComfyUI.lnk'))) {
        if (Test-Path $l) { Remove-Item -LiteralPath $l -Recurse -Force; Add-Change 'Delete' 'Shortcuts' $l }
    }
    Remove-Item -LiteralPath $P.State -Force
    Add-Change 'Delete' 'state.json' 'Install record (recreated when you install again)'
    Write-Log "To remove everything, delete $Root and $DataDir by hand" 'WARN'
}

function Show-Help {
    Get-Help $PSCommandPath -Detailed | Out-String | Write-Host
}

function Show-Menu {
    while ($true) {
        $script:Changes.Clear()
        $saved = Get-SavedRoot
        Write-Host ''
        Write-Host "  ComfyNuke $AppVersion — ComfyUI for Nuke" -ForegroundColor Cyan
        Write-Host ("  " + $(if ($saved) { "Installed at $saved" } else { 'Not installed yet' })) -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '   1  Install / Repair'
        Write-Host '   2  Check for updates (you choose what to update)'
        Write-Host '   3  Start ComfyUI'
        Write-Host '   4  Status'
        Write-Host '   5  Roll back to an earlier version'
        Write-Host '   6  Doctor (use when something is wrong; creates a zip on your Desktop)'
        Write-Host '   7  Uninstall'
        Write-Host '   8  Download missing models (for a workflow; resumes if interrupted)'
        Write-Host '   9  Sign in to Hugging Face (or change the saved token)'
        Write-Host '   0  Exit'
        $c = "$(Read-Host '  Choose')".Trim()
        $map = @{ '1' = 'install'; '2' = 'update'; '3' = 'start'; '4' = 'status'; '5' = 'rollback'; '6' = 'doctor'; '7' = 'uninstall'; '8' = 'models'; '9' = 'hf-login' }
        if ($c -eq '0' -or $c -eq '') { return }
        if (-not $map.ContainsKey($c)) { continue }
        [void](Start-Action $map[$c])
        [void](Read-Host '  Press Enter to return to the menu')
    }
}

function Start-Action([string]$Name) {
    $script:Changes.Clear()
    $script:LogFile = Join-Path $LogDir ("{0}-{1}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $Name)
    Write-Log "ComfyNuke $AppVersion  $Name  (manifest $($Manifest.manifestVersion))" 'DEBUG'
    $failed = $false
    try {
        $g = Get-GpuInfo
        Write-Log ("Windows {0}; graphics card {1} (driver {2})" -f [Environment]::OSVersion.Version, $g.Name, $g.Driver) 'DEBUG'
        Remove-OldLogs
    } catch { }
    try {
        switch ($Name) {
            'install'     { Invoke-Install }
            'update'      { Invoke-Update }
            'status'      { Invoke-Status }
            'start'       { Invoke-Start }
            'rollback'    { Invoke-Rollback }
            'doctor'      { Invoke-Doctor }
            'uninstall'   { Invoke-Uninstall }
            'models'      { Invoke-Models }
            'hf-login'    { Invoke-HfLogin }
            'self-update' { [void](Invoke-SelfUpdate) }
            'help'        { Show-Help }
        }
    } catch {
        $failed = $true
        Write-Log $_.Exception.Message 'ERROR'
        Add-Content -LiteralPath $LogFile -Value $_.ScriptStackTrace -Encoding UTF8
        Write-Log 'Something went wrong. Everything that finished is kept. You can run it again, or choose "Doctor" to create a zip to send to whoever helped you install.' 'WARN'
    } finally {
        if ($Name -in @('install', 'update', 'rollback', 'uninstall', 'self-update', 'hf-login')) { Show-Summary }
        else { Write-Host "    Log: $LogFile" -ForegroundColor DarkGray }
    }
    return -not $failed
}

# ----------------------------------------------------------------------------
# Entry point
# ----------------------------------------------------------------------------
if ($Command -eq 'menu') { Show-Menu; exit 0 }
$ok = Start-Action $Command
if ($ok) { exit 0 } else { exit 1 }
