# =============================================================================
# IntuneGraphModules.psd1
# Module manifest — loads all sub-modules in dependency order.
#
# BasetuneHelpers.psm1 is loaded FIRST so the logging functions (Write-Log,
# Set-LogCallback, Set-LogFile) and the shared tenant classifier
# (Get-TenantMode) are available to every subsequent module via the manifest's
# shared module scope.
#
# BasetuneConfig and BasetuneUI are NOT listed here — they depend on WPF
# globals and are imported separately by BasetuneUI.ps1.
# =============================================================================
@{
    ModuleVersion = '1.0.0'

    NestedModules = @(
        'BasetuneHelpers.psm1',
        'GraphtokenClient.psm1',
        'IntuneGraphPolicies.psm1',
        'IntuneGraphCompare.psm1',
        'IntuneGraphReport.psm1',
        'IntuneGraphLoad.psm1',
        'IntuneGraphExport.psm1'
    )

    # Wildcard pulls in every Export-ModuleMember declaration from the nested
    # modules above — new functions surface automatically when added.
    FunctionsToExport = '*'
}
