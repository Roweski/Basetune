# =============================================================================
# BasetuneSettings.psm1
# Config.json (tenants) and Options.json in the UI: load at startup, save,
# and fill the tenant dropdowns (main window + Tenant Configuration).
# The tenant form itself is in BasetuneConfigWindow.psm1; Get-TenantMode is in
# BasetuneHelpers.psm1 (shared with the CLI).
# =============================================================================

# Controls of the main and config window, by x:Name (BasetuneState.psm1).
$script:UI = (Get-BasetuneContext).UI
# Paths, config, tenants and form state (initialised in Basetune.ps1).
$script:AppState = (Get-BasetuneContext).State

# ── Helpers: dropdown population ─────────────────────────────────────────────
function script:Add-TenantItemsToDropdown {
    param($Cmb, [string]$SelectTag)
    if (-not $Cmb) { return }
    $Cmb.Items.Clear()
    foreach ($key in (Get-SortedTenantKeys)) {
        $node      = $AppState.tenantStore[$key]
        $label     = if ($node.displayName) { $node.displayName } else { $key }
        $isOffline = $node.authMethod -eq 'None' -or -not $node.authMethod
        $display   = if ($isOffline) { "$label (JSON)" } else { $label }
        $Cmb.Items.Add((New-TenantComboItem $display $key)) | Out-Null
    }
    if ($SelectTag) {
        Select-ComboByTag $Cmb $SelectTag | Out-Null
    } elseif ($Cmb.Items.Count -gt 0) {
        $Cmb.SelectedIndex = 0
    }
}

function script:New-TenantComboItem {
    param([string]$Content, [string]$Tag)
    $item = [System.Windows.Controls.ComboBoxItem]::new()
    $item.Content = $Content
    $item.Tag     = $Tag
    # JSON tenants use the same text colour as the others (theme TextBrush).
    return $item
}

function script:Get-SortedTenantKeys {
    return $AppState.tenantStore.Keys | Sort-Object {
        $n = $AppState.tenantStore[$_]
        if ($n -and $n.PSObject.Properties['displayName'] -and $n.displayName) { $n.displayName } else { $_ }
    }
}

# ── Options (Options.json) ────────────────────────────────────────────────────
# Read once at startup, after Import-Config (a new Config.json is reported
# before a new Options.json). Get-BasetuneOptions creates / repairs the file
# and logs what it changed. A relative report path is relative to Basetune.
function Import-Options {
    $opt = Get-BasetuneOptions -Path "$($AppState.ScriptRoot)\Config\Options.json"
    $AppState.savedMaxThreads = "$($opt.MaxThreads)"
    $AppState.savedTheme      = if ($opt.Theme -eq 'light') { 'light' } else { 'dark' }
    $AppState.savedPlatforms  = [string[]](Get-ValidPlatforms $opt.Platforms)
    $rp = Resolve-FolderPath -Path $opt.ReportPath -BasePath $AppState.ScriptRoot
    if ($rp.Error) {
        # Already repaired in Options.json; fallback when that write failed.
        $AppState.savedPathReport = $AppState.reportBasePath
    } else {
        $AppState.reportBasePath  = $rp.Path
        $AppState.savedPathReport = $rp.Path
    }
}

# Writes the current options to Options.json (Options window, Save).
# Throws on a write error; the caller reports it.
function Save-Options {
    $pathReport = if ($AppState.savedPathReport -and $AppState.savedPathReport.Trim()) { $AppState.savedPathReport.Trim() } else { $AppState.reportBasePath }
    Save-BasetuneOptions -Path "$($AppState.ScriptRoot)\Config\Options.json" `
        -ReportPath $pathReport -Platforms $AppState.savedPlatforms -Theme $AppState.savedTheme -MaxThreads $AppState.savedMaxThreads
}

# ── Load config ───────────────────────────────────────────────────────────────
function Import-Config {
    # -Quiet: reload without logging an invalid Config.json again (closing
    # Tenant Configuration); startup and Save config still report it.
    param([switch]$Quiet)
    $configPath = "$($AppState.ScriptRoot)\Config\Config.json"
    $AppState.tenantStore.Clear()
    $AppState.configLoadError = $null
    $AppState.configReadFailed = $false   # invalid/unreadable: no "No tenants found" at startup

    if (Test-Path $configPath) {
        try {
            $AppState.cfg = Get-BasetuneConfig $configPath

            # Invalid JSON is reported (otherwise no tenants appear without a
            # reason) and remembered, so Save-Config does not overwrite the
            # unreadable file with an empty config.
            if ($AppState.cfg.PSObject.Properties['__configError'] -and $AppState.cfg.__configError) {
                $AppState.configLoadError = $AppState.cfg.__configError
                $AppState.configReadFailed = $true
                if (-not $Quiet) {
                    Write-Log 'Config' "$($AppState.cfg.__configError)" 'ERROR'
                    if ($AppState.cfg.PSObject.Properties['__configErrorDetail'] -and $AppState.cfg.__configErrorDetail) {
                        Write-Log 'Config' "Details: $($AppState.cfg.__configErrorDetail)" 'ERROR' -FileOnly
                    }
                }
            }

            # The options are in Options.json (Import-Options).

            if ($AppState.cfg.PSObject.Properties['tenant'] -and $AppState.cfg.tenant) {
                foreach ($prop in $AppState.cfg.tenant.PSObject.Properties) {
                    $AppState.tenantStore[$prop.Name] = $prop.Value
                }
            }
        } catch {
            $AppState.configReadFailed = $true
            $msg = "Could not read Config.json. See the log file for details"
            try {
                Write-Log 'Config' $msg 'ERROR'
                Write-Log 'Config' "Details: $($_.Exception.Message)" 'ERROR' -FileOnly
            } catch { Write-Host $msg -ForegroundColor Red }
        }
    } else {
        # No Config.json (first start, or removed): create it with an empty
        # tenant block (and the Config folder). Log file only; the view shows
        # "Click the gear icon ..." once the window is loaded.
        try {
            Save-Config
            Write-Log 'Config' 'Config.json created with default values' 'INFO' -FileOnly
        } catch {
            Write-Log 'Config' "Could not write Config.json. See the log file for details" 'ERROR'
            Write-Log 'Config' "Details: $($_.Exception.Message)" 'ERROR' -FileOnly
        }
    }

    Update-ConfigDropdowns
}

# ── Dropdowns ─────────────────────────────────────────────────────────────────
function Update-ConfigDropdowns {
    if ($UI.lstTenants) {
        $sel = if ($AppState.editingTenantKey) { $AppState.editingTenantKey } else { '' }
        Add-TenantItemsToDropdown $UI.lstTenants $sel
    }
}

function Sync-MainTenantDropdowns {
    param([string]$PreferSrcTag = '', [string]$PreferTgtTag = '')
    $selSrc = if ($PreferSrcTag -and $AppState.tenantStore.Contains($PreferSrcTag)) { $PreferSrcTag } else { '' }
    $selTgt = if ($PreferTgtTag -and $AppState.tenantStore.Contains($PreferTgtTag)) { $PreferTgtTag } else { '' }
    Add-TenantItemsToDropdown $UI.cmbSourceTenant $selSrc
    Add-TenantItemsToDropdown $UI.cmbTargetTenant $selTgt
    # Placeholder "No tenants configured..." only when there are no tenants
    # (with tenants the first one is always selected).
    $hintVis = if (@($AppState.tenantStore.Keys).Count -gt 0) { 'Collapsed' } else { 'Visible' }
    foreach ($h in @($UI.txtSourceTenantHint, $UI.txtTargetTenantHint)) { if ($h) { $h.Visibility = $hintVis } }
    # Tenant Configuration button: normal look and tooltip (Reset-ConfigButtonStyle).
    if (Get-Command Reset-ConfigButtonStyle -ErrorAction SilentlyContinue) {
        Reset-ConfigButtonStyle
    }
    $AppState.tenantList = @($AppState.tenantStore.Keys | ForEach-Object {
        $k = $_; $n = $AppState.tenantStore[$k]
        [PSCustomObject]@{ Key = $k; Label = if ($n.displayName) { $n.displayName } else { $k }; Node = $n }
    })
}

function Select-ComboByTag {
    param($Cmb, [string]$Tag)
    if (-not $Cmb) { return $false }
    foreach ($item in $Cmb.Items) {
        if ($item.Tag -eq $Tag) { $Cmb.SelectedItem = $item; return $true }
    }
    return $false
}

# ── Save ──────────────────────────────────────────────────────────────────────
function Save-Config {
    if ($AppState.configLoadError) {
        # Config.json could not be read at startup: writing now would overwrite
        # it and lose the tenants. Callers append what was not saved.
        throw "$($AppState.configLoadError)"
    }
    $configPath = "$($AppState.ScriptRoot)\Config\Config.json"
    $configDir  = Split-Path $configPath

    # Config.json holds the tenants only (options: Save-Options).
    $out = [ordered]@{}

    # Tenants block. $AppState.tenantStore holds ENCRYPTED secrets
    # (Get-BasetuneConfig does not decrypt; Save-TenantForm encrypts). Each node
    # is copied into a fresh ordered hashtable, so the store is not mutated.
    $tenantsObj = [ordered]@{}
    foreach ($k in $AppState.tenantStore.Keys) {
        $src = $AppState.tenantStore[$k]
        if ($src -is [System.Collections.IDictionary]) {
            $dst = [ordered]@{}
            foreach ($key in $src.Keys) { $dst[$key] = $src[$key] }
        } else {
            # PSCustomObject (loaded from JSON) — convert to ordered hashtable
            $dst = [ordered]@{}
            foreach ($p in $src.PSObject.Properties) {
                if ($p.Name.StartsWith('__')) { continue }   # skip __invalid etc.
                $dst[$p.Name] = $p.Value
            }
        }

        # Encrypted secrets ("DPAPI:...") are written as-is. A plaintext value
        # (should not happen) is encrypted first; if that fails the save is
        # aborted rather than writing plaintext to disk.
        if ($dst['clientSecret'] -and -not (Test-SecretEncrypted ([string]$dst['clientSecret']))) {
            try {
                $dst['clientSecret'] = Protect-Secret ([string]$dst['clientSecret'])
            } catch {
                throw "Failed to encrypt clientSecret for tenant '$($dst['displayName'])': $($_.Exception.Message)"
            }
        }

        $tenantsObj[$k] = $dst
    }
    $out['tenant'] = $tenantsObj

    if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
    $out | ConvertTo-Json -Depth 8 | Out-File $configPath -Encoding UTF8
    try { $AppState.cfg = Get-BasetuneConfig $configPath } catch {}
}

Export-ModuleMember -Function @(
    'Import-Options',
    'Save-Options',
    'Import-Config',
    'Update-ConfigDropdowns',
    'Sync-MainTenantDropdowns',
    'Select-ComboByTag',
    'Save-Config'
)
