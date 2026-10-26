# =============================================================================
# BasetuneHelpers.psm1
# Cross-layer helpers used by both CLI and UI.
# Loaded as the FIRST nested module by BasetuneCore.psd1, so every later
# module can call Write-Log without an explicit import.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# Logging — Write-Log with optional GUI callback (Set-LogCallback)
#
# Every message is a log entry (New-LogEntry): Level, Label, Message. The
# sinks read the fields; nothing builds or parses a "[LEVEL][Label] message"
# string. Three sinks:
#   - CLI:         no callback set → Write-Host (WARN / ERROR in colour)
#   - UI runspace: callback enqueues the entry to a ConcurrentQueue, drained
#                  by a DispatcherTimer on the UI thread (Add-UILogLines)
#   - File:        when Set-LogFile set a path, every entry is also
#                  appended there (best-effort, never throws)
# ─────────────────────────────────────────────────────────────────────────────

# The log levels: INFO (progress, results, everything else), WARN, ERROR.
# Write-Log, Write-UILog, Clear-UILog and New-LogEntry validate against them.
# A new level also needs its colour in Write-Log, the log view
# (Add-UILogLines) and its CMTrace type (ConvertTo-CMTraceLine).

# One log entry. Label = the area the message is about (Compare, Source,
# Config, ...): the Component column in CMTrace, not shown in the log view or
# the console.
function New-LogEntry {
    param([string]$Label, [string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    return [pscustomobject]@{ Level = $Level; Label = $Label; Message = $Message }
}

$script:LogCallback = $null
$script:LogFile     = $null
$script:LogSource   = ''      # 'UI' or 'CLI' (Set-LogFile -Source): CMTrace file field, shown as "Source" in the detail pane

# One log entry (New-LogEntry) to the log file. UI, its runspaces, the
# parallel load workers and the CLI (another process) all write
# Logs\Basetune.log, so a named mutex serialises the writes (same Windows
# session; no 'Global\' prefix needed), and a busy file gets a few short
# retries instead of losing the line. An entry without text (the separator
# line) is skipped. Best-effort: never throws.
function Add-LogFileLine {
    param([string]$Path, $Entry, [string]$Source = $script:LogSource)
    if (-not $Path -or -not $Entry -or [string]::IsNullOrWhiteSpace($Entry.Message)) { return }
    $text = (ConvertTo-CMTraceLine $Entry -Source $Source) + "`r`n"
    $mx = $null; $owned = $false
    try {
        $mx = [System.Threading.Mutex]::new($false, 'Basetune_LogFile')
        try { $owned = $mx.WaitOne(2000) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
        for ($i = 0; $i -lt 3; $i++) {
            try { [System.IO.File]::AppendAllText($Path, $text, [System.Text.UTF8Encoding]::new($false)); break }
            catch { Start-Sleep -Milliseconds 50 }
        }
    } catch {
    } finally {
        if ($mx) {
            if ($owned) { try { $mx.ReleaseMutex() } catch {} }
            $mx.Dispose()
        }
    }
}

function Get-LogSource { return $script:LogSource }

# The Basetune version ("3.0.1"): ModuleVersion of BasetuneCore.psd1 (next to
# this file), read once. The manifest is the one place to change it.
$script:BasetuneVersion = $null
function Get-BasetuneVersion {
    if (-not $script:BasetuneVersion) {
        try {
            $script:BasetuneVersion = [string](Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'BasetuneCore.psd1')).ModuleVersion
        } catch { $script:BasetuneVersion = '' }
        if (-not $script:BasetuneVersion) { $script:BasetuneVersion = 'unknown' }
    }
    return $script:BasetuneVersion
}

function Write-Log {
    param([string]$Label, [string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO', [switch]$FileOnly)

    # Write-Log '' '' → an empty entry: a blank line on the console, nothing
    # in the log view or the log file.
    $entry = New-LogEntry $Label $Message $Level

    # Log file, if set: CMTrace format (ConvertTo-CMTraceLine), best-effort.
    if ($script:LogFile) {
        Add-LogFileLine -Path $script:LogFile -Entry $entry
    }
    # -FileOnly: technical detail for the log file, not for the log view/console.
    if ($FileOnly) { return }

    # If a GUI callback is set, forward the entry there (no console output
    # from runspaces).
    if ($script:LogCallback) {
        & $script:LogCallback $entry
        return
    }

    # Console (CLI): only the message, like the UI log view. WARN and ERROR in
    # colour, INFO in the console's own colour. The log file keeps the label
    # (CMTrace Component).
    switch ($Level) {
        'WARN'  { Write-Host $Message -ForegroundColor Yellow }
        'ERROR' { Write-Host $Message -ForegroundColor Red }
        default { Write-Host $Message }
    }
}

# The callback gets one log entry (New-LogEntry) per Write-Log call.
function Set-LogCallback {
    param([scriptblock]$Callback)
    $script:LogCallback = $Callback
}

# Log setup at the start of a UI background runspace (after it imports
# BasetuneCore.psd1): every Write-Log entry goes to the runspace's queue (the
# UI drains it into the log view) and, with a path, also to the log file.
function Set-RunspaceLogging {
    param([Parameter(Mandatory)]$Queue, [string]$LogFile, [string]$Source = 'UI')
    Set-LogCallback ({ param($entry) $Queue.Enqueue($entry) }.GetNewClosure())
    if ($LogFile) { try { Set-LogFile -Path $LogFile -Source $Source } catch {} }
}
function Set-LogFile {
    param(
        [string]$Path,
        # Only the UI and CLI scripts pass -Rotate, once at startup. Runspaces
        # (same path) must never rotate: several may be writing at once.
        [switch]$Rotate,
        [long]$MaxBytes = 5MB,
        # Rotated logs kept (the newest); older ones are deleted.
        [int]$KeepRotated = 5,
        # 'UI' or 'CLI': UI and CLI share Logs\Basetune.log; written to the
        # CMTrace file field (Source in the detail pane).
        [string]$Source = ''
    )
    $script:LogFile = $Path
    if ($Source) { $script:LogSource = $Source }

    # Size limit (startup only, see -Rotate): a log larger than $MaxBytes is
    # renamed with the time of its last line and a new log is started:
    #     Basetune.log -> Basetune_20261019_103512.log
    # The $KeepRotated newest rotated logs stay. Best-effort, never throws.
    if ($Rotate) {
        try {
            if ($Path -and (Test-Path -LiteralPath $Path)) {
                $item = Get-Item -LiteralPath $Path -ErrorAction Stop
                if ($item.Length -gt $MaxBytes) {
                    $stamp = $item.LastWriteTime.ToString('yyyyMMdd_HHmmss')
                    $dest  = Join-Path $item.DirectoryName "$($item.BaseName)_$stamp$($item.Extension)"
                    Move-Item -LiteralPath $Path -Destination $dest -Force -ErrorAction Stop

                    # Only names of this form (<name>_yyyyMMdd_HHmmss<ext>):
                    # other files in the folder are never touched.
                    $rx = '^' + [regex]::Escape($item.BaseName) + '_\d{8}_\d{6}' + [regex]::Escape($item.Extension) + '$'
                    Get-ChildItem -LiteralPath $item.DirectoryName -File |
                        Where-Object { $_.Name -match $rx } |
                        Sort-Object Name -Descending |
                        Select-Object -Skip $KeepRotated |
                        Remove-Item -Force -ErrorAction SilentlyContinue
                }
            }
        } catch {}
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# CMTrace log line
#
# A log entry (New-LogEntry) -> CMTrace / ConfigMgr log format, so
# Logs\*.log opens in CMTrace with columns (Log Text, Component, Date/Time,
# Thread) and colouring: ERROR -> type 3 (red), WARN -> type 2 (yellow),
# INFO -> 1. Component = the label ("Basetune" when it has none).
# Time bias = minutes to add to local time for UTC (ConfigMgr convention,
# e.g. -120 for UTC+2).
# ─────────────────────────────────────────────────────────────────────────────
function ConvertTo-CMTraceLine {
    param([Parameter(Mandatory)]$Entry, [string]$Source = '')
    $msg       = [string]$Entry.Message
    $Component = if ($Entry.Label) { [string]$Entry.Label } else { 'Basetune' }
    $type = switch ($Entry.Level) { 'ERROR' { 3 } 'WARN' { 2 } default { 1 } }
    $now  = Get-Date
    $bias = -[int][System.TimeZoneInfo]::Local.GetUtcOffset($now).TotalMinutes
    $time = $now.ToString('HH:mm:ss.fff') + $bias.ToString('+0;-0;+0')
    $date = $now.ToString('MM-dd-yyyy')
    $thr  = [System.Threading.Thread]::CurrentThread.ManagedThreadId
    return '<![LOG[' + $msg + ']LOG]!><time="' + $time + '" date="' + $date +
           '" component="' + $Component + '" context="" type="' + $type +
           '" thread="' + $thr + '" file="' + $Source + '">'   # file = "Source" in the CMTrace detail pane: UI / CLI
}

# ─────────────────────────────────────────────────────────────────────────────
# Tenant auth-method classifier
# Online (call Graph) or Offline (read JSON from disk); the single source of
# truth for CLI and UI.
#
# Input : Node — the raw tenant node (PSCustomObject from Config.json, or an
#                ordered hashtable built by Save-TenantForm). May be $null.
# Output: 'Offline' if Node is missing, has no authMethod, or authMethod='None';
#         'Online'  otherwise.
# ─────────────────────────────────────────────────────────────────────────────
function Get-TenantMode {
    param($Node)
    if (-not $Node) { return 'Offline' }

    # PSCustomObject (from JSON) or IDictionary (ordered hash): Get-NodeValue
    $auth = Get-NodeValue $Node 'authMethod'

    if (-not $auth -or $auth -eq 'None') { return 'Offline' }
    return 'Online'
}

# ─────────────────────────────────────────────────────────────────────────────
# Secret encryption — DPAPI (Data Protection API)
#
# Encrypts client secrets so Config.json holds no plaintext. DPAPI with
# CurrentUser scope: only the same Windows user on the same machine can
# decrypt.
#
# Why CurrentUser scope?
#   - LocalMachine: any user on the box (service accounts, admin RDP
#     sessions) could decrypt.
#   - Roaming/portable: needs an own key file + key rotation; overkill for a
#     local admin tool.
#   - CurrentUser is what the Graph PowerShell SDK, AzureAD and
#     Connect-AzAccount use for their token caches.
#
# Storage format: encrypted values start with "DPAPI:", so reads tell them
# apart without a try/catch. Anything else is plaintext (an older Config.json;
# encrypted on first read, see Get-BasetuneConfig).
#
# Decrypt failure (config from another user or machine): DPAPI throws,
# Unprotect-Secret returns $null and the caller logs "re-enter the secret".
# The tenant still appears in the UI, only the credential is missing.
# ─────────────────────────────────────────────────────────────────────────────

$script:DpapiPrefix = 'DPAPI:'

function Test-SecretEncrypted {
    param([string]$Value)
    return ($Value -is [string]) -and $Value.StartsWith($script:DpapiPrefix)
}

function Protect-Secret {
    param([Parameter(Mandatory)][string]$Plain)   # Mandatory: an empty value is refused

    # ConvertFrom-SecureString (no -Key) = DPAPI CurrentUser; hex blob, prefixed.
    $secure  = ConvertTo-SecureString -String $Plain -AsPlainText -Force
    $blob    = ConvertFrom-SecureString -SecureString $secure
    return "$($script:DpapiPrefix)$blob"
}

function Unprotect-Secret {
    param([string]$Encrypted)

    if ([string]::IsNullOrEmpty($Encrypted)) { return '' }
    if (-not (Test-SecretEncrypted $Encrypted)) {
        # Plaintext from an older Config.json: returned as-is;
        # Get-BasetuneConfig encrypts it.
        return $Encrypted
    }

    $blob = $Encrypted.Substring($script:DpapiPrefix.Length)
    try {
        # -ErrorAction Stop: without it ConvertTo-SecureString writes a bad blob
        # (tampered, or from another machine) to the host error stream before
        # throwing, bypassing this try/catch and landing in the parent CMD window.
        $secure = ConvertTo-SecureString -String $blob -ErrorAction Stop
        # Back to plain text: the token endpoint needs the secret in a
        # form-encoded POST body. It lives on the GC heap only for the token
        # exchange.
        $bstr  = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        } finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    } catch {
        # Wrong user/machine, corrupted or tampered blob. Get-BasetuneConfig
        # sees $null and logs an actionable error.
        return $null
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# MaxThreads validation
# For ForEach-Object -Parallel -ThrottleLimit, which must be >= 1 (0 or
# garbage would abort the whole load). Outside 1..32 or not a number -> 8.
# ─────────────────────────────────────────────────────────────────────────────
$script:MaxThreadsDefault = 8
$script:MaxThreadsMin     = 1
$script:MaxThreadsMax     = 32

function Get-ValidMaxThreads {
    param($Value)
    $n = 0
    if ($null -eq $Value -or -not [int]::TryParse("$Value".Trim(), [ref]$n)) {
        return $script:MaxThreadsDefault
    }
    if ($n -lt $script:MaxThreadsMin) { return $script:MaxThreadsDefault }
    if ($n -gt $script:MaxThreadsMax) { return $script:MaxThreadsDefault }
    return $n
}

function Test-MaxThreadsValue {
    # $true for a whole number in range. The Options dialog uses this to
    # refuse a bad value instead of silently replacing it.
    param($Value)
    $n = 0
    if ($null -eq $Value -or -not [int]::TryParse("$Value".Trim(), [ref]$n)) { return $false }
    return ($n -ge $script:MaxThreadsMin -and $n -le $script:MaxThreadsMax)
}

function Get-MaxThreadsRange {
    return [PSCustomObject]@{ Min = $script:MaxThreadsMin; Max = $script:MaxThreadsMax; Default = $script:MaxThreadsDefault }
}

# ─────────────────────────────────────────────────────────────────────────────
# Folder path validation — used for the report path (Config.json, -ReportPath,
# Options window) and -ExportPath.
#
# Returns [PSCustomObject]@{ Path; Error }:
#   Path  — normalized full path (single backslashes, no trailing backslash
#           except on a drive root such as C:\), or $null when invalid
#   Error — reason the path is invalid, or $null
#
# Accepted:  C:\Reports, C:\Reports\,
#            relative paths (Reports, .\Reports) when -BasePath is given
# Rejected:  network paths (\\server\share): a share is not always available.
#            Allowed with -AllowNetwork: base folder (Basetune or the current
#            folder may be on a share) and the CLI -ExportPath.
#            c:dddd / C: (drive-relative), \Reports (no drive), invalid
#            characters, reserved names (CON, NUL, ...), a drive that does
#            not exist on this PC
# The folder itself does NOT have to exist.
# ─────────────────────────────────────────────────────────────────────────────
function Resolve-FolderPath {
    param(
        [string]$Path,
        [string]$BasePath = '',
        [switch]$RequireAbsolute,
        [switch]$AllowNetwork       # base folder and CLI -ExportPath (see above)
    )

    $fail = { param($m) [PSCustomObject]@{ Path = $null; Error = $m } }

    $p = if ($null -eq $Path) { '' } else { $Path.Trim() }
    # Pasted "C:\My Reports" (with quotes) from Explorer's "Copy as path".
    if ($p.Length -ge 2 -and $p.StartsWith('"') -and $p.EndsWith('"')) { $p = $p.Substring(1, $p.Length - 2).Trim() }
    if (-not $p) { return & $fail "Path is empty" }
    $orig = $p
    $p = $p -replace '/', '\'

    $example = "Use a full path such as C:\Reports"
    $prefix  = ''
    $rest    = ''

    if (-not $AllowNetwork -and $p -match '^\\\\') {
        return & $fail "Network paths (\\server\share) are not supported. Use a local folder such as C:\Reports"
    }
    if ($p -match '^\\\\') {
        # UNC: \\server\share[\...]
        if ($p -notmatch '^\\\\([^\\]+)\\+([^\\]+)(.*)$') {
            return & $fail "'$orig' is not a complete network path. $example"
        }
        $srv = $Matches[1]; $share = $Matches[2]; $rest = $Matches[3]
        if ("$srv$share" -match '[<>"|?*:]') {
            return & $fail "'$orig' contains invalid characters (< > : `" | ? *)"
        }
        $prefix = "\\$srv\$share"
    }
    elseif ($p -match '^([A-Za-z]):\\(.*)$') {
        $prefix = "$($Matches[1].ToUpper()):"
        $rest   = "\$($Matches[2])"
    }
    elseif ($p -match '^[A-Za-z]:') {
        # C:Reports resolves against drive C's current folder: never intended.
        return & $fail "'$orig' is not a valid folder path (missing '\' after the drive letter). $example"
    }
    elseif ($p -match '^\\') {
        return & $fail "'$orig' has no drive letter. $example"
    }
    else {
        if ($RequireAbsolute -or -not $BasePath) {
            return & $fail "'$orig' is not a full path. $example"
        }
        $base = Resolve-FolderPath -Path $BasePath -AllowNetwork
        if ($base.Error) { return & $fail "Base folder for '$orig' is not valid: $($base.Error)" }
        return Resolve-FolderPath -Path ($base.Path.TrimEnd('\') + '\' + $p) -AllowNetwork
    }

    # Check every folder name after the drive/share.
    $segments = [System.Collections.Generic.List[string]]::new()
    foreach ($seg in ($rest -split '\\+')) {
        if ($seg -eq '' -or $seg -eq '.') { continue }
        if ($seg -eq '..') {
            if ($segments.Count -gt 0) { $segments.RemoveAt($segments.Count - 1) }
            continue
        }
        if ($seg -match '[<>:"|?*]' -or $seg -match '[\x00-\x1F]') {
            return & $fail "'$orig' contains invalid characters (< > : `" | ? *)"
        }
        if ($seg -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$') {
            return & $fail "'$orig' contains a reserved Windows name ('$seg')"
        }
        if ($seg -ne $seg.TrimEnd(' ', '.')) {
            return & $fail "'$orig': folder names cannot end with a space or a dot ('$seg')"
        }
        $segments.Add($seg)
    }

    $full = if ($segments.Count -gt 0) { $prefix + '\' + ($segments -join '\') }
            elseif ($prefix -match '^[A-Z]:$') { "$prefix\" }   # drive root C:\
            else { $prefix }                                    # \\server\share

    # Drive must exist (Windows only). Shares are not probed: slow, and they
    # give their own error on create.
    if ($prefix -match '^[A-Z]:$' -and ($IsWindows -or $env:OS -eq 'Windows_NT')) {
        if (-not (Test-Path -LiteralPath "$prefix\")) {
            return & $fail "Drive $prefix does not exist on this PC ('$orig')"
        }
    }

    return [PSCustomObject]@{ Path = $full; Error = $null }
}

# ─────────────────────────────────────────────────────────────────────────────
# Platforms (settings.platforms in Config.json)
# Which Settings Catalog platforms are loaded. Keys lower-case in Config.json,
# label shown in the UI. Default: Windows only. Get-PlatformKey maps Graph's
# per-policy 'platforms' (windows10, macOS, iOS, ...) to these keys.
# ─────────────────────────────────────────────────────────────────────────────
$script:PlatformOptions = @(
    [PSCustomObject]@{ Key = 'windows'; Label = 'Windows' }
    [PSCustomObject]@{ Key = 'macos';   Label = 'macOS'   }
    [PSCustomObject]@{ Key = 'ios';     Label = 'iOS'     }
    [PSCustomObject]@{ Key = 'android'; Label = 'Android' }
    [PSCustomObject]@{ Key = 'linux';   Label = 'Linux'   }
)
$script:PlatformDefault = @('windows')

function Get-PlatformOptions { return $script:PlatformOptions }
function Get-DefaultPlatforms { return [string[]]$script:PlatformDefault }

# Graph 'platforms' value -> key ('windows', 'macos', ...), or $null when the
# policy has no (known) platform. A JSON export without the field is $null too.
function Get-PlatformKey {
    param($Value)
    # No pipeline: runs for every policy of a load (1000+ for a large folder).
    if ($null -eq $Value) { return $null }
    foreach ($v in ("$Value" -split '[,\s]+')) {
        if (-not $v) { continue }
        switch ($v.ToLowerInvariant()) {
            { $_ -in 'windows', 'windows10', 'windows10x' }      { return 'windows' }
            'macos'                                             { return 'macos' }
            { $_ -in 'ios', 'ipados', 'visionos', 'tvos' }       { return 'ios' }
            { $_ -in 'android', 'androidenterprise', 'aosp' }   { return 'android' }
            'linux'                                             { return 'linux' }
        }
    }
    return $null
}

function Get-PlatformLabel {
    param([string]$Key)
    $o = $script:PlatformOptions | Where-Object { $_.Key -eq $Key } | Select-Object -First 1
    if ($o) { return $o.Label } else { return $Key }
}

# Config value (array, or a single string) -> valid keys in the fixed order
# (Windows, macOS, iOS, Android, Linux). Nothing valid -> default (Windows).
function Get-ValidPlatforms {
    param($Value)
    $wanted = @($Value | ForEach-Object { "$_".Trim().ToLowerInvariant() } | Where-Object { $_ })
    $keys = [string[]]@($script:PlatformOptions | Where-Object { $_.Key -in $wanted } | ForEach-Object { $_.Key })
    if ($keys.Count -eq 0) { return [string[]]$script:PlatformDefault }
    return $keys
}

# ─────────────────────────────────────────────────────────────────────────────
# PLATFORM FILTER (settings.platforms / CLI -Platforms)
# Used by the load module (UI + CLI compare) and the CLI export.
#
# Test-PolicyPlatform: $true when the policy belongs to a selected platform.
# A policy WITHOUT a (known) platform is never loaded (the compare matches
# settings per platform); counted under '__noplatform'. No platforms given =
# no filter, but a platform is still required.
# Write-PlatformSkipLog: one line per reason, e.g.
#   "Skipped 12 policies for other platforms (macOS: 8, iOS: 4)"
#   "Skipped 3 policies without platform"
# ─────────────────────────────────────────────────────────────────────────────
function Test-PolicyPlatform {
    param($PlatformsValue, [string[]]$Platforms, [hashtable]$Skipped)
    $key = Get-PlatformKey $PlatformsValue
    if (-not $key) {
        $Skipped['__noplatform'] = 1 + [int]$Skipped['__noplatform']
        return $false
    }
    if (-not $Platforms -or $Platforms.Count -eq 0) { return $true }
    if ($key -in $Platforms) { return $true }
    $lbl = Get-PlatformLabel $key
    $Skipped[$lbl] = 1 + [int]$Skipped[$lbl]
    return $false
}

function Write-PlatformSkipLog {
    param([string]$Label, [hashtable]$Skipped)
    if (-not $Skipped -or $Skipped.Count -eq 0) { return }
    $none = [int]$Skipped['__noplatform']
    if ($none -gt 0) {
        $nn = if ($none -eq 1) { 'policy' } else { 'policies' }
        Write-Log $Label "Skipped $none $nn without platform" "WARN"
    }
    $total = [int](($Skipped.GetEnumerator() | Where-Object { $_.Key -ne '__noplatform' } |
                    ForEach-Object { $_.Value } | Measure-Object -Sum).Sum)
    if ($total -eq 0) { return }
    $noun  = if ($total -eq 1) { 'policy' } else { 'policies' }
    # Order of the platform options (Windows, macOS, iOS, Android, Linux).
    $parts = @(Get-PlatformOptions | Where-Object { $Skipped.ContainsKey($_.Label) } |
               ForEach-Object { "$($_.Label): $($Skipped[$_.Label])" })
    Write-Log $Label "Skipped $total $noun for other platforms ($($parts -join ', '))" "INFO"
}

# Policy type from templateReference.templateFamily (column Type in the lists):
#   none / empty                 -> Settings Catalog
#   baseline                     -> Security Baseline
#   endpointSecurity...          -> Endpoint Security
#   enrollmentConfiguration      -> Enrollment (Device Preparation, ADE)
#   deviceConfigurationPolicies  -> Template (Configuration > Templates)
#   anything else                -> Other
# No templateReference at all (older exports): Settings Catalog.
# -EmptyWhenMissing (JSON tenants): templateReference missing or null = type
# unknown = empty label. One that IS there but empty ({}, empty
# templateFamily, 'none') is still Settings Catalog.
function Get-PolicyTypeLabel {
    param($TemplateReference, [switch]$EmptyWhenMissing)
    if ($EmptyWhenMissing -and $null -eq $TemplateReference) { return '' }
    $fam = ''
    if ($TemplateReference) { $fam = [string](Get-NodeValue $TemplateReference 'templateFamily') }
    $fam = $fam.Trim()
    if (-not $fam -or $fam -eq 'none')                  { return 'Settings Catalog' }
    if ($fam -eq 'baseline')                            { return 'Security Baseline' }
    if ($fam -like 'endpointSecurity*')                 { return 'Endpoint Security' }
    if ($fam -eq 'enrollmentConfiguration')             { return 'Enrollment' }
    if ($fam -eq 'deviceConfigurationPolicies')         { return 'Template' }
    return 'Other'
}

function Get-PlatformsText {
    param([string[]]$Platforms)
    return (@($Platforms | ForEach-Object { Get-PlatformLabel $_ }) -join ', ')
}

# Safe property read for tenant nodes. BasetuneGraph and BasetuneConfig run
# under Set-StrictMode -Version Latest, where a missing property throws; a
# hand-edited Config.json may lack authMethod, clientSecret, ... This returns
# $null instead of aborting the config load.
# Supports PSCustomObject (from JSON) and IDictionary (ordered hashtable).
# ─────────────────────────────────────────────────────────────────────────────
function Get-NodeValue {
    param($Node, [string]$Name)
    if ($null -eq $Node) { return $null }
    if ($Node -is [System.Collections.IDictionary]) {
        if ($Node.Contains($Name)) { return $Node[$Name] }
        return $null
    }
    $p = $Node.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

# ─────────────────────────────────────────────────────────────────────────────

# CSV separator for Diff.csv / Summary.csv: this PC's Windows list separator,
# the one Excel uses on a double-click (';' in BE/NL/DE/FR/..., ',' in
# US/UK/...). Any other separator (customised, Arabic semicolon, ...) gives
# ';'. Quoting keeps values with , ; or line breaks intact either way.
function Get-CsvDelimiter {
    $sep = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ListSeparator
    if ($sep -in ',', ';') { return [char]$sep }
    return [char]';'
}

# ─────────────────────────────────────────────────────────────────────────────
# PROCESS POWER THROTTLING (EcoQoS)
# Windows 11 can apply execution-speed throttling (EcoQoS) to a process,
# potentially reducing performance when the process is not in the foreground.
# Measured on one laptop: a large compare in the UI took about 55 s with
# another window in front and 33 s with Basetune in front, and about 34 s
# minimized once this setting was switched off. That points to throttling,
# but does not prove it was the only cause. While a job runs (UI) or for a
# whole CLI run, Basetune opts out of this one throttling setting:
#   Set-ProcessPowerThrottling -Enabled $false   disable execution-speed throttling
#   Set-ProcessPowerThrottling -Enabled $true    restore default Windows management
# It does not guarantee the highest clock speed or performance cores only:
# Windows still manages power in other ways (power mode, temperature, ...).
# SetProcessInformation(ProcessPowerThrottling), EXECUTION_SPEED bit in
# ControlMask: StateMask 0 = do not throttle; ControlMask 0 = Windows decides
# (the default). The P/Invoke type is compiled on the first call (about
# 0.4 s), not at startup. Best effort: failures are ignored (older Windows).
# ─────────────────────────────────────────────────────────────────────────────
function Set-ProcessPowerThrottling {
    param([Parameter(Mandatory)][bool]$Enabled)
    try {
        if (-not ('Basetune.PowerThrottling' -as [type])) {
            # Not compiled yet = never switched off: nothing to restore.
            if ($Enabled) { return }
            Add-Type -Namespace Basetune -Name PowerThrottling -MemberDefinition @'
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct State { public uint Version; public uint ControlMask; public uint StateMask; }
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetProcessInformation(System.IntPtr process, int infoClass, ref State info, int size);
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr GetCurrentProcess();
'@
        }
        $state = New-Object 'Basetune.PowerThrottling+State'
        $state.Version     = 1                               # PROCESS_POWER_THROTTLING_CURRENT_VERSION
        $state.ControlMask = if ($Enabled) { 0 } else { 1 }  # 1 = PROCESS_POWER_THROTTLING_EXECUTION_SPEED
        $state.StateMask   = 0
        # 4 = ProcessPowerThrottling; 12 = size of the struct (3 x uint).
        [void][Basetune.PowerThrottling]::SetProcessInformation([Basetune.PowerThrottling]::GetCurrentProcess(), 4, [ref]$state, 12)
    } catch {}
}

Export-ModuleMember -Function @(
    'Get-BasetuneVersion',
    'Get-CsvDelimiter',
    'Set-ProcessPowerThrottling',
    'Add-LogFileLine',
    'Get-LogSource',
    'New-LogEntry',
    'Write-Log',
    'Set-LogCallback',
    'Set-RunspaceLogging',
    'Set-LogFile',
    'ConvertTo-CMTraceLine',
    'Get-TenantMode',
    'Test-SecretEncrypted',
    'Protect-Secret',
    'Unprotect-Secret',
    'Get-ValidMaxThreads',
    'Test-MaxThreadsValue',
    'Get-MaxThreadsRange',
    'Resolve-FolderPath',
    'Get-PlatformOptions',
    'Get-DefaultPlatforms',
    'Get-PlatformKey',
    'Get-PlatformLabel',
    'Get-ValidPlatforms',
    'Test-PolicyPlatform',
    'Write-PlatformSkipLog',
    'Get-PolicyTypeLabel',
    'Get-PlatformsText',
    'Get-NodeValue'
)
