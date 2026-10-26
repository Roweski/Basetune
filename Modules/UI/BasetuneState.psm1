# =============================================================================
# BasetuneState.psm1
# Shared UI context (controls + app state) for Basetune.ps1 and the UI
# modules (see the list in Basetune.ps1).
#
# A module cannot see the $script: variables of Basetune.ps1, so this
# module owns one context hashtable (no $global:, see CLAUDE.md). Every UI
# module takes a reference to it at import time
# (`$script:UI = (Get-BasetuneContext).UI`), Basetune.ps1 does the same at
# script scope: all share the SAME hashtable, so a control registered in one
# place is visible everywhere.
#
# Import before the other UI modules. Not used in runspaces (they get $Shared).
#
# Shape:
#   @{
#     UI = @{
#       Window     = <main Window>
#       btnCompare = <Button>       # every named control, by its x:Name
#       ...                         # config window controls are added each
#     }                             # time the config window opens
#     State = @{                    # read as $AppState.<name>
#       ScriptRoot, ModulesPath, definitionsPath, reportBasePath, ...
#       CurrentJob, Cache, cfg, tenantStore, editingTenantKey, ...
#     }                             # (initialised in Basetune.ps1)
#   }
# =============================================================================

$script:Context = @{
    UI    = @{}
    State = @{}
}

function Get-BasetuneContext { return $script:Context }

# Looks up each name under $Root (Find-InTree) and stores the element in the
# UI registry under that name. Re-registering a name (the config window is
# created anew each time it opens) replaces the element; a name that is not
# found is stored as $null.
function Register-BasetuneControls {
    param(
        [Parameter(Mandatory)]$Root,
        [Parameter(Mandatory)][string[]]$Names
    )
    $ui = $script:Context.UI
    foreach ($n in $Names) { $ui[$n] = Find-InTree -Root $Root -Name $n }
}

Export-ModuleMember -Function @(
    'Get-BasetuneContext',
    'Register-BasetuneControls'
)
