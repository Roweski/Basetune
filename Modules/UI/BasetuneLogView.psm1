# =============================================================================
# BasetuneLogView.psm1
# The log view at the bottom of the main window (RichTextBox): adding lines
# (Add-UILogLines, Write-UILog), clickable paths, the busy dots and clearing
# it. UI lines are also written to the log file.
#
# Shares the controls ($UI) and the app state ($AppState) with the other UI
# modules through BasetuneState.psm1.
# =============================================================================

$script:UI       = (Get-BasetuneContext).UI
$script:AppState = (Get-BasetuneContext).State

# ── Log view (RichTextBox) ───────────────────────────────────────────────────
# One Paragraph per line, so a single line can be coloured. Lines come in as
# log entries (New-LogEntry: Level, Label, Message); the log file keeps the
# label. The view shows only the message; ERROR lines use ErrorBrush, WARN
# lines WarnBrush (both follow the theme). Messages that need the side say
# it ("Loading source policies").
$script:UILogMaxLines = 5000

# Local paths in a line (C:\...\Report.html, a folder) become links: a click
# opens the file with its default app, or the folder in Explorer. A path ends
# at the end of the line, before " (", " —", a quote or a sentence-ending
# period. " (" only ends it when no backslash follows, so a folder like
# "Basetune (1)\Definitions" stays whole.
#
# Short file names: a file in another folder than the last one shown first
# gets a "Using path: <folder>" line; the lines after it show only the file
# name (still a link to the full path). The compare output has its own
# "Report folder: ..." line (see Add-UILogLines). View only: the log file
# keeps the full paths.
$script:UILogPathRegex = [regex]'[A-Za-z]:\\.*?(?=\.?(?:\s\((?![^\\]*\\)|\s—|[''"]|$))'
$script:UILogLastDir   = $null

# Plain string split on '\' (the paths are always Windows paths).
function script:Get-UILogFolder  { param([string]$Path) $i = $Path.LastIndexOf('\'); if ($i -gt 2) { $Path.Substring(0, $i) } else { $null } }
function script:Get-UILogName { param([string]$Path) $Path.Substring($Path.LastIndexOf('\') + 1) }

function script:Test-UILogIsFile {
    param([string]$Path)
    return ((Get-UILogName $Path) -match '\.[A-Za-z0-9]{1,5}$')
}

function script:New-UILogLink {
    param([string]$Path, [string]$Display)
    $link = [System.Windows.Documents.Hyperlink]::new([System.Windows.Documents.Run]::new($Display))
    $link.Tag     = $Path
    $link.ToolTip = $Path
    $link.SetResourceReference([System.Windows.Documents.TextElement]::ForegroundProperty, 'AccentBrush')
    $link.Add_Click({
        param($sender, $e)
        $path = [string]$sender.Tag
        if (-not (Test-Path -LiteralPath $path)) {
            # Test-Path is also $false for a path without read permission;
            # GetAttributes then throws UnauthorizedAccessException.
            $denied = $false
            # PowerShell wraps .NET method errors: check the inner exception.
            try { [void][System.IO.File]::GetAttributes($path); $denied = $true }
            catch {
                $ex = $_.Exception
                if ($ex -is [System.Management.Automation.MethodInvocationException] -and $ex.InnerException) { $ex = $ex.InnerException }
                if ($ex -is [System.UnauthorizedAccessException]) { $denied = $true }
            }
            if ($denied) {
                $what = if (Test-UILogIsFile $path) { 'file' } else { 'folder' }
                Write-UILog 'Basetune' "Could not open the $what. See the log file for details" 'WARN'
                Write-Log 'Basetune' "Details: no access to '$path'" 'WARN' -FileOnly
            } else {
                Write-UILog 'Basetune' "Path not found: $path" 'WARN'
            }
            return
        }
        try { Start-Process -FilePath $path -ErrorAction Stop }
        catch {
            # No app associated with the file type: show it in Explorer.
            try { Start-Process explorer.exe -ArgumentList "/select,`"$path`"" } catch {}
        }
    })
    return $link
}

# One shared zero margin (a struct: assigning copies it), not a new Thickness
# per line.
$script:UILogZeroMargin = [System.Windows.Thickness]::new(0)

function script:New-UILogParagraph {
    $p = [System.Windows.Documents.Paragraph]::new()
    $p.Margin = $script:UILogZeroMargin
    return $p
}

# "See the log file" becomes a link that opens Basetune.log (other wording:
# just "the log file"). "See compare.log for details" (the warnings at the
# end of a compare) is a link as a whole to compare.log in the folder of the
# running compare (written by Invoke-BaselineCompare, next to the report);
# without "for details" just "See compare.log".
$script:UILogFileRegex = [regex]'(?<log>See the log file|the log file)|(?<cmp>See compare\.log(?: for details)?)'

function script:Add-UILogText {
    param([System.Windows.Documents.Paragraph]$Paragraph, [string]$Text, [switch]$NoLinks)
    if (-not $Text) { return }
    $pos = 0
    if (-not $NoLinks) {
        foreach ($m in $script:UILogFileRegex.Matches($Text)) {
            $target = if ($m.Groups['cmp'].Success) {
                          if ($AppState.compareRunDir) { Join-Path $AppState.compareRunDir 'compare.log' }
                      } else { $AppState.logFile }
            if (-not $target) { continue }   # left as plain text below
            if ($m.Index -gt $pos) {
                $Paragraph.Inlines.Add([System.Windows.Documents.Run]::new($Text.Substring($pos, $m.Index - $pos)))
            }
            $Paragraph.Inlines.Add((New-UILogLink -Path $target -Display $m.Value))
            $pos = $m.Index + $m.Length
        }
    }
    if ($pos -lt $Text.Length) {
        $Paragraph.Inlines.Add([System.Windows.Documents.Run]::new($Text.Substring($pos)))
    }
}

function script:Add-UILogInlines {
    param([System.Windows.Documents.Paragraph]$Paragraph, [string]$Text, [switch]$NoLinks)
    $pos = 0
    foreach ($m in $script:UILogPathRegex.Matches($Text)) {
        if ($m.Length -lt 4) { continue }
        if ($m.Index -gt $pos) {
            Add-UILogText -Paragraph $Paragraph -Text $Text.Substring($pos, $m.Index - $pos) -NoLinks:$NoLinks
        }
        $path    = $m.Value
        $display = $path
        if ((Test-UILogIsFile $path) -and $script:UILogLastDir -and
            ((Get-UILogFolder $path) -eq $script:UILogLastDir)) {
            $display = Get-UILogName $path
        }
        if ($NoLinks) { $Paragraph.Inlines.Add([System.Windows.Documents.Run]::new($display)) }
        else          { $Paragraph.Inlines.Add((New-UILogLink -Path $path -Display $display)) }
        $pos = $m.Index + $m.Length
    }
    if ($pos -lt $Text.Length) {
        Add-UILogText -Paragraph $Paragraph -Text $Text.Substring($pos) -NoLinks:$NoLinks
    }
}

# ── Calm "busy" dots on some progress lines ────────────────────────────────
# The compare, export and download progress lines ("Comparing settings...",
# "Exporting HTML report...", "Writing definition files to disk...", see the
# regex) keep their dots moving (. .. ...) every 0.6 s until the next line is
# written; then they end as plain "...". One line animates at a time. Best
# effort: without the run nothing animates.
$script:UILogAnimRegex = [regex]'^(?<base>Comparing settings|Resolving display names( and categories)?|Exporting CSV reports|Exporting HTML report|Downloading (setting|category|setting and category) definitions( using tenant: .+)?|Writing definition files to disk|Updating category definitions)\.\.\.$'
$script:UILogAnimRun   = $null
$script:UILogAnimBase  = ''
$script:UILogAnimTick  = 0
$script:UILogAnimTimer = $null
$script:UILogLastLineResolving = $false   # last line in the view was the "Resolving display names ..." line

function script:Stop-UILogAnim {
    if ($script:UILogAnimRun) {
        try { $script:UILogAnimRun.Text = $script:UILogAnimBase + '...' } catch {}
    }
    $script:UILogAnimRun = $null
    if ($script:UILogAnimTimer) { $script:UILogAnimTimer.Stop() }
}

function script:Start-UILogAnim {
    param($Run, [string]$Base)
    Stop-UILogAnim
    $script:UILogAnimRun  = $Run
    $script:UILogAnimBase = $Base
    $script:UILogAnimTick = 0
    if (-not $script:UILogAnimTimer) {
        $t = [System.Windows.Threading.DispatcherTimer]::new()
        $t.Interval = [TimeSpan]::FromMilliseconds(600)
        $t.Add_Tick({
            $r = $script:UILogAnimRun
            if (-not $r) { $script:UILogAnimTimer.Stop(); return }
            $script:UILogAnimTick++
            try { $r.Text = $script:UILogAnimBase + ('.' * (($script:UILogAnimTick % 3) + 1)) } catch {}
        })
        $script:UILogAnimTimer = $t
    }
    $script:UILogAnimTimer.Start()
}

# Adds log entries (New-LogEntry) to the view: one entry, or a batch drained
# from a runspace queue. View only: Write-UILog / Write-Log write the file.
function Add-UILogLines {
    param([object[]]$Entries)
    if (-not $Entries -or -not $UI.txtLog) { return }
    $doc = $UI.txtLog.Document
    foreach ($entry in $Entries) {
        if (-not $entry -or -not $entry.Message) { continue }
        $level = $entry.Level
        # A message with line breaks: a paragraph per line, all with the
        # entry's level. Most have none (the -split regex is skipped then).
        $msgLines = if ($entry.Message.Contains("`n")) { $entry.Message -split "`r?`n" } else { $entry.Message }
        foreach ($shown in $msgLines) {
            if ($shown.Trim().Length -eq 0) { continue }
            # Log file only: the JSON folder of a load ("Using path: ...").
            if ($level -ne 'ERROR' -and $shown -match '^Using path: ') { continue }

            # Selection changed during the compare: the note goes right after the
            # "Resolving display names ..." line (if no line follows it, it is
            # written when the compare ends).
            if ($AppState.compareSelectionNotePending -and $script:UILogLastLineResolving) {
                $AppState.compareSelectionNotePending = $false
                Write-UILog 'Compare' 'Policy selection changed. Disabling report and details buttons'
            }
            $script:UILogLastLineResolving = ($shown -match '^(Resolving|Skipping) display names')

            # A new line ends the dots of the previous busy line. Only called when
            # a line is busy: a call per line adds up over 1000+ "Loaded policy" lines.
            if ($script:UILogAnimRun) { Stop-UILogAnim }

            # Compare output in the order Invoke-BaselineCompare logs it (-> as shown):
            #   Comparison complete: 958 rows processed            (as it is)
            #   Report folder: C:\reports\Src_Tgt\20261010_113304   (link, relative)
            #   Exporting CSV reports...
            #   Created <path>\Diff.csv (958 rows)                  -> Created Diff.csv (958 rows)
            #   Created <path>\Summary.csv                          -> Created Summary.csv
            #   Exporting HTML report...
            #   Created <path>\Report.html (522 settings)           -> Created Report.html (522 settings)
            # The "Report folder" line sets the folder, so the "Created" lines show
            # only the file name as a link (general path handling below).
            # No counts per status here: the report counts per setting, which
            # differs from the rows in Diff.csv.
            if ($level -ne 'ERROR' -and $shown -match '^Report folder: (?<p>[A-Za-z]:\\.+)$') {
                $dir = $Matches['p'].TrimEnd('\')
                $script:UILogLastDir = $dir
                $up = New-UILogParagraph
                $up.Inlines.Add([System.Windows.Documents.Run]::new('Report folder: '))
                # Shown relative (Src_Tgt\yyyyMMdd_HHmmss); link and tooltip keep
                # the full path.
                $dirShown = $dir
                $base = if ($AppState.reportBasePath) { $AppState.reportBasePath.TrimEnd('\') + '\' } else { $null }
                if ($base -and $dir.Length -gt $base.Length -and $dir.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $dirShown = $dir.Substring($base.Length)
                }
                $up.Inlines.Add((New-UILogLink -Path $dir -Display $dirShown))
                $doc.Blocks.Add($up)
                continue
            }

            # Lines about Config.json (e.g. "Report path in Config.json normalized:
            # 'C:\Reports\' -> 'C:\Reports'.") describe its contents: plain text,
            # no path links, no folder bookkeeping.
            if ($shown -match 'Config\.json') {
                # View only: the default report folder in the missing / invalid
                # report path messages is shown as .\Reports.
                if ($shown -match '^(Config\.json is missing report path setting|Invalid report path .+ in Config\.json)\. Set to default \(' -and $AppState.ScriptRoot) {
                    $rootRx = [regex]::Escape('Set to default (' + $AppState.ScriptRoot.TrimEnd('\') + '\')
                    $shown  = [regex]::Replace($shown, $rootRx, 'Set to default (.\', 'IgnoreCase')
                }
                $p = New-UILogParagraph
                # No path links here, but "the log file" stays a link.
                Add-UILogText -Paragraph $p -Text $shown
                if ($level -eq 'ERROR') {
                    $p.SetResourceReference([System.Windows.Documents.TextElement]::ForegroundProperty, 'ErrorBrush')
                } elseif ($level -eq 'WARN') {
                    $p.SetResourceReference([System.Windows.Documents.TextElement]::ForegroundProperty, 'WarnBrush')
                }
                $doc.Blocks.Add($p)
                continue
            }

            # Most lines ("Loaded policy: ...", 1000+ in a large load) hold no path
            # and no link text. The regex calls below (.NET calls, slow per line)
            # only run when the line can match: a path needs "X:\", a link "the log
            # file" / "See compare.log" (checked case-insensitively here, so nothing
            # the case-sensitive link regex matches is skipped).
            $hasPath = $shown -match '[A-Za-z]:\\'
            $plain   = $shown -and -not $hasPath -and $shown -notmatch 'the log file|See compare\.log'

            # Folder bookkeeping for the short file names (see above).
            $first = if ($hasPath) { $script:UILogPathRegex.Match($shown) } else { $null }
            if ($first -and $first.Success -and $first.Length -ge 4) {
                if (-not (Test-UILogIsFile $first.Value)) {
                    # A folder line ("Using path: C:\...\EXPORT"): remember it.
                    $script:UILogLastDir = $first.Value.TrimEnd('\')
                } else {
                    $dir = Get-UILogFolder $first.Value
                    if ($dir -and $dir -ne $script:UILogLastDir) {
                        $script:UILogLastDir = $dir
                        $up = New-UILogParagraph
                        # Other files (e.g. downloaded definitions); the compare
                        # has its own "Report folder" line.
                        $up.Inlines.Add([System.Windows.Documents.Run]::new('Using path: '))
                        $up.Inlines.Add((New-UILogLink -Path $dir -Display $dir))
                        $doc.Blocks.Add($up)
                    }
                }
            }

            # New-UILogParagraph inline: a function call per line costs about as
            # much as the WPF work of the line itself.
            $p = [System.Windows.Documents.Paragraph]::new()
            $p.Margin = $script:UILogZeroMargin
            # Downloaded definition files: name only, no link (their "Using path:"
            # folder line stays a link).
            $noLinks = ($shown -match '^Saved (definitions|categories) to ')
            if ($plain) {
                # The whole line as one Run, as Add-UILogInlines would give it.
                $p.Inlines.Add([System.Windows.Documents.Run]::new($shown))
            } else {
                Add-UILogInlines -Paragraph $p -Text $shown -NoLinks:$noLinks
            }
            # ERROR lines red, WARN lines orange (WarnBrush, darker in the light
            # theme). Links keep their own colour (New-UILogLink: AccentBrush).
            if ($level -eq 'ERROR') {
                $p.SetResourceReference([System.Windows.Documents.TextElement]::ForegroundProperty, 'ErrorBrush')
            } elseif ($level -eq 'WARN') {
                $p.SetResourceReference([System.Windows.Documents.TextElement]::ForegroundProperty, 'WarnBrush')
            }
            $doc.Blocks.Add($p)
            # Busy line: animate its dots. The regex only runs on lines ending in "...".
            $am = if ($shown -like '*...') { $script:UILogAnimRegex.Match($shown) } else { $null }
            if ($am -and $am.Success -and $level -ne 'ERROR' -and $p.Inlines.FirstInline -is [System.Windows.Documents.Run]) {
                Start-UILogAnim -Run $p.Inlines.FirstInline -Base $am.Groups['base'].Value
            }
        }
    }
    # Rolling window: keep the view responsive in long sessions.
    while ($doc.Blocks.Count -gt $script:UILogMaxLines) {
        [void]$doc.Blocks.Remove($doc.Blocks.FirstBlock)
    }
    $UI.txtLog.ScrollToEnd()
}

function Clear-UILogView {
    Stop-UILogAnim
    if ($UI.txtLog) { $UI.txtLog.Document.Blocks.Clear() }
    $script:UILogLastDir = $null
}

# A line in the log view and the log file (the file is a complete record of
# what the user saw). Same parameters as Write-Log; on the UI thread the two
# give the same result.
function Write-UILog {
    param([string]$Label, [string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    $entry = New-LogEntry $Label $Message $Level
    Add-UILogLines $entry
    if ($AppState.logFile) { Add-LogFileLine -Path $AppState.logFile -Entry $entry }
}

# Clears the log view; with a message, that becomes its first line.
function Clear-UILog {
    param([string]$Label, [string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    Clear-UILogView
    if ($Message) { Write-UILog $Label $Message $Level }
}

Export-ModuleMember -Function @(
    'Add-UILogLines',
    'Clear-UILogView',
    'Write-UILog',
    'Clear-UILog'
)
