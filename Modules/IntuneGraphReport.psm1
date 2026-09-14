# ─────────────────────────────────────────────────────────────────────────────
# IntuneGraphReport.psm1
#
# Report generation functions extracted from IntuneGraphCompare.psm1.
#
#   Get-BaselineSummary  — per-policy compliance summary
#   Get-OverlapSummary   — duplicate / conflict overlap rows
#   Get-HtmlReport       — HTML report from resolved diff rows
# ─────────────────────────────────────────────────────────────────────────────

# Write-Log komt normaal van de host. Deze terugval zorgt dat de module ook
# los importeerbaar is; binnen Basetune wint de echte Write-Log met
# bestandslogging, want die bestaat dan al.
if (-not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    function global:Write-Log {
        param([string]$Label, [string]$Message, [string]$Level = 'INFO')
        $color = switch ($Level) {
            'ERROR' { 'Red' }    'WARN' { 'Yellow' }
            'OK'    { 'Green' }  default { 'Gray' }
        }
        Write-Host "[$Level][$Label] $Message" -ForegroundColor $color
    }
}

function Get-BaselineSummary {
    param(
        [Parameter(Mandatory)]
        [array]$Rows
    )

    $sourceRows = $Rows | Where-Object { $_.SourcePolicyName }

    $byPolicy = $sourceRows | Group-Object -Property SourcePolicyName

    $summary = foreach ($pg in $byPolicy) {

        $byDef   = $pg.Group | Group-Object -Property Setting
        $total   = 0
        $match   = 0
        $missing = 0
        $diff    = 0

        foreach ($dg in $byDef) {
            $total++
            $issue  = ($dg.Group | Select-Object -First 1).Issue
            $status = ($dg.Group | Select-Object -First 1).Status

            if ($issue -eq 'Conflict') {
                $diff++
            } else {
                switch ($status) {
                    'Match'   { $match++   }
                    'Missing' { $missing++ }
                    default   { $diff++    }
                }
            }
        }

        $compliance = if ($total -gt 0) { [math]::Round(($match / $total) * 100, 2) } else { 0 }

        [PSCustomObject]@{
            Policy           = $pg.Name
            Total            = $total
            Match            = $match
            Missing          = $missing
            Diff             = $diff
            'Compliance (%)' = $compliance
        }
    }

    return $summary | Sort-Object Policy
}


# ─────────────────────────────────────────────────────────────────────────────
# GET OVERLAP SUMMARY
#
# Returns one aggregated row per setting with Issue=Conflict or Issue=Duplicate,
# including all involved target policies and values.
#
# Output columns:
#   SourcePolicyName  — name of the baseline policy
#   Setting           — human-readable setting name
#   Issue             — Conflict or Duplicate
#   TargetPolicies    — comma-separated list of target policy names
#   TargetValues      — comma-separated list of target values (same order)
#
# Input  : array of resolved diff rows
# Output : array of aggregated overlap rows, sorted by SourcePolicyName, Setting
# ─────────────────────────────────────────────────────────────────────────────
function Get-OverlapSummary {
    param(
        [Parameter(Mandatory)]
        [array]$Rows
    )

    $overlapRows = $Rows | Where-Object { $_.Issue -eq 'Conflict' -or $_.Issue -eq 'Duplicate' }

    $grouped = $overlapRows | Group-Object -Property SourcePolicyName, Setting

    $output = foreach ($g in $grouped) {
        $first   = $g.Group | Select-Object -First 1
        $sorted  = $g.Group | Sort-Object -Property TargetPolicyName -Unique
        $policies = ($sorted | ForEach-Object { $_.TargetPolicyName }) -join ", "
        $values   = ($sorted | ForEach-Object { $_.TargetValue      }) -join ", "

        [PSCustomObject]@{
            SourcePolicyName = $first.SourcePolicyName
            Setting          = $first.Setting
            Issue            = $first.Issue
            TargetPolicies   = $policies
            TargetValues     = $values
        }
    }

    return $output | Sort-Object Setting, SourcePolicyName
}


# ─────────────────────────────────────────────────────────────────────────────
# GET HTML REPORT
#
# Accepts resolved diff rows ($Rows) and generates an HTML report with one
# row per unique setting.
#
# Columns:
#   SourcePolicyName — baseline policy name
#   Setting          — human-readable setting name
#   SourceValue      — value in the baseline
#   Status           — Match / Diff / Missing  (aggregated across N target rows)
#   Issue            — None / Duplicate / Conflict
#
# Status aggregation per DefinitionId:
#   Issue = None      → take Status from the single row
#   Issue = Duplicate → all rows share the same Status, take the first
#   Issue = Conflict  → always "Diff" (target values differ from each other)
#
# Input  : array of resolved diff rows (as produced by Invoke-BaselineCompare)
# Output : HTML file written to OutputPath
# ─────────────────────────────────────────────────────────────────────────────
function Get-HtmlReport {
    param(
        [Parameter(Mandatory)]
        [array]$Rows,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [string]$SourceLabel = "",
        [string]$TargetLabel = ""
    )

    # Only process source rows
    $sourceRows = $Rows | Where-Object { $_.SourcePolicyName }

    # One row per unique SourcePolicyName + Setting + SourceValue combination
    $grouped = $sourceRows | Group-Object -Property SourcePolicyName, Setting, SourceValue

    $settings = foreach ($g in $grouped) {
        $first  = $g.Group | Select-Object -First 1
        $issue  = $first.Issue

        # Do not trust the first row for the aggregated status. One group can
        # hold several target policies, and Group-Object does not order them:
        # with two policies matching and one differing, whichever landed first
        # decided the badge. Any differing target makes the whole group a Diff.
        $status = if ($issue -eq 'Conflict') {
            'Diff'
        } elseif (@($g.Group | Where-Object { $_.Status -eq 'Diff' }).Count -gt 0) {
            'Diff'
        } else {
            $first.Status
        }

        # Build unique target policy + value pairs for detail expand
        $targets = @($g.Group | Where-Object { $_.TargetPolicyName } |
            Sort-Object TargetPolicyName -Unique |
            ForEach-Object {
                [ordered]@{ name = $_.TargetPolicyName; value = $_.TargetValue }
            })

        [PSCustomObject]@{
            SourcePolicyName = $first.SourcePolicyName
            Setting          = $first.Setting
            SourceValue      = $first.SourceValue
            Status           = $status
            Issue            = $issue
            TargetCount      = $targets.Count
            Targets          = $targets
        }
    }

    $settings = $settings | Sort-Object SourcePolicyName, Setting, SourceValue

    # ── Build JSON data array for JS ─────────────────────────────────────────
    $jsonRows = foreach ($s in $settings) {
        $obj = [ordered]@{
            policy   = $s.SourcePolicyName
            setting  = $s.Setting
            value    = $s.SourceValue
            status   = $s.Status
            issue    = $s.Issue
            tcount   = $s.TargetCount
            targets  = $s.Targets
        }
        $obj | ConvertTo-Json -Compress -Depth 3
    }
    $jsonData = if ($jsonRows) { "[" + ($jsonRows -join ",") + "]" } else { "[]" }

    # ConvertTo-Json laat < > & ongemoeid, en deze JSON belandt letterlijk in een
    # <script>-blok. Elke settingnaam bevat al > als padscheiding ("Defender >
    # Attack Surface Reduction Rules > ..."), en waarden kunnen vrije tekst uit
    # de tenant bevatten. Komt daar ooit de reeks </script in voor, dan sluit de
    # browser het scriptblok af en is het rapport stuk. De \u-notatie is geldige
    # JSON en levert na het parsen exact dezelfde string op.
    # U+2028 en U+2029 zijn geldig in JSON maar niet in een JavaScript-literal.
    $jsonData = $jsonData.
        Replace('<', '\u003c').
        Replace('>', '\u003e').
        Replace('&', '\u0026').
        Replace([string][char]0x2028, '\u2028').
        Replace([string][char]0x2029, '\u2029')

    $totalSettings  = $settings.Count
    $countMatch     = @($settings | Where-Object { $_.Status -eq 'Match'   }).Count
    $countDiff      = @($settings | Where-Object { $_.Status -eq 'Diff'    }).Count
    $countMissing   = @($settings | Where-Object { $_.Status -eq 'Missing' }).Count
    $countDuplicate = @($settings | Where-Object { $_.Issue  -eq 'Duplicate' }).Count
    $countConflict  = @($settings | Where-Object { $_.Issue  -eq 'Conflict'  }).Count

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Basetune - Baseline Report</title>
<style>
    :root {
        --primary-blue: #1a6ef5;
        --primary-blue-hover: #1662d9;
        --primary-orange: #f0a340;
        --bg-body: #f0f4f8;
        --bg-card: white;
        --text-main: #1a1a1a;
        --text-sub: #666;
        --border-color: #eef1f6;
        --card-shadow: 0 4px 20px rgba(0,0,0,0.05);
        --status-match-bg: #16a34a;   --status-match-text: #ffffff;
        --status-diff-bg: #f0a340;    --status-diff-text: #ffffff;
        --status-missing-bg: #1a6ef5; --status-missing-text: #ffffff;
        --issue-conflict-bg: #dc2626; --issue-conflict-text: #ffffff;
        --issue-duplicate-bg: #9aa3ae;--issue-duplicate-text: #ffffff;
        --logo-bg: #e8f0fe;
    }
    body.dark-mode {
        --bg-body: #0f1115;
        --bg-card: #1a1d23;
        --text-main: #f0f2f5;
        --text-sub: #a0a6b1;
        --border-color: #2d323a;
        --card-shadow: 0 4px 25px rgba(0,0,0,0.3);
        --logo-bg: #23272e;
    }
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    /* Ruimte voor de scrollbalk vasthouden, ook als de pagina op het scherm
       past. Zonder dit verspringt de gecentreerde inhoud een halve
       scrollbalkbreedte zodra een filter weinig rijen overhoudt: bij Conflict
       verdwijnt de balk, het venster wordt breder en alles schuift naar rechts.
       scrollbar-gutter is de nette oplossing; de overflow-y: scroll erboven is
       de terugval voor browsers die dat nog niet kennen. */
    html { overflow-y: scroll; }
    @supports (scrollbar-gutter: stable) {
        html { overflow-y: auto; scrollbar-gutter: stable; }
    }
    body {
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
        background-color: var(--bg-body);
        color: var(--text-main);
        padding: 40px 20px;
        display: flex; flex-direction: column; align-items: center;
        transition: background-color 0.3s, color 0.3s;
    }
    .theme-toggle {
        position: fixed; top: 20px; right: 20px;
        background: var(--bg-card); border: 1px solid var(--border-color);
        padding: 10px; border-radius: 50%; cursor: pointer;
        box-shadow: var(--card-shadow); display: flex; align-items: center;
        transition: all 0.2s ease; z-index: 1000;
    }
    .theme-toggle svg { width: 20px; height: 20px; fill: var(--text-main); }
    .sun-icon { display: none; }
    .dark-mode .sun-icon { display: block; }
    .dark-mode .moon-icon { display: none; }
    .container { max-width: 1200px; width: 100%; }
    header { margin-bottom: 32px; padding-top: 8px; }
    h1 { font-size: 28px; font-weight: 600; margin: 10px 0 6px; letter-spacing: -0.8px; }
    .subtitle { font-size: 15px; color: var(--text-sub); margin-bottom: 28px; }
    .blue-text { color: var(--primary-blue); font-weight: 600; }

    .stats-grid { display: flex; gap: 12px; margin-bottom: 28px; flex-wrap: wrap; }
    .stat-card {
        background: var(--bg-card); border: 1px solid var(--border-color);
        border-radius: 12px; padding: 16px 20px; min-width: 100px;
        box-shadow: var(--card-shadow); cursor: pointer;
        transition: border-color 0.15s, box-shadow 0.15s;
    }
    .stat-card:hover { border-color: var(--primary-blue); box-shadow: 0 4px 20px rgba(26,110,245,0.12); }
    .stat-card.active { border-color: var(--primary-blue); box-shadow: 0 4px 20px rgba(26,110,245,0.18); }
    .stat-card .s-label {
        font-size: 11px; font-weight: 600; text-transform: uppercase;
        letter-spacing: 0.8px; color: var(--text-sub); margin-bottom: 6px;
    }
    .stat-card .s-value { font-size: 28px; font-weight: 700; letter-spacing: -1px; line-height: 1; }
    .stat-card.s-total   .s-value { color: var(--text-main); }
    .stat-card.s-match   .s-value { color: #16a34a; }
    .stat-card.s-diff    .s-value { color: #f0a340; }
    .stat-card.s-missing .s-value { color: var(--primary-blue); }
    .stat-card.s-dup     .s-value { color: #9aa3ae; }
    .stat-card.s-conflict .s-value { color: #dc2626; }

    .filters {
        display: flex; gap: 10px; margin-bottom: 16px; flex-wrap: wrap; align-items: center;
    }
    .filters input[type=text] {
        background: var(--bg-card); border: 1px solid var(--border-color);
        border-radius: 8px; color: var(--text-main);
        font-size: 13px; padding: 8px 14px; width: 260px; outline: none;
        transition: border-color 0.2s;
    }
    .filters input[type=text]:focus { border-color: var(--primary-blue); }
    .filters select {
        background: var(--bg-card); border: 1px solid var(--border-color);
        border-radius: 8px; color: var(--text-main);
        font-size: 13px; padding: 8px 14px; outline: none; cursor: pointer;
    }
    #filterPolicy { max-width: 260px; }
    .row-count { font-size: 12px; color: var(--text-sub); margin-bottom: 10px; }

    .content-card {
        background: var(--bg-card); border-radius: 16px;
        box-shadow: var(--card-shadow); border: 1px solid var(--border-color);
        overflow: hidden;
    }
    .table-wrapper { overflow-x: auto; }
    table { width: 100%; border-collapse: collapse; font-size: 13px; }
    th {
        text-align: left; padding: 14px 15px; color: var(--text-sub);
        background-color: var(--bg-card); border-bottom: 1px solid var(--border-color);
        font-weight: 600; text-transform: uppercase; letter-spacing: 0.8px;
        font-size: 11px; white-space: nowrap; cursor: pointer; user-select: none;
    }
    th:hover { color: var(--primary-blue); }
    th .sort-indicator { margin-left: 4px; opacity: 0.4; font-size: 10px; }
    th.sorted-asc .sort-indicator::after  { content: '▲'; opacity: 1; }
    th.sorted-desc .sort-indicator::after { content: '▼'; opacity: 1; }
    td { padding: 11px 15px; border-bottom: 1px solid var(--border-color); vertical-align: middle; }
    tr:last-child td { border-bottom: none; }
    tr:hover td { background-color: rgba(26,110,245,0.02); }

    .col-policy { color: var(--text-sub); font-size: 12px; white-space: nowrap; max-width: 220px; overflow: hidden; text-overflow: ellipsis; }
    .col-setting { max-width: 460px; }
    .col-value { color: var(--text-sub); font-size: 12px; max-width: 220px; word-break: break-word; white-space: normal; }

    /* Status + Issue columns: fixed width so badges never shift the layout */
    .col-status { width: 110px; white-space: nowrap; }
    .col-issue  { width: 130px; white-space: nowrap; }

    .badge {
        display: inline-block; padding: 3px 0; border-radius: 999px;
        font-size: 11px; font-weight: 600;
        width: 100px; text-align: center;
    }
    .val-match     { background: var(--status-match-bg);    color: var(--status-match-text); }
    .val-diff      { background: var(--status-diff-bg);     color: var(--status-diff-text); }
    .val-missing   { background: var(--status-missing-bg);  color: var(--status-missing-text); }
    .val-conflict  { background: var(--issue-conflict-bg);  color: var(--issue-conflict-text); }
    .val-duplicate { background: var(--issue-duplicate-bg); color: var(--issue-duplicate-text); }
    .none-text {
        display: inline-block; width: 100px; text-align: center;
        padding: 3px 0; border-radius: 6px;
        font-size: 11px; font-weight: 500; color: var(--text-sub);
        border: 1px dashed var(--border-color); opacity: 0.6;
    }

    tr.main-row { cursor: pointer; }
    tr.main-row:hover td { background-color: rgba(26,110,245,0.04); }
    tr.main-row.expanded td { background-color: rgba(26,110,245,0.04); border-bottom: none; }
    .expand-icon { display: inline-flex; align-items: center; margin-right: 7px; color: var(--text-sub); transition: transform 0.2s; line-height: 1; vertical-align: middle; }
    tr.main-row.expanded .expand-icon { transform: rotate(90deg); }

    tr.detail-row td {
        background-color: rgba(26,110,245,0.02);
        border-bottom: 1px solid var(--border-color);
        padding: 0;
    }
    tr.detail-row.hidden { display: none; }
    .detail-inner { padding: 10px 16px 14px 32px; }
    .detail-table { width: 100%; border-collapse: collapse; font-size: 12px; }
    .detail-table th {
        text-align: left; padding: 6px 10px; font-size: 10px;
        font-weight: 600; text-transform: uppercase; letter-spacing: 0.6px;
        color: var(--text-sub); border-bottom: 1px solid var(--border-color);
        background: transparent; cursor: default;
    }
    .detail-table th:hover { color: var(--text-sub); }
    .detail-table td { padding: 6px 10px; border-bottom: 1px solid var(--border-color); color: var(--text-sub); }
    .detail-table tr:last-child td { border-bottom: none; }
    .detail-empty { padding: 8px 0; color: var(--text-sub); font-size: 12px; font-style: italic; }

    .pagination {
        display: flex; align-items: center; gap: 6px;
        padding: 14px 16px; border-top: 1px solid var(--border-color);
        flex-wrap: wrap;
    }
    .pagination button {
        background: var(--bg-card); border: 1px solid var(--border-color);
        color: var(--text-main); border-radius: 6px; padding: 5px 11px;
        font-size: 12px; cursor: pointer; transition: all 0.15s;
    }
    .pagination button:hover:not(:disabled) { border-color: var(--primary-blue); color: var(--primary-blue); }
    .pagination button:disabled { opacity: 0.35; cursor: default; }
    .pagination button.active { background: var(--primary-blue); color: #fff; border-color: var(--primary-blue); }
    .pagination .page-info { font-size: 12px; color: var(--text-sub); margin-left: auto; }

    footer { text-align: center; color: var(--text-sub); font-size: 12px; padding: 40px 0; opacity: 0.7; }
</style>
</head>
<body>

<button class="theme-toggle" id="theme-toggle" aria-label="Toggle Dark Mode">
    <svg class="moon-icon" viewBox="0 0 20 20"><path d="M17.293 13.293A8 8 0 016.707 2.707a8.001 8.001 0 1010.586 10.586z"/></svg>
    <svg class="sun-icon" viewBox="0 0 20 20"><path d="M10 2a1 1 0 011 1v1a1 1 0 11-2 0V3a1 1 0 011-1zm4 8a4 4 0 11-8 0 4 4 0 018 0zm-.464 4.95l.707.707a1 1 0 001.414-1.414l-.707-.707a1 1 0 00-1.414 1.414zm2.12-10.607a1 1 0 010 1.414l-.706.707a1 1 0 11-1.414-1.414l.707-.707a1 1 0 011.415 0zM17 11a1 1 0 100-2h-1a1 1 0 100 2h1zm-7 4a1 1 0 011 1v1a1 1 0 11-2 0v-1a1 1 0 011-1zM5.05 6.464A1 1 0 106.465 5.05l-.708-.707a1 1 0 00-1.414 1.414l.707.707zm1.414 8.486l-.707.707a1 1 0 01-1.414-1.414l.707-.707a1 1 0 011.414 1.414zM4 11a1 1 0 100-2H3a1 1 0 000 2h1z" fill-rule="evenodd" clip-rule="evenodd"/></svg>
</button>

<div class="container">
    <header>
        <h1>Baseline <span class="blue-text">Comparison</span> Report</h1>
        $(if ($SourceLabel -or $TargetLabel) {
            $src = if ($SourceLabel) { $SourceLabel } else { 'Source' }
            $tgt = if ($TargetLabel) { $TargetLabel } else { 'Target' }
            "<p class=`"subtitle`"><span style=`"color:var(--blue)`">$src</span> &nbsp;&rarr;&nbsp; <span style=`"color:var(--blue)`">$tgt</span> &nbsp;&middot;&nbsp; Generated on $(Get-Date -Format 'yyyy-MM-dd HH:mm') &nbsp;&middot;&nbsp; $totalSettings settings</p>"
        } else {
            "<p class=`"subtitle`">Generated on $(Get-Date -Format 'yyyy-MM-dd HH:mm') &nbsp;&middot;&nbsp; $totalSettings settings</p>"
        })
    </header>

    <div class="stats-grid">
        <div class="stat-card s-total"   onclick="filterByCard('','')">        <div class="s-label">Total</div>     <div class="s-value">$totalSettings</div></div>
        <div class="stat-card s-match"   onclick="filterByCard('Match','')">   <div class="s-label">Match</div>     <div class="s-value">$countMatch</div></div>
        <div class="stat-card s-diff"    onclick="filterByCard('Diff','')">    <div class="s-label">Diff</div>      <div class="s-value">$countDiff</div></div>
        <div class="stat-card s-missing" onclick="filterByCard('Missing','')"> <div class="s-label">Missing</div>   <div class="s-value">$countMissing</div></div>
        <div class="stat-card s-dup"     onclick="filterByCard('','Duplicate')"><div class="s-label">Duplicate</div> <div class="s-value">$countDuplicate</div></div>
        <div class="stat-card s-conflict" onclick="filterByCard('','Conflict')"><div class="s-label">Conflict</div> <div class="s-value">$countConflict</div></div>
    </div>

    <div class="filters">
        <input type="text" id="search" placeholder="Search setting or policy..." oninput="applyFilters()">
        <select id="filterStatus" onchange="applyFilters()">
            <option value="">All statuses</option>
            <option value="Match">Match</option>
            <option value="Diff">Diff</option>
            <option value="Missing">Missing</option>
        </select>
        <select id="filterIssue" onchange="applyFilters()">
            <option value="">All issues</option>
            <option value="None">None</option>
            <option value="Duplicate">Duplicate</option>
            <option value="Conflict">Conflict</option>
        </select>
        <select id="filterPolicy" onchange="applyFilters()">
            <option value="">All policies</option>
        </select>
    </div>
    <div class="row-count" id="rowCount"></div>

    <div class="content-card">
        <div class="table-wrapper">
            <table id="mainTable">
                <thead>
                    <tr>
                        <th onclick="sortTable(0)">Policy<span class="sort-indicator"></span></th>
                        <th onclick="sortTable(1)">Setting<span class="sort-indicator"></span></th>
                        <th onclick="sortTable(2)">Source Value<span class="sort-indicator"></span></th>
                        <th class="col-status" onclick="sortTable(3)">Status<span class="sort-indicator"></span></th>
                        <th class="col-issue"  onclick="sortTable(4)">Issue<span class="sort-indicator"></span></th>
                    </tr>
                </thead>
                <tbody id="tableBody"></tbody>
            </table>
        </div>
        <div class="pagination" id="pagination"></div>
    </div>

    <footer>Basetune 2026 &nbsp;&middot;&nbsp; Built for the Intune community &nbsp;&middot;&nbsp; MIT License</footer>
</div>

<script>
    const toggleBtn = document.getElementById('theme-toggle');
    if (localStorage.getItem('theme') === 'dark') { document.body.classList.add('dark-mode'); }
    toggleBtn.addEventListener('click', () => {
        document.body.classList.toggle('dark-mode');
        localStorage.setItem('theme', document.body.classList.contains('dark-mode') ? 'dark' : 'light');
    });

    const PAGE_SIZE = 100;
    const ALL_DATA  = $jsonData;

    // Populate policy dropdown from unique policy names in data
    (function() {
        var seen = {};
        var opts = [];
        for (var i = 0; i < ALL_DATA.length; i++) {
            var p = ALL_DATA[i].policy;
            if (p && !seen[p]) { seen[p] = true; opts.push(p); }
        }
        opts.sort(function(a,b){ return a.localeCompare(b); });
        var sel = document.getElementById('filterPolicy');
        for (var j = 0; j < opts.length; j++) {
            var o = document.createElement('option');
            o.value = opts[j]; o.textContent = opts[j];
            sel.appendChild(o);
        }
    })();

    let filtered  = ALL_DATA.slice();
    let sortCol   = -1;
    let sortAsc   = true;
    let currentPage = 1;

    const statusBadge = {
        Match:   '<span class="badge val-match">Match</span>',
        Diff:    '<span class="badge val-diff">Diff</span>',
        Missing: '<span class="badge val-missing">Missing</span>'
    };
    const issueBadge = {
        Conflict:  function(n) { return '<span class="badge val-conflict">Conflict (' + n + ')</span>'; },
        Duplicate: function(n) { return '<span class="badge val-duplicate">Duplicate (' + n + ')</span>'; },
        None:      function()  { return '<span class="none-text">&#8212;</span>'; }
    };

    function esc(s) {
        return String(s ?? '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
    }

    function renderPage() {
        const start  = (currentPage - 1) * PAGE_SIZE;
        const slice  = filtered.slice(start, start + PAGE_SIZE);
        const tbody  = document.getElementById('tableBody');

        var html = '';
        for (var i = 0; i < slice.length; i++) {
            var r   = slice[i];
            var idx = start + i;
            var hasTargets = r.targets && r.targets.length > 0;

            // Main row
            html += '<tr class="main-row" onclick="toggleDetail(' + idx + ')" id="row-' + idx + '">' +
                '<td class="col-policy" title="' + esc(r.policy) + '">' +
                    (hasTargets ? '<span class="expand-icon"><svg width="12" height="12" viewBox="0 0 12 12" fill="none"><path d="M4 2.5L7.5 6L4 9.5" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg></span>' : '<span class="expand-icon" style="opacity:0"><svg width="12" height="12" viewBox="0 0 12 12" fill="none"><path d="M4 2.5L7.5 6L4 9.5" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg></span>') +
                    esc(r.policy) + '</td>' +
                '<td class="col-setting">' + esc(r.setting) + '</td>' +
                '<td class="col-value">'   + esc(r.value)   + '</td>' +
                '<td class="col-status">' + (statusBadge[r.status] || esc(r.status)) + '</td>' +
                '<td class="col-issue">'  + (issueBadge[r.issue] ? issueBadge[r.issue](r.tcount) : esc(r.issue)) + '</td>' +
                '</tr>';

            // Detail row (hidden by default)
            html += '<tr class="detail-row hidden" id="detail-' + idx + '">' +
                '<td colspan="5"><div class="detail-inner">';

            if (hasTargets) {
                html += '<table class="detail-table"><thead><tr>' +
                    '<th>Target Policy</th><th>Target Value</th>' +
                    '</tr></thead><tbody>';
                for (var j = 0; j < r.targets.length; j++) {
                    var t = r.targets[j];
                    html += '<tr><td>' + esc(t.name) + '</td><td>' + esc(t.value) + '</td></tr>';
                }
                html += '</tbody></table>';
            } else {
                html += '<span class="detail-empty">No matching target policies found.</span>';
            }

            html += '</div></td></tr>';
        }

        tbody.innerHTML = html;

        const total = filtered.length;
        const pages = Math.ceil(total / PAGE_SIZE) || 1;

        document.getElementById('rowCount').textContent =
            total + ' of $totalSettings settings visible';

        renderPagination(pages);
    }

    function toggleDetail(idx) {
        var mainRow   = document.getElementById('row-'   + idx);
        var detailRow = document.getElementById('detail-' + idx);
        if (!detailRow) return;
        var isOpen = !detailRow.classList.contains('hidden');
        detailRow.classList.toggle('hidden', isOpen);
        mainRow.classList.toggle('expanded', !isOpen);
    }

    function renderPagination(pages) {
        const el = document.getElementById('pagination');
        if (pages <= 1) { el.innerHTML = ''; return; }

        const prev = currentPage - 1;
        const next = currentPage + 1;

        var btns = '';
        btns += '<button onclick="goPage(1)"'       + (currentPage===1     ? ' disabled' : '') + '>&#171; First</button>';
        btns += '<button onclick="goPage(' + prev + ')"' + (currentPage===1 ? ' disabled' : '') + '>&#8249; Prev</button>';

        var range = 3;
        for (var p = Math.max(1, currentPage - range); p <= Math.min(pages, currentPage + range); p++) {
            btns += '<button onclick="goPage(' + p + ')"' + (p === currentPage ? ' class="active"' : '') + '>' + p + '</button>';
        }

        btns += '<button onclick="goPage(' + next   + ')"' + (currentPage===pages ? ' disabled' : '') + '>Next &#8250;</button>';
        btns += '<button onclick="goPage(' + pages  + ')"' + (currentPage===pages ? ' disabled' : '') + '>Last &#187;</button>';
        btns += '<span class="page-info">Page ' + currentPage + ' of ' + pages + '</span>';

        el.innerHTML = btns;
    }

    function goPage(p) {
        const pages = Math.ceil(filtered.length / PAGE_SIZE) || 1;
        currentPage = Math.max(1, Math.min(p, pages));
        renderPage();
        window.scrollTo({ top: 0, behavior: 'smooth' });
    }

    function filterByCard(status, issue) {
        document.getElementById('filterStatus').value = status;
        document.getElementById('filterIssue').value  = issue;
        document.getElementById('filterPolicy').value = '';
        document.getElementById('search').value = '';
        applyFilters();
    }

    // De markering wordt afgeleid uit de filterstand, niet gezet bij het
    // klikken. Anders blijft een tegel opgelicht zodra je daarna via de
    // dropdowns of het zoekveld iets anders kiest.
    //
    // Een tegel is alleen actief als de view precies is wat die tegel
    // oplevert: een enkele status of een enkel issue, zonder zoekterm en
    // zonder policyfilter. Bij een combinatie licht er niets op, want geen
    // enkele tegel dekt die dan.
    function syncCards() {
        document.querySelectorAll('.stat-card').forEach(function(c) {
            c.classList.remove('active');
        });

        var search = document.getElementById('search').value.trim();
        var status = document.getElementById('filterStatus').value;
        var issue  = document.getElementById('filterIssue').value;
        var policy = document.getElementById('filterPolicy').value;

        if (search || policy) { return; }
        if (status && issue)  { return; }

        var cls;
        if (!status && !issue) {
            cls = 's-total';
        } else {
            var map = { 'Match':'s-match', 'Diff':'s-diff', 'Missing':'s-missing',
                        'Duplicate':'s-dup', 'Conflict':'s-conflict' };
            cls = map[status || issue];
        }

        if (!cls) { return; }
        var el = document.querySelector('.' + cls);
        if (el) { el.classList.add('active'); }
    }

    function applyFilters() {
        const search = document.getElementById('search').value.toLowerCase();
        const status = document.getElementById('filterStatus').value;
        const issue  = document.getElementById('filterIssue').value;
        const policy = document.getElementById('filterPolicy').value;

        filtered = ALL_DATA.filter(function(r) {
            return (!search || (r.policy  || '').toLowerCase().includes(search) ||
                               (r.setting || '').toLowerCase().includes(search) ||
                               (r.value   || '').toLowerCase().includes(search))
                && (!status || r.status === status)
                && (!issue  || r.issue  === issue)
                && (!policy || r.policy === policy);
        });

        if (sortCol >= 0) applySort(false);

        syncCards();
        currentPage = 1;
        renderPage();
    }

    const sortKeys = ['policy','setting','value','status','issue'];

    function sortTable(col) {
        if (sortCol === col) { sortAsc = !sortAsc; } else { sortCol = col; sortAsc = true; }

        document.querySelectorAll('th').forEach((th, i) => {
            th.classList.remove('sorted-asc','sorted-desc');
            if (i === col) th.classList.add(sortAsc ? 'sorted-asc' : 'sorted-desc');
        });

        // applySort(false): sorteren zonder te tekenen. De renderPage hieronder
        // doet dat een keer, met currentPage al teruggezet naar 1.
        applySort(false);
        currentPage = 1;
        renderPage();
    }

    function applySort(rerender) {
        const key = sortKeys[sortCol];
        filtered.sort((a, b) => {
            const ta = (a[key] ?? '').toLowerCase();
            const tb = (b[key] ?? '').toLowerCase();
            return sortAsc ? ta.localeCompare(tb) : tb.localeCompare(ta);
        });
        if (rerender) renderPage();
    }

    applyFilters();
</script>
</body>
</html>
"@


    $html | Out-File -FilePath $OutputPath -Encoding UTF8
    Write-Log "HTML" "Report ready: $OutputPath ($totalSettings settings)" "OK"
}

Export-ModuleMember -Function Get-BaselineSummary, Get-OverlapSummary, Get-HtmlReport