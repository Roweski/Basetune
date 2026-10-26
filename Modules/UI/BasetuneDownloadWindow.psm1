# =============================================================================
# BasetuneDownloadWindow.psm1
# Download definitions window (Show-TenantPickerDialog, BasetuneDownload.xaml):
# shows the definitions in use and lets the user pick an API tenant. The
# download runs in BasetuneActions.psm1 (Start-DefinitionDownload).
# $UI / $AppState come from BasetuneState.psm1.
# =============================================================================

$script:UI       = (Get-BasetuneContext).UI
$script:AppState = (Get-BasetuneContext).State

# ── Status of the definitions in use (download dialog) ──────────────────────
# Counts: from the in-memory cache only (Start-DefinitionPreload, refreshed by
# a download), so the dialog opens fast; "-" while it is empty.
# Last updated: date of the downloaded settings.json; "Never (using default)"
# with only the shipped .default file; "Missing" without any file.
function Get-DefinitionStatus {
    $inv    = [System.Globalization.CultureInfo]::InvariantCulture
    $status = [PSCustomObject]@{ Definitions = '-'; Categories = '-'; LastUpdated = 'Missing' }
    $path   = $AppState.definitionsPath
    if (-not $path) { return $status }
    $cache  = $AppState.Cache.Definitions

    $defs = Get-DefinitionFile -DefinitionsPath $path -Kind Definitions

    if ($cache.HasDefs -and $cache.Lookup)       { $status.Definitions = $cache.Lookup.Count.ToString('N0', $inv) }
    if ($cache.HasCats -and $cache.CategoryById) { $status.Categories  = $cache.CategoryById.Count.ToString('N0', $inv) }

    if ($defs.Exists -and -not $defs.IsDefault) {
        $status.LastUpdated = (Get-Item -LiteralPath $defs.Path).LastWriteTime.ToString('dd/MM/yyyy HH:mm', $inv)
    } elseif ($defs.Exists) {
        $status.LastUpdated = 'Never (using default)'
    }
    return $status
}

# ── Tenant picker dialog for download ────────────────────────────────────────
function Show-TenantPickerDialog {
    $onlineTenants = @($AppState.tenantList | Where-Object {
        (Get-TenantMode $_.Node) -eq 'Online'
    } | Sort-Object { $_.Label })

    $dlg = Import-Xaml -Path "$($AppState.XamlPath)\BasetuneDownload.xaml"
    $dlg.Owner = $UI.Window

    $cmb       = $dlg.FindName('cmbDownloadTenant')
    $cmbHint   = $dlg.FindName('cmbDownloadTenantHint')
    $btnOk     = $dlg.FindName('btnDownloadOk')
    $btnCancel = $dlg.FindName('btnDownloadCancel')

    # "Current" block: definitions in use
    try {
        $st = Get-DefinitionStatus
        $t  = $dlg.FindName('txtDlgDefCount');    if ($t) { $t.Text = $st.Definitions }
        $t  = $dlg.FindName('txtDlgCatCount');    if ($t) { $t.Text = $st.Categories }
        $t  = $dlg.FindName('txtDlgLastUpdated'); if ($t) { $t.Text = $st.LastUpdated }
    } catch {}

    if ($onlineTenants.Count -eq 0) {
        $cmb.IsEnabled   = $false
        $btnOk.IsEnabled = $false
        if ($cmbHint)      { $cmbHint.Text = 'No tenant with App Registration found' }
    } else {
        foreach ($t in $onlineTenants) {
            $item         = [System.Windows.Controls.ComboBoxItem]::new()
            $item.Content = $t.Label
            $item.Tag     = $t.Key
            $cmb.Items.Add($item) | Out-Null
        }
        # Nothing selected: placeholder "Select a tenant to download
        # definitions..." and Download disabled until a tenant is picked.
        $cmb.SelectedIndex = -1
        $btnOk.IsEnabled   = $false
        $cmb.Add_SelectionChanged({
            $picked = [bool]$cmb.SelectedItem
            $btnOk.IsEnabled = $picked
            if ($cmbHint) { $cmbHint.Visibility = if ($picked) { 'Collapsed' } else { 'Visible' } }
        })
    }

    $script:dlgPickedKey = $null
    $btnOk.Add_Click({
        if (-not $cmb.SelectedItem) { return }
        $script:dlgPickedKey = $cmb.SelectedItem.Tag; $dlg.DialogResult = $true
    })
    $btnCancel.Content = 'Close'
    $btnCancel.Add_Click({ $dlg.DialogResult = $false })
    $dlg.Add_KeyDown({ param($s,$e); if ($e.Key -eq 'Escape') { $dlg.DialogResult = $false } })
    $dlg.ShowDialog() | Out-Null
    return $script:dlgPickedKey
}

Export-ModuleMember -Function @(
    'Get-DefinitionStatus',
    'Show-TenantPickerDialog'
)
