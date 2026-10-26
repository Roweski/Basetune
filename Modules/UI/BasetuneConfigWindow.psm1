# =============================================================================
# BasetuneConfigWindow.psm1
# Tenant Configuration window (Open-ConfigWindow) and its tenant form: fields
# per authentication method, validation and commit (Save-TenantForm),
# connection test and save. Config.json itself is written by Save-Config
# (BasetuneSettings.psm1). $UI / $AppState come from BasetuneState.psm1.
# =============================================================================

$script:UI       = (Get-BasetuneContext).UI
$script:AppState = (Get-BasetuneContext).State

# ═════════════════════════════════════════════════════════════════════════════
# FORM HELPERS — used by the handlers that Open-ConfigWindow wires up
# ═════════════════════════════════════════════════════════════════════════════
# Unsaved changes in the window: enables / disables Save.
$script:hasUnsavedChanges = $false

# Placeholder in the tenant dropdown while nothing is selected:
# "Add your first tenant below..." without tenants, "Enter tenant details
# below..." for a new tenant (+), "Select a tenant..." otherwise.
function Update-TenantListHint {
    $h = $UI.lstTenantsHint; $l = $UI.lstTenants
    if (-not $h -or -not $l) { return }
    $newForm = (-not $l.SelectedItem) -and (-not $AppState.editingTenantKey) -and
               $UI.pnlTenantForm -and $UI.pnlTenantForm.Visibility -eq 'Visible'
    $h.Text       = if ($l.Items.Count -eq 0) { 'Add your first tenant below' }
                    elseif ($newForm)         { 'Enter tenant details below' }   # after +
                    else                      { 'Select a tenant' }
    $h.Visibility = if ($l.SelectedItem) { 'Collapsed' } else { 'Visible' }
    # + : off without tenants, and off while the form for a new tenant is
    # open (until Save, or until an existing tenant is picked).
    if ($UI.btnAddTenant) { $UI.btnAddTenant.IsEnabled = ($l.Items.Count -gt 0) -and -not $newForm }
    # Nothing to pick from yet: the dropdown is disabled too.
    $l.IsEnabled = ($l.Items.Count -gt 0)
}

function Set-UnsavedChanges {
    $script:hasUnsavedChanges = $true
    if ($UI.btnSaveConfig) { $UI.btnSaveConfig.IsEnabled = $true }
}

# Save back on when the form has unsaved changes (after the policy folder or
# the authentication method changed). Network folders (\\server\share) are
# accepted, so the policy folder never blocks Save.
function Update-ConfigSaveButton {
    if ($UI.btnSaveConfig -and $script:hasUnsavedChanges) { $UI.btnSaveConfig.IsEnabled = $true }
}

function Clear-UnsavedChanges {
    $script:hasUnsavedChanges = $false
    if ($UI.btnSaveConfig) { $UI.btnSaveConfig.IsEnabled = $false }
}

# No tenants: the empty form for a new tenant, ready to type in.
# Tenants: the first one is selected (or -SelectKey, e.g. the tenant that
# was just saved); + starts an empty form for a new one.
function Reset-TenantFormState {
    param([string]$SelectKey = '')
    $l = $UI.lstTenants
    if ($l.Items.Count -gt 0) {
        $target = $null
        if ($SelectKey) { $target = @($l.Items | Where-Object { $_.Tag -eq $SelectKey }) | Select-Object -First 1 }
        if (-not $target) { $target = $l.Items[0] }
        $l.SelectedItem = $null     # so selecting always fills the form
        $l.SelectedItem = $target
    } else {
        Start-AddTenant
    }
    Clear-UnsavedChanges   # showing a tenant / an empty form is not a change
    Update-TenantListHint
}

# Snapshot of the saved tenants, to log what a Save changed:
#   Created tenant 'x' with authentication method 'ClientSecret'.
#   Removed tenant 'y'.
#   Updated tenant 'z'.
# (Get-TenantSnapshot below; Reset-ChangedSides first.)

# After a save or closing this window the main dropdowns are filled again
# with events suppressed, so the usual tenant-switch reset does not run. A
# side whose tenant changed (removed, or another one selected) is reset here:
# its loaded list, connection and card message ("Could not load policies")
# belong to a tenant that is no longer selected.
function Reset-ChangedSides {
    param([string]$PrevSrcTag, [string]$PrevTgtTag)
    foreach ($s in @(@('Source', $PrevSrcTag, $UI.cmbSourceTenant), @('Target', $PrevTgtTag, $UI.cmbTargetTenant))) {
        $now = if ($s[2] -and $s[2].SelectedItem) { "$($s[2].SelectedItem.Tag)" } else { '' }
        if ("$($s[1])" -ne $now) { Reset-Side $s[0] }
    }
}

# The encrypted clientSecret is left out of the comparison (it is
# re-encrypted on every commit); a typed secret marks the tenant updated.
function Get-TenantSnapshot {
    $snap = @{}
    foreach ($k in @($AppState.tenantStore.Keys)) {
        $h = $AppState.tenantStore[$k] | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
        # Only the fields the form edits, empty = missing, so a tenant that
        # is committed again unchanged does not count as updated.
        $sig = (@('displayName', 'authMethod', 'tenantId', 'clientId', 'certThumbprint', 'path') |
                ForEach-Object { "$_=$("$($h[$_])".Trim())" }) -join '|'
        $snap[$k] = @{
            Name = if ($h['displayName']) { "$($h['displayName'])" } else { $k }
            Auth = "$($h['authMethod'])"
            Sig  = $sig
        }
    }
    return $snap
}

# $true when the tenant list differs from the last save (e.g. a removed
# tenant that is not saved yet). Used when the form switches tenant:
# typed input is then discarded, so Save stays active only for this.
function Test-TenantStoreChanged {
    $before = $AppState.cfgTenantSnapshot
    $now    = Get-TenantSnapshot
    if ($before.Count -ne $now.Count) { return $true }
    foreach ($k in $now.Keys) {
        if (-not $before.ContainsKey($k) -or $before[$k].Sig -ne $now[$k].Sig) { return $true }
    }
    return $false
}

# "Required" follows the field while typing: emptying a required field
# shows it right away, typing removes it (also "Path not found"). Which
# fields are required depends on the authentication method, same rules
# as Save-TenantForm. Save checks everything again anyway.
function Test-TenantFieldRequired {
    param([string]$Name)
    $auth = if ($UI.cfgTenantAuthMethod.SelectedItem) { "$($UI.cfgTenantAuthMethod.SelectedItem.Content)" } else { 'ClientSecret' }
    switch ($Name) {
        'DisplayName'  { return $true }
        'TenantId'     { return $auth -ne 'None (JSON)' }
        'ClientId'     { return $auth -ne 'None (JSON)' }
        'ClientSecret' { return $auth -eq 'ClientSecret' }
        'CertThumb'    { return $auth -eq 'Certificate' }
        'JsonPath'     { return $auth -eq 'None (JSON)' }
    }
    return $false
}

# New tenant form emptied again (all fields blank): there is no new
# tenant. No "Required" marks, and Save only stays active for pending
# changes such as removed tenants. Registered last, so it runs after the
# handlers above (which mark Required / enable Save while typing).
function Test-NewTenantFormEmpty {
    $vals = @(
        $UI.cfgTenantDisplayName.Text, $UI.cfgTenantTenantId.Text, $UI.cfgTenantClientId.Text,
        $(if ($UI.cfgTenantClientSecret) { $UI.cfgTenantClientSecret.Password } else { '' }),
        $(if ($UI.cfgTenantClientSecretShown) { $UI.cfgTenantClientSecretShown.Text } else { '' }),
        $UI.cfgTenantCertThumbprint.Text, $UI.cfgTenantPath.Text
    )
    return -not ($vals | Where-Object { $_ -and "$_".Trim() })
}

# ── Key generation (numeric) ─────────────────────────────────────────────────
function New-TenantKey {
    # Returns the next available integer key (1, 2, 3, …)
    $existingNums = @($AppState.tenantStore.Keys | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
    $next = 1
    while ($existingNums -contains $next) { $next++ }
    return "$next"
}

# ── Required label helpers ────────────────────────────────────────────────────
function script:Show-Required {
    param([string]$Name)
    $ctrl = $AppState.requiredLabels[$Name]
    if ($ctrl) { $ctrl.Visibility = 'Visible' }
}

function script:Hide-Required {
    param([string]$Name)
    $ctrl = $AppState.requiredLabels[$Name]
    if ($ctrl) { $ctrl.Visibility = 'Collapsed' }
}

function script:Show-PathNotFound {
    param([string]$Name, [string]$Text = 'Path not found!')
    $ctrl = $AppState.requiredLabels[$Name]
    if ($ctrl) {
        $ctrl.Text       = $Text
        $ctrl.Visibility = 'Visible'
    }
}

function Clear-RequiredLabels {
    if (-not $AppState.requiredLabels) { return }
    foreach ($ctrl in $AppState.requiredLabels.Values) {
        if ($ctrl) { $ctrl.Text = 'Required!'; $ctrl.Visibility = 'Collapsed' }
    }
}

# ── Secret form helpers (PasswordBox + reveal TextBox) ───────────────────────
# The Client Secret field is two overlapping controls in the XAML:
#   - cfgTenantClientSecret      : PasswordBox (masked, visible by default)
#   - cfgTenantClientSecretShown : TextBox     (plain, hidden by default)
# btnRevealSecret swaps which one is visible.
# Read: the visible control wins. Write: always both, so the reveal toggle
# shows the same value either way.
function script:Get-TenantSecretFromForm {
    if ($UI.cfgTenantClientSecretShown -and
        $UI.cfgTenantClientSecretShown.Visibility -eq 'Visible') {
        return [string]$UI.cfgTenantClientSecretShown.Text
    }
    if ($UI.cfgTenantClientSecret) {
        return [string]$UI.cfgTenantClientSecret.Password
    }
    return ''
}

# ── Validate + commit form ────────────────────────────────────────────────────
function Save-TenantForm {

    if (-not $UI.cfgTenantDisplayName) { return $true }
    if ($UI.pnlTenantForm -and $UI.pnlTenantForm.Visibility -ne 'Visible') { return $true }

    # The empty form for a new tenant (open by default) with nothing typed:
    # nothing to commit, so e.g. saving after removing a tenant works. (Only
    # choosing a method does not enable Save for a new tenant.) Anything typed
    # is validated as a new tenant.
    if (-not $AppState.editingTenantKey) {
        $typed = @(
            $UI.cfgTenantDisplayName.Text, $UI.cfgTenantTenantId.Text, $UI.cfgTenantClientId.Text,
            (Get-TenantSecretFromForm), $UI.cfgTenantCertThumbprint.Text, $UI.cfgTenantPath.Text
        ) | Where-Object { $_ -and "$_".Trim() }
        if (-not $typed) { return $true }
    }

    Clear-RequiredLabels

    $valid = $true

    $label = $UI.cfgTenantDisplayName.Text.Trim()
    if (-not $label -or $label -match '[\\/:*?"<>|]') {
        Show-Required 'DisplayName'
        if (-not $UI.cfgTenantDisplayName.IsFocused) {
            $UI.cfgTenantDisplayName.Focus() | Out-Null
        }
        $valid = $false
    }

    $authSel = if ($UI.cfgTenantAuthMethod.SelectedItem) {
        $UI.cfgTenantAuthMethod.SelectedItem.Content } else { 'ClientSecret' }
    $authMethod = switch ($authSel) {
        'Certificate' { 'Certificate' }
        'None (JSON)' { 'None' }
        default       { 'ClientSecret' }
    }

    if ($authMethod -ne 'None') {
        if (-not $UI.cfgTenantTenantId.Text.Trim())  { Show-Required 'TenantId';     $valid = $false }
        if (-not $UI.cfgTenantClientId.Text.Trim())  { Show-Required 'ClientId';     $valid = $false }
        if ($authMethod -eq 'ClientSecret' -and -not (Get-TenantSecretFromForm).Trim()) {
            Show-Required 'ClientSecret'; $valid = $false
        }
        if ($authMethod -eq 'Certificate' -and -not $UI.cfgTenantCertThumbprint.Text.Trim()) {
            Show-Required 'CertThumb'; $valid = $false
        }
    } else {
        if (-not $UI.cfgTenantPath.Text.Trim()) { Show-Required 'JsonPath'; $valid = $false }
    }

    if (-not $valid) { return $false }

    $key = if ($AppState.editingTenantKey) {
        $AppState.editingTenantKey
    } else {
        New-TenantKey
    }

    $node = [ordered]@{ displayName = $label; authMethod = $authMethod }
    if ($authMethod -ne 'None') {
        $node.tenantId = $UI.cfgTenantTenantId.Text.Trim()
        $node.clientId = $UI.cfgTenantClientId.Text.Trim()
        if ($authMethod -eq 'ClientSecret') {
            # Encrypted right away: $AppState.tenantStore never holds a
            # plaintext secret; New-GraphConnection decrypts it just-in-time.
            try {
                $node.clientSecret = Protect-Secret ((Get-TenantSecretFromForm).Trim())
            } catch {
                Write-Log 'Config' 'Could not encrypt the client secret. See the log file for details' 'ERROR'
                Write-Log 'Config' "Details: $($_.Exception.Message)" 'ERROR' -FileOnly
                Show-Required 'ClientSecret'
                return $false
            }
        } else {
            $node.certThumbprint = $UI.cfgTenantCertThumbprint.Text.Trim()
        }
    } else {
        $typedPath = $UI.cfgTenantPath.Text.Trim()
        if (-not $typedPath) { Show-Required 'JsonPath'; return $false }
        # Network folders (\\server\share) are accepted: IsPathRooted is true for them.
        if (-not [System.IO.Path]::IsPathRooted($typedPath)) { Show-PathNotFound 'JsonPath'; return $false }
        $isExisting = [bool]$AppState.editingTenantKey
        if ($isExisting) {
            # Existing tenant: the path must exist. A missing one (renamed,
            # deleted) is not created silently; the user fixes it.
            if (-not (Test-Path $typedPath)) { Show-PathNotFound 'JsonPath'; return $false }
        } else {
            # New tenant — create the folder if it doesn't exist yet.
            try { New-Item -ItemType Directory -Path $typedPath -Force | Out-Null } catch { Show-PathNotFound 'JsonPath'; return $false }
        }
        $node.path = $typedPath
    }

    $AppState.tenantStore[$key] = $node
    $AppState.editingTenantKey  = $key
    return $true
}

# ── Form state ────────────────────────────────────────────────────────────────
function Show-TenantForm {
    param([switch]$IsNew)
    if ($UI.pnlTenantForm)   { $UI.pnlTenantForm.Visibility   = 'Visible' }
    if ($UI.btnRemoveTenant) {
        $UI.btnRemoveTenant.IsEnabled = -not $IsNew
    }
    Clear-RequiredLabels
    Update-TenantAuthFields
}

# ── Auth field visibility ─────────────────────────────────────────────────────
function Update-TenantAuthFields {
    $sel      = if ($UI.cfgTenantAuthMethod.SelectedItem) {
        $UI.cfgTenantAuthMethod.SelectedItem.Content } else { 'ClientSecret' }
    $isSecret = $sel -eq 'ClientSecret'
    $isCert   = $sel -eq 'Certificate'
    $isNone   = $sel -eq 'None (JSON)'

    # Hidden (not Collapsed) for None (JSON): the rows keep their space, so the
    # window keeps the height of the ClientSecret / Certificate form.
    $credVis = if ($isNone) { 'Hidden' } else { 'Visible' }
    $UI.pnlTenantId.Visibility   = $credVis
    $UI.pnlClientId.Visibility   = $credVis
    $UI.pnlCredential.Visibility = $credVis

    # ── ClientSecret controls ────────────────────────────────────────────────
    # Other methods: collapse both secret controls and the reveal eye, or the
    # revealed TextBox / eye stays in the row and pushes the Certificate
    # Thumbprint (same StackPanel) out of the card.
    $UI.lblTenantSecret.Visibility        = if ($isSecret) { 'Visible' } else { 'Collapsed' }
    $UI.cfgTenantClientSecret.Visibility  = if ($isSecret) { 'Visible' } else { 'Collapsed' }
    if ($UI.cfgTenantClientSecretShown -and -not $isSecret) {
        $UI.cfgTenantClientSecretShown.Visibility = 'Collapsed'
    }
    if ($UI.btnRevealSecret) {
        $UI.btnRevealSecret.Visibility = if ($isSecret) { 'Visible' } else { 'Collapsed' }
    }

    $UI.cfgTenantCertThumbprint.Visibility = if ($isCert)   { 'Visible' } else { 'Collapsed' }
    $UI.lblTenantThumb.Visibility          = if ($isCert)   { 'Visible' } else { 'Collapsed' }
    $UI.pnlTenantPath.Visibility           = if ($isNone)   { 'Visible' } else { 'Collapsed' }

    # Also hide any Required labels that belong to fields that are now hidden
    if ($isNone) {
        Hide-Required 'TenantId'; Hide-Required 'ClientId'
        Hide-Required 'ClientSecret'; Hide-Required 'CertThumb'
    } elseif ($isSecret) {
        Hide-Required 'CertThumb'; Hide-Required 'JsonPath'
    } elseif ($isCert) {
        Hide-Required 'ClientSecret'; Hide-Required 'JsonPath'
    }
}

# ── New tenant ────────────────────────────────────────────────────────────────
function Start-AddTenant {
    # Clearing the fields is not a change by the user: no "unsaved changes".
    $prevSuppress = $AppState.suppressEvents
    $AppState.suppressEvents = $true
    $UI.lstTenants.SelectedItem        = $null
    $AppState.editingTenantKey               = $null
    $UI.cfgTenantDisplayName.Text      = ''
    $UI.cfgTenantTenantId.Text         = ''
    $UI.cfgTenantClientId.Text         = ''
    # Clear both halves of the dual-control secret field + reset reveal-state
    if ($UI.cfgTenantClientSecret)      { $UI.cfgTenantClientSecret.Password = '' }
    if ($UI.cfgTenantClientSecretShown) {
        $UI.cfgTenantClientSecretShown.Text       = ''
        $UI.cfgTenantClientSecretShown.Visibility = 'Collapsed'
    }
    if ($UI.cfgTenantClientSecret)      { $UI.cfgTenantClientSecret.Visibility = 'Visible' }
    if ($UI.iconEyeOpen)                { $UI.iconEyeOpen.Visibility = 'Visible' }
    if ($UI.iconEyeOff)                 { $UI.iconEyeOff.Visibility  = 'Collapsed' }
    $UI.cfgTenantCertThumbprint.Text   = ''
    $UI.cfgTenantPath.Text             = ''
    $UI.cfgTenantAuthMethod.SelectedIndex = 0    # default: ClientSecret
    $AppState.suppressEvents = $prevSuppress
    Update-TenantAuthFields
    Show-TenantForm -IsNew

    # New tenant (no tenants yet, or the + button): cursor in Display Name.
    # Queued at ApplicationIdle, so it also works when this runs just before
    # the window is shown (no tenants: the form is opened before ShowDialog).
    $tb = $UI.cfgTenantDisplayName
    if ($tb) {
        [void]$tb.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::ApplicationIdle,
            [System.Action]{ if ($tb.IsVisible) { [void]$tb.Focus(); [void][System.Windows.Input.Keyboard]::Focus($tb) } }.GetNewClosure())
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# CONFIGURATION WINDOW
# ═════════════════════════════════════════════════════════════════════════════
function Open-ConfigWindow {
    $cfgWindow = Import-Xaml -Path "$($AppState.XamlPath)\BasetuneConfig.xaml" -Width 820 -Height 600
    $cfgWindow.Owner = $UI.Window

    function Find-ConfigControl { param([string]$n) Find-InTree -Root $cfgWindow -Name $n }

    # Register this window's controls (overwrites a previous window's in $UI)
    Register-BasetuneControls -Root $cfgWindow -Names @(
        'lstTenants', 'lstTenantsHint', 'btnAddTenant', 'btnRemoveTenant', 'btnSaveConfig',
        'lblConnectionStatus', 'pnlTenantForm',
        'cfgTenantDisplayName', 'cfgTenantAuthMethod', 'cfgTenantTenantId', 'cfgTenantClientId',
        'cfgTenantClientSecret',        # PasswordBox (masked)
        'cfgTenantClientSecretShown',   # TextBox (revealed)
        'btnRevealSecret',
        'iconEyeOpen', 'iconEyeOff',    # SVG paths, eye open / crossed-out
        'cfgTenantCertThumbprint', 'cfgTenantPath', 'btnBrowseTenantPath',
        'pnlTenantPath', 'pnlCredential', 'pnlTenantId', 'pnlClientId',
        'lblTenantSecret', 'lblTenantThumb'
    )

    if ($UI.lstTenants) {
        $UI.lstTenants.Add_SelectionChanged({ Update-TenantListHint })
        ([System.Collections.Specialized.INotifyCollectionChanged]$UI.lstTenants.Items).add_CollectionChanged({ Update-TenantListHint })
    }

    # Required label controls — used by Save-TenantForm to show inline errors
    $AppState.requiredLabels = @{
        DisplayName  = Find-ConfigControl 'reqDisplayName'
        TenantId     = Find-ConfigControl 'reqTenantId'
        ClientId     = Find-ConfigControl 'reqClientId'
        ClientSecret = Find-ConfigControl 'reqClientSecret'
        CertThumb    = Find-ConfigControl 'reqCertThumb'
        JsonPath     = Find-ConfigControl 'reqJsonPath'
    }

    # Unsaved changes tracking: a new window starts clean.
    $script:hasUnsavedChanges = $false

    Update-ConfigDropdowns

    $AppState.cfgTenantSnapshot = Get-TenantSnapshot
    $AppState.cfgSecretEdited   = $false
    $AppState.cfgFormEdited     = $false   # user typed/changed something in the form of the selected tenant

    # Reset-TenantFormState runs just before ShowDialog, after the dropdown's
    # SelectionChanged handler (which fills the form) is wired.

    # ── Event wiring ──────────────────────────────────────────────────────────
    $UI.cfgTenantAuthMethod.Add_SelectionChanged({
        Update-TenantAuthFields
        Update-ConfigSaveButton
        # New tenant (empty form): only choosing a method is not a change yet;
        # Save becomes active once something is typed. For an existing tenant
        # a different method is a change.
        if (-not $AppState.suppressEvents -and $AppState.editingTenantKey) { $AppState.cfgFormEdited = $true; Set-UnsavedChanges }
    })

    $UI.btnBrowseTenantPath.Add_Click({
        $p = Show-FolderBrowser -InitialPath $UI.cfgTenantPath.Text.Trim() -Owner $cfgWindow
        if ($p) { $UI.cfgTenantPath.Text = $p; Set-UnsavedChanges }
    })

    $reqFieldMap = @{
        DisplayName  = @($UI.cfgTenantDisplayName)
        TenantId     = @($UI.cfgTenantTenantId)
        ClientId     = @($UI.cfgTenantClientId)
        ClientSecret = @($UI.cfgTenantClientSecret, $UI.cfgTenantClientSecretShown)
        CertThumb    = @($UI.cfgTenantCertThumbprint)
        JsonPath     = @($UI.cfgTenantPath)
    }
    foreach ($reqName in $reqFieldMap.Keys) {
        $lbl = $AppState.requiredLabels[$reqName]
        if (-not $lbl) { continue }
        $name = $reqName
        # GetNewClosure only captures locals and loses the module scope:
        # $AppState must be a local here to be visible inside $update, and
        # Test-TenantFieldRequired is found because it is exported.
        $AppState = $AppState
        $update = {
            param([string]$Value)
            if ($Value -and $Value.Trim()) {
                if ($lbl.Visibility -eq 'Visible') { $lbl.Visibility = 'Collapsed' }
            } elseif (-not $AppState.suppressEvents -and (Test-TenantFieldRequired $name)) {
                # Emptied by the user (not by loading / clearing the form).
                $lbl.Text = 'Required!'; $lbl.Visibility = 'Visible'
            }
        }.GetNewClosure()
        foreach ($fld in $reqFieldMap[$reqName]) {
            if (-not $fld) { continue }
            if ($fld -is [System.Windows.Controls.PasswordBox]) {
                $fld.Add_PasswordChanged({ param($s, $e) & $update $s.Password }.GetNewClosure())
            } else {
                $fld.Add_TextChanged({ param($s, $e) if ($s.IsVisible) { & $update $s.Text } }.GetNewClosure())
            }
        }
    }

    foreach ($ctrl in @(
        $UI.cfgTenantDisplayName, $UI.cfgTenantTenantId,
        $UI.cfgTenantClientId, $UI.cfgTenantPath,
        $UI.cfgTenantCertThumbprint
    )) { if ($ctrl) { $ctrl.Add_TextChanged({ if (-not $AppState.suppressEvents) { $AppState.cfgFormEdited = $true; Set-UnsavedChanges } }) } }

    # Secret: PasswordChanged on the PasswordBox, TextChanged on the reveal
    # TextBox. Either marks unsaved and mirrors the edit to the other control,
    # so revealing / hiding keeps what was typed.
    if ($UI.cfgTenantClientSecret) {
        $UI.cfgTenantClientSecret.Add_PasswordChanged({
            if ($AppState.suppressEvents) { return }
            if ($UI.cfgTenantClientSecretShown) {
                $AppState.suppressEvents = $true
                try { $UI.cfgTenantClientSecretShown.Text = $UI.cfgTenantClientSecret.Password }
                finally { $AppState.suppressEvents = $false }
            }
            $AppState.cfgSecretEdited = $true
            $AppState.cfgFormEdited   = $true
            Set-UnsavedChanges
        })
    }
    if ($UI.cfgTenantClientSecretShown) {
        $UI.cfgTenantClientSecretShown.Add_TextChanged({
            if ($AppState.suppressEvents) { return }
            if ($UI.cfgTenantClientSecret) {
                $AppState.suppressEvents = $true
                try { $UI.cfgTenantClientSecret.Password = $UI.cfgTenantClientSecretShown.Text }
                finally { $AppState.suppressEvents = $false }
            }
            $AppState.cfgSecretEdited = $true
            $AppState.cfgFormEdited   = $true
            Set-UnsavedChanges
        })
    }

    $emptyFormCheck = {
        if ($AppState.suppressEvents) { return }
        if ($AppState.editingTenantKey -or $UI.lstTenants.SelectedItem) { return }   # existing tenant
        if (Test-NewTenantFormEmpty) {
            Clear-RequiredLabels
            if (Test-TenantStoreChanged) { Set-UnsavedChanges } else { Clear-UnsavedChanges }
        }
    }
    # Clear (x) buttons in Display Name, Tenant ID, Client ID and Certificate
    # Thumbprint: visible while the field has text; a click empties the field
    # (the usual handlers then mark Required / update Save) and focuses it.
    foreach ($pair in @(@('cfgTenantDisplayName', 'btnClearDisplayName'),
                        @('cfgTenantTenantId',    'btnClearTenantId'),
                        @('cfgTenantClientId',    'btnClearClientId'),
                        @('cfgTenantCertThumbprint', 'btnClearCertThumb'))) {
        $tb  = Find-ConfigControl $pair[0]
        $btn = Find-ConfigControl $pair[1]
        if (-not $tb -or -not $btn) { continue }
        $tb.Add_TextChanged({ $btn.Visibility = if ($tb.Text) { 'Visible' } else { 'Collapsed' } }.GetNewClosure())
        $btn.Add_Click({ $tb.Text = ''; $tb.Focus() | Out-Null }.GetNewClosure())
    }

    # (Display Name: registered after its own handler further down.)
    foreach ($fld in @($UI.cfgTenantTenantId, $UI.cfgTenantClientId,
                       $UI.cfgTenantClientSecretShown, $UI.cfgTenantCertThumbprint, $UI.cfgTenantPath)) {
        if ($fld) { $fld.Add_TextChanged($emptyFormCheck) }
    }
    if ($UI.cfgTenantClientSecret) { $UI.cfgTenantClientSecret.Add_PasswordChanged($emptyFormCheck) }
    # JSON folder path: Save follows the unsaved-changes state. Registered
    # last, so it runs after Set-UnsavedChanges / the empty-form check.
    if ($UI.cfgTenantPath) { $UI.cfgTenantPath.Add_TextChanged({ Update-ConfigSaveButton }) }

    # Reveal toggle: swap the masked PasswordBox and the plain TextBox, and
    # the eye icons (SVG paths iconEyeOpen / iconEyeOff in BasetuneConfig.xaml).
    if ($UI.btnRevealSecret) {
        $UI.btnRevealSecret.Add_Click({
            if (-not $UI.cfgTenantClientSecret -or -not $UI.cfgTenantClientSecretShown) { return }
            $isShown = $UI.cfgTenantClientSecretShown.Visibility -eq 'Visible'
            if ($isShown) {
                # Hide: copy back to PasswordBox, show masked
                $AppState.suppressEvents = $true
                try {
                    $UI.cfgTenantClientSecret.Password = $UI.cfgTenantClientSecretShown.Text
                } finally { $AppState.suppressEvents = $false }
                $UI.cfgTenantClientSecretShown.Visibility = 'Collapsed'
                $UI.cfgTenantClientSecret.Visibility      = 'Visible'
                if ($UI.iconEyeOpen) { $UI.iconEyeOpen.Visibility = 'Visible' }
                if ($UI.iconEyeOff)  { $UI.iconEyeOff.Visibility  = 'Collapsed' }
            } else {
                # Show: copy from PasswordBox, show plain TextBox
                $AppState.suppressEvents = $true
                try {
                    $UI.cfgTenantClientSecretShown.Text = $UI.cfgTenantClientSecret.Password
                } finally { $AppState.suppressEvents = $false }
                $UI.cfgTenantClientSecret.Visibility      = 'Collapsed'
                $UI.cfgTenantClientSecretShown.Visibility = 'Visible'
                if ($UI.iconEyeOpen) { $UI.iconEyeOpen.Visibility = 'Collapsed' }
                if ($UI.iconEyeOff)  { $UI.iconEyeOff.Visibility  = 'Visible' }
            }
        })
    }

    $UI.cfgTenantDisplayName.Add_TextChanged({
        if (-not $AppState.suppressEvents) { $AppState.cfgFormEdited = $true; Set-UnsavedChanges }
        $txt = $UI.cfgTenantDisplayName.Text
        if ($txt -match '[\\/:*?"<>|]') {
            $UI.cfgTenantDisplayName.BorderBrush = [System.Windows.Media.Brushes]::Red
            $UI.cfgTenantDisplayName.ToolTip     = 'Invalid characters: \ / : * ? " < > |'
        } else {
            # Back to the theme border (light or dark) instead of a fixed colour.
            $UI.cfgTenantDisplayName.ClearValue([System.Windows.Controls.Control]::BorderBrushProperty)
            $UI.cfgTenantDisplayName.ToolTip = $null
        }
    })
    # After the handler above (which enables Save), so an emptied new form
    # still turns Save off again.
    $UI.cfgTenantDisplayName.Add_TextChanged($emptyFormCheck)

    $UI.lstTenants.Add_SelectionChanged({
        if ($AppState.suppressEvents) { return }
        $sel = $UI.lstTenants.SelectedItem
        if (-not $sel) { return }
        $AppState.cfgSecretEdited = $false
        $AppState.cfgFormEdited   = $false
        $key = $sel.Tag
        $node = $AppState.tenantStore[$key]
        if (-not $node) { return }
        $AppState.suppressEvents = $true
        $AppState.editingTenantKey       = $key
        $UI.cfgTenantDisplayName.Text    = if ($node.displayName)    { $node.displayName    } else { '' }
        $UI.cfgTenantTenantId.Text = if ($node.tenantId) { $node.tenantId } else { '' }
        $UI.cfgTenantClientId.Text = if ($node.clientId) { $node.clientId } else { '' }
        # Hashtable (ordered) or PSCustomObject node: Get-NodeValue ($null -> '')
        $UI.cfgTenantPath.Text = [string](Get-NodeValue $node 'path')
        $UI.cfgTenantAuthMethod.SelectedIndex = switch ($node.authMethod) {
            'Certificate' { 1 }; 'None' { 2 }; default { 0 }
        }
        Update-TenantAuthFields
        if ($node.authMethod -eq 'Certificate') {
            $UI.cfgTenantCertThumbprint.Text = [string](Get-NodeValue $node 'certThumbprint')
        } else {
            # Fill both secret controls. The store holds the secret encrypted;
            # it is decrypted only here, for the selected tenant, into the
            # form. Not decryptable (other Windows user or PC): the field
            # stays empty so a new secret can be entered.
            $storedSecret = [string](Get-NodeValue $node 'clientSecret')
            $secretValue = ''
            if ($storedSecret) {
                $secretValue = Unprotect-Secret ([string]$storedSecret)
                if ($null -eq $secretValue) {
                    $secretValue = ''
                    $lblName = if ($node.displayName) { $node.displayName } else { $key }
                    Write-Log 'Config' "Could not decrypt the client secret for '$lblName' (encrypted by another Windows user or on another PC). Enter the secret again" 'ERROR'
                }
            }
            if ($UI.cfgTenantClientSecret)      { $UI.cfgTenantClientSecret.Password = $secretValue }
            if ($UI.cfgTenantClientSecretShown) { $UI.cfgTenantClientSecretShown.Text = $secretValue }
            # Another tenant always starts masked.
            if ($UI.cfgTenantClientSecret)      { $UI.cfgTenantClientSecret.Visibility      = 'Visible' }
            if ($UI.cfgTenantClientSecretShown) { $UI.cfgTenantClientSecretShown.Visibility = 'Collapsed' }
            if ($UI.iconEyeOpen)                { $UI.iconEyeOpen.Visibility = 'Visible' }
            if ($UI.iconEyeOff)                 { $UI.iconEyeOff.Visibility  = 'Collapsed' }
        }
        $AppState.suppressEvents = $false
        Show-TenantForm
        # The connection test result belongs to the save that just happened;
        # picking another tenant clears it (not while that save reselects).
        if (-not $AppState.cfgSavingNow -and $UI.lblConnectionStatus) { $UI.lblConnectionStatus.Text = '' }
        # Unsaved input for another (or a new) tenant is discarded by
        # switching: Save only stays active for still pending changes.
        if (Test-TenantStoreChanged) { Set-UnsavedChanges } else { Clear-UnsavedChanges }
    })

    $UI.btnAddTenant.Add_Click({
        Start-AddTenant; $AppState.cfgSecretEdited = $false; $AppState.cfgFormEdited = $false; Update-TenantListHint
        if ($UI.lblConnectionStatus) { $UI.lblConnectionStatus.Text = '' }
        if (Test-TenantStoreChanged) { Set-UnsavedChanges } else { Clear-UnsavedChanges }
    })

    $UI.btnRemoveTenant.Add_Click({
        $sel = $UI.lstTenants.SelectedItem
        if (-not $sel) { return }
        $key = $sel.Tag
        $AppState.tenantStore.Remove($key)
        if ($AppState.editingTenantKey -eq $key) { $AppState.editingTenantKey = $null }
        Update-ConfigDropdowns
        Reset-TenantFormState
        Set-UnsavedChanges
    })

    $UI.btnSaveConfig.Add_Click({
        # Existing tenant whose secret was typed: counts as updated (see Get-TenantSnapshot).
        $secretChangedKey = if ($AppState.cfgSecretEdited -and $AppState.editingTenantKey) { $AppState.editingTenantKey } else { $null }
        $formEditedNow    = [bool]$AppState.cfgFormEdited
        if (-not (Save-TenantForm)) { return }

        # A save starts with an empty log view, like the four main actions:
        # only this save's lines follow. The log file keeps the rest.
        Clear-UILog

        # ── Connection test (sync) ──────────────────────────────────────────
        # Runs before Save-Config, on the tenant just committed to
        # $AppState.tenantStore (secret encrypted; New-GraphConnection
        # decrypts it just-in-time). Sync, not a runspace: the dialog is modal
        # and blocking it for the 2-5 s token request is intended.
        # A failed test still saves (offline, or fix it later); the log and
        # the label say the credentials did not verify.
        $testKey  = $AppState.editingTenantKey
        $testNode = if ($testKey) { $AppState.tenantStore[$testKey] } else { $null }
        $shouldTest = ($testNode -and $testNode.authMethod -ne 'None' -and $testNode.authMethod)
        # Only test what this Save adds or changes: a new tenant, or an
        # existing one that was edited in the form (also when the same value
        # is pasted again, e.g. to retry a failing connection). A tenant that
        # is just selected (e.g. while saving removals) is not tested again.
        if ($shouldTest) {
            $isNewTenant = -not ($AppState.cfgTenantSnapshot -and $AppState.cfgTenantSnapshot.ContainsKey($testKey))
            $isChanged   = $false
            if (-not $isNewTenant) {
                $nowSnap   = Get-TenantSnapshot
                $isChanged = ($nowSnap[$testKey].Sig -ne $AppState.cfgTenantSnapshot[$testKey].Sig) -or ($testKey -eq $secretChangedKey) -or $formEditedNow
            }
            $shouldTest = $isNewTenant -or $isChanged
        }
        $testPassed = $true   # Default true so offline-only tenants don't trigger a failure UI

        if ($shouldTest) {
            $tenantLabel = if ($testNode.displayName) { $testNode.displayName } else { $testKey }
            Write-Log 'Config' $(if ($isNewTenant) { "Testing connection for new tenant '$tenantLabel'..." }
                                 else              { "Testing connection for tenant '$tenantLabel'..." }) 'INFO'
            if ($UI.lblConnectionStatus) {
                $UI.lblConnectionStatus.Foreground = [System.Windows.Media.Brushes]::Gray
                $UI.lblConnectionStatus.Text       = "Testing connection..."
                # Paint the label now: the token call blocks the UI thread,
                # so it would otherwise only show after the test.
                $UI.lblConnectionStatus.Dispatcher.Invoke(
                    [System.Windows.Threading.DispatcherPriority]::Render,
                    [System.Action]{}
                )
            }
            # No buttons disabled: the sync call blocks the UI thread, so
            # clicks only run after this handler returns.
            $conn = $null
            try { $conn = New-GraphConnection -Config $testNode -Label 'Config' }
            catch { Write-Log 'Config' "Details: $($_.Exception.Message)" 'WARN' -FileOnly }

            $testPassed = ($null -ne $conn)

            if ($UI.lblConnectionStatus) {
                if ($testPassed) {
                    $UI.lblConnectionStatus.Foreground = [System.Windows.Media.Brushes]::Green
                    $UI.lblConnectionStatus.Text       = "Connection successful"
                } else {
                    $UI.lblConnectionStatus.Foreground = [System.Windows.Media.Brushes]::Red
                    $UI.lblConnectionStatus.Text       = "Connection failed. Saving anyway..."
                }
            }
            if ($testPassed) {
                Write-Log 'Config' "Connection verified for '$tenantLabel'"
            } else {
                Write-Log 'Config' "Could not connect to '$tenantLabel'. Saving anyway. See the log file for details" 'WARN'
            }
        } else {
            # Nothing tested: clear the status of a previous save.
            if ($UI.lblConnectionStatus) { $UI.lblConnectionStatus.Text = '' }
        }

        try {
            Save-Config

            # What this Save changed, compared with the previous save.
            $before = $AppState.cfgTenantSnapshot
            $after  = Get-TenantSnapshot
            foreach ($k in $after.Keys) {
                if (-not $before.ContainsKey($k)) {
                    $authShown = if ($after[$k].Auth -eq 'None') { 'None (JSON)' } else { $after[$k].Auth }
                    Write-Log 'Config' "Created tenant '$($after[$k].Name)' with authentication method '$authShown'"
                }
            }
            foreach ($k in $before.Keys) {
                if (-not $after.ContainsKey($k)) { Write-Log 'Config' "Removed tenant '$($before[$k].Name)'" }
            }
            foreach ($k in $after.Keys) {
                if ($before.ContainsKey($k) -and ($before[$k].Sig -ne $after[$k].Sig -or $k -eq $secretChangedKey)) {
                    Write-Log 'Config' "Updated tenant '$($after[$k].Name)'"
                }
            }
            $AppState.cfgTenantSnapshot = $after
            $AppState.cfgSecretEdited   = $false
            $AppState.cfgFormEdited     = $false

            $savedKey   = $AppState.editingTenantKey
            $prevSrcTag = if ($UI.cmbSourceTenant.SelectedItem) { $UI.cmbSourceTenant.SelectedItem.Tag } else { '' }
            $prevTgtTag = if ($UI.cmbTargetTenant.SelectedItem) { $UI.cmbTargetTenant.SelectedItem.Tag } else { '' }
            $AppState.suppressEvents = $true
            Import-Config
            Sync-MainTenantDropdowns -PreferSrcTag $prevSrcTag -PreferTgtTag $prevTgtTag
            $AppState.suppressEvents = $false
            $AppState.lastSourceTenantKey = if ($UI.cmbSourceTenant.SelectedItem) { $UI.cmbSourceTenant.SelectedItem.Tag } else { $null }
            $AppState.lastTargetTenantKey = if ($UI.cmbTargetTenant.SelectedItem) { $UI.cmbTargetTenant.SelectedItem.Tag } else { $null }
            Reset-ChangedSides -PrevSrcTag $prevSrcTag -PrevTgtTag $prevTgtTag
            Update-ExportButtons
            Update-EmptyState 'Source'; Update-EmptyState 'Target'
            # The last tenant was removed: the log lines above (load, sign-in
            # errors) belong to tenants that are gone. Start clean with the
            # same line as a first start (the log file keeps everything).
            if ($before.Count -gt 0 -and $after.Count -eq 0) {
                Clear-UILog 'Config' 'Click the gear icon to configure a tenant and get started'
            }
            Clear-UnsavedChanges
            # After a save: the saved tenant stays selected (the connection
            # test result stays visible).
            $AppState.cfgSavingNow = $true
            try { Reset-TenantFormState -SelectKey $savedKey } finally { $AppState.cfgSavingNow = $false }
        } catch {
            # Report it: Config.json may not be written (e.g. locked by sync),
            # and the user must not think it was saved.
            $AppState.suppressEvents = $false
            $UI.btnSaveConfig.IsEnabled = $true
            if ($AppState.configLoadError) {
                # Invalid Config.json: log only, no popup.
                Write-Log 'Config' "$($_.Exception.Message) Tenant configuration not saved" 'ERROR'
            } else {
                Write-Log 'Config' 'Could not save Config.json. See the log file for details' 'ERROR'
                Write-Log 'Config' "Details: $($_.Exception.Message)" 'ERROR' -FileOnly
                [System.Windows.MessageBox]::Show("Saving the configuration failed:`n$($_.Exception.Message)", "Basetune", 'OK', 'Error') | Out-Null
            }
        }
    })

    $btnClose = Find-ConfigControl 'btnCloseConfig'
    if ($btnClose) { $btnClose.Add_Click({ $cfgWindow.Close() }) }

    $cfgWindow.Add_Closed({
        $prevSrcTag = if ($UI.cmbSourceTenant.SelectedItem) { $UI.cmbSourceTenant.SelectedItem.Tag } else { '' }
        $prevTgtTag = if ($UI.cmbTargetTenant.SelectedItem) { $UI.cmbTargetTenant.SelectedItem.Tag } else { '' }
        Import-Config -Quiet
        $AppState.suppressEvents = $true
        Sync-MainTenantDropdowns -PreferSrcTag $prevSrcTag -PreferTgtTag $prevTgtTag
        $AppState.suppressEvents = $false
        $AppState.lastSourceTenantKey = if ($UI.cmbSourceTenant.SelectedItem) { $UI.cmbSourceTenant.SelectedItem.Tag } else { $null }
        $AppState.lastTargetTenantKey = if ($UI.cmbTargetTenant.SelectedItem) { $UI.cmbTargetTenant.SelectedItem.Tag } else { $null }
        Reset-ChangedSides -PrevSrcTag $prevSrcTag -PrevTgtTag $prevTgtTag
        Update-ExportButtons
        Update-EmptyState 'Source'; Update-EmptyState 'Target'
    })

    $cfgWindow.Add_KeyDown({ param($s,$e); if ($e.Key -eq 'Escape') { $cfgWindow.Close() } })
    # Opens on: the tenant of the side used last (dropdown change or load,
    # Source or Target, see $AppState.lastPickedTenantSide), otherwise Source,
    # otherwise the first tenant; no tenants: empty form.
    $sideCmb = if ($AppState.lastPickedTenantSide -eq 'Target') { $UI.cmbTargetTenant } else { $UI.cmbSourceTenant }
    $openKey = if ($sideCmb -and $sideCmb.SelectedItem) { "$($sideCmb.SelectedItem.Tag)" }
               elseif ($UI.cmbSourceTenant -and $UI.cmbSourceTenant.SelectedItem) { "$($UI.cmbSourceTenant.SelectedItem.Tag)" }
               else { '' }
    Reset-TenantFormState -SelectKey $openKey
    $cfgWindow.ShowDialog() | Out-Null
}

# ═════════════════════════════════════════════════════════════════════════════
# INITIALISATION
# Opens Tenant Configuration from the main window. Called once from Basetune.ps1.
# ═════════════════════════════════════════════════════════════════════════════
function Initialize-ConfigWindowEvents {
    $UI.btnOpenConfig.Add_Click({ Open-ConfigWindow })

    # The empty-card text "Configure a tenant to get started" is a link: click opens Tenant Configuration.
    foreach ($nmLbl in @($UI.lblSourceNoMatch, $UI.lblTargetNoMatch)) {
        if ($nmLbl) {
            $nmLbl.Add_MouseLeftButtonUp({
                param($s, $e)
                if ($s.Text -eq 'Configure a tenant to get started' -and -not $AppState.CurrentJob) { Open-ConfigWindow }
            })
        }
    }
}

Export-ModuleMember -Function @(
    'Update-TenantListHint',
    'Set-UnsavedChanges',
    'Update-ConfigSaveButton',
    'Clear-UnsavedChanges',
    'Reset-ChangedSides',
    'Reset-TenantFormState',
    'Get-TenantSnapshot',
    'Test-TenantStoreChanged',
    'Test-TenantFieldRequired',
    'Test-NewTenantFormEmpty',
    'New-TenantKey',
    'Clear-RequiredLabels',
    'Save-TenantForm',
    'Show-TenantForm',
    'Update-TenantAuthFields',
    'Start-AddTenant',
    'Open-ConfigWindow',
    'Initialize-ConfigWindowEvents'
)
