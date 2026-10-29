# =============================================================================
# BasetuneCLI.psm1
# Functions only the CLI (BasetuneCLI.ps1) uses. Imported by BasetuneCLI.ps1
# after Modules\Core\BasetuneCore.psd1; the UI never loads it, so the UI works
# without the Modules\CLI folder.
#
# Strict mode: a hand-edited Config.json with a missing property must not
# slip through unnoticed.
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────────────────────
# Resolve-TenantConfig
#
# Source and target tenant nodes by SourceId / TargetId (-Source /
# -Target of the CLI; the UI picks tenants in its lists). No default; an
# unknown or invalid entry gives $null.
# ─────────────────────────────────────────────────────────────────────────────
function Resolve-TenantConfig {
    param(
        [Parameter(Mandatory)]$Cfg,
        [string]$SourceId = "",
        [string]$TargetId = ""
    )

    $srcKey = if ($SourceId) { $SourceId } else { $null }
    $tgtKey = if ($TargetId) { $TargetId } else { $null }

    # Safe lookup: strict mode throws on a missing property
    $srcNode = $null
    $tgtNode = $null
    if ($srcKey -and $Cfg.tenant) {
        $prop = $Cfg.tenant.PSObject.Properties[$srcKey]
        if ($prop) { $srcNode = $prop.Value }
    }
    if ($tgtKey -and $Cfg.tenant) {
        $prop = $Cfg.tenant.PSObject.Properties[$tgtKey]
        if ($prop) { $tgtNode = $prop.Value }
    }

    if ($srcNode -and $srcNode.PSObject.Properties['__invalid'] -and $srcNode.__invalid) { $srcNode = $null }
    if ($tgtNode -and $tgtNode.PSObject.Properties['__invalid'] -and $tgtNode.__invalid) { $tgtNode = $null }

    return [PSCustomObject]@{
        source = $srcNode
        target = $tgtNode
        tenant = $Cfg.tenant
    }
}

Export-ModuleMember -Function @(
    'Resolve-TenantConfig'
)
