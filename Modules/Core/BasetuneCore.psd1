# =============================================================================
# BasetuneCore.psd1
# Module manifest: loads all sub-modules in dependency order.
#
# BasetuneHelpers.psm1 first, so every later module can use its helpers:
#   - logging: Write-Log, Set-LogCallback, Set-LogFile (CMTrace format,
#     log split at startup), ConvertTo-CMTraceLine
#   - tenant classifier: Get-TenantMode
#   - secrets (DPAPI): Protect-Secret, Unprotect-Secret, Test-SecretEncrypted
#   - validation: Max threads (Get-ValidMaxThreads, ...) and folder paths
#     (Resolve-FolderPath)
#   - Get-NodeValue (safe property read on tenant nodes)
#
# Then: BasetuneConfig (Config.json / Options.json), BasetuneGraph
# (tokens + Graph requests), BasetuneDefinitions (settings.json /
# categories.json) and the pipeline modules (Policies, Compare, Report, Load,
# Export).
#
# Modules\Core is engine: no WPF, used by the CLI, the UI and its runspaces
# (which import only this manifest). The UI modules (WPF, shared UI context)
# are imported separately by BasetuneUI.ps1.
# =============================================================================
@{
    # The Basetune version, the one place to change it for a release (UI
    # title, CLI -Help, log file, report footer; Get-BasetuneVersion).
    ModuleVersion = '3.0.0'

    NestedModules = @(
        'BasetuneHelpers.psm1',
        'BasetuneConfig.psm1',
        'BasetuneGraph.psm1',
        'BasetuneDefinitions.psm1',
        'BasetunePolicies.psm1',
        'BasetuneCompare.psm1',
        'BasetuneReport.psm1',
        'BasetuneLoad.psm1',
        'BasetuneExport.psm1'
    )

    # Every Export-ModuleMember function of the nested modules.
    FunctionsToExport = '*'
}
