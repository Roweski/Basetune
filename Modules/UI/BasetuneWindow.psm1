# =============================================================================
# BasetuneWindow.psm1
# Main window chrome: own title bar, start size / position, maximised margin,
# tooltips for cut-off text, rounded corners, and the collapsible log view.
# $UI / $AppState come from BasetuneState.psm1.
# =============================================================================

$script:UI       = (Get-BasetuneContext).UI
$script:AppState = (Get-BasetuneContext).State

# ── Native window helpers ────────────────────────────────────────────────────
# For Resize-BasetuneWindowToScreen and the maximised margin.
# DPI: pwsh.exe is "system DPI aware" (its manifest): sharp on the main
# monitor, scaled by Windows on a monitor with other scaling. Per-monitor DPI
# set from the script (thread or HighDpiAware layer) gives half-drawn windows
# or stuck scaling; WPF needs it from the manifest (an own launcher .exe).
try {
    if (-not ('Basetune.NativeWin' -as [type])) {
        Add-Type -Namespace Basetune -Name NativeWin -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern uint GetDpiForWindow(System.IntPtr hwnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetWindowPos(System.IntPtr hwnd, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool GetWindowRect(System.IntPtr hwnd, out RECT rect);
'@
    }
} catch {}

# ── Fit the start size to the monitor ────────────────────────────────────────
# 1400x1000 does not fit every screen (a laptop at 175% has ~850-900 DIP
# height), and a window can open across two monitors. Once shown, a window that
# does not fit on one monitor is moved onto the monitor holding most of it,
# shrunk to at most 92% of its work area and centred. Pixels via the window's
# own DPI + SetWindowPos (one coordinate space, also with other scaling).
# Best-effort: on any error nothing changes.
function Resize-BasetuneWindowToScreen {
    param($Win)
    try {
        $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($Win).Handle
        if ($hwnd -eq [System.IntPtr]::Zero) { return }
        $scale = [Basetune.NativeWin]::GetDpiForWindow($hwnd) / 96.0
        if ($scale -le 0) { return }
        $wa = [System.Windows.Forms.Screen]::FromHandle($hwnd).WorkingArea   # physical pixels
        $availW = $wa.Width  / $scale
        $availH = $wa.Height / $scale
        $maxW   = [math]::Floor($availW * 0.92)
        $maxH   = [math]::Floor($availH * 0.92)
        if ($Win.MinWidth  -gt $maxW) { $Win.MinWidth  = $maxW }
        if ($Win.MinHeight -gt $maxH) { $Win.MinHeight = $maxH }
        $w = [math]::Min($Win.ActualWidth,  $maxW)
        $h = [math]::Min($Win.ActualHeight, $maxH)

        $pxW = [int][math]::Round($w * $scale)
        $pxH = [int][math]::Round($h * $scale)
        $tooBig = ($w -lt $Win.ActualWidth) -or ($h -lt $Win.ActualHeight)
        $r = New-Object Basetune.NativeWin+RECT
        $inside = $true
        if ([Basetune.NativeWin]::GetWindowRect($hwnd, [ref]$r)) {
            # Small tolerance for the invisible resize border around the window.
            $tol = [int](8 * $scale)
            $inside = ($r.Left -ge $wa.Left - $tol) -and ($r.Top -ge $wa.Top - $tol) -and
                      ($r.Right -le $wa.Right + $tol) -and ($r.Bottom -le $wa.Bottom + $tol)
        }
        if (-not $tooBig -and $inside) { return }
        $x = $wa.Left + [int](($wa.Width  - $pxW) / 2)
        $y = $wa.Top  + [int](($wa.Height - $pxH) / 2)
        # SWP_NOZORDER (0x4) | SWP_NOACTIVATE (0x10)
        [void][Basetune.NativeWin]::SetWindowPos($hwnd, [System.IntPtr]::Zero, $x, $y, $pxW, $pxH, 0x14)
    } catch {}
}

# Maximised: Windows puts the resize frame off-screen on every side. Move the
# content in by that amount (window rect vs work area) and hide the outline.
# Restored: no margin, outline back. Also sets the maximise / restore glyph.
function Update-BasetuneMaximizedState {
    $w = $UI.Window
    $isMax = ($w.WindowState -eq 'Maximized')
    if ($UI.btnCaptionMax) {
        $UI.btnCaptionMax.Content = if ($isMax) { [string][char]0xE923 } else { [string][char]0xE922 }
        $UI.btnCaptionMax.ToolTip = if ($isMax) { 'Restore Down' } else { 'Maximize' }
    }
    if (-not $UI.rootBorder) { return }
    if (-not $isMax) {
        $UI.rootBorder.Margin          = [System.Windows.Thickness]::new(0)
        $UI.rootBorder.BorderThickness = [System.Windows.Thickness]::new(1)
        return
    }
    $UI.rootBorder.BorderThickness = [System.Windows.Thickness]::new(0)
    try {
        $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($w).Handle
        $r = New-Object Basetune.NativeWin+RECT
        if (-not [Basetune.NativeWin]::GetWindowRect($hwnd, [ref]$r)) { return }
        $wa    = [System.Windows.Forms.Screen]::FromHandle($hwnd).WorkingArea
        $scale = [System.Windows.Media.VisualTreeHelper]::GetDpi($w).DpiScaleX
        if ($scale -le 0) { $scale = 1 }
        $l = [math]::Max(0, $wa.Left   - $r.Left)   / $scale
        $t = [math]::Max(0, $wa.Top    - $r.Top)    / $scale
        $rr = [math]::Max(0, $r.Right  - $wa.Right)  / $scale
        $b = [math]::Max(0, $r.Bottom - $wa.Bottom) / $scale
        $UI.rootBorder.Margin = [System.Windows.Thickness]::new($l, $t, $rr, $b)
    } catch {
        # Fallback: the usual frame width.
        $UI.rootBorder.Margin = [System.Windows.Thickness]::new(7)
    }
}

# ── Tooltips with the full name only when the text is cut off ────────────────
# Policy names and the selected tenant are cut off with "..." in a narrow
# window. When the text fits, the tooltip is cancelled just before it opens
# (one text measurement at that moment, nothing in the background).
function Test-BasetuneTextTrimmed {
    param([System.Windows.Controls.TextBlock]$Tb)
    if (-not $Tb -or -not $Tb.Text -or $Tb.ActualWidth -le 0) { return $false }
    $tf = [System.Windows.Media.Typeface]::new($Tb.FontFamily, $Tb.FontStyle, $Tb.FontWeight, $Tb.FontStretch)
    $ft = [System.Windows.Media.FormattedText]::new($Tb.Text, [System.Globalization.CultureInfo]::CurrentCulture,
            $Tb.FlowDirection, $tf, $Tb.FontSize, $Tb.Foreground,
            [System.Windows.Media.VisualTreeHelper]::GetDpi($Tb).PixelsPerDip)
    return ($ft.WidthIncludingTrailingWhitespace -gt ($Tb.ActualWidth + 0.5))
}

# Rotate the chevron (down = expanded, up = collapsed) in 0.4 s, from the
# current angle, so a fast double click turns back smoothly.
function Set-LogToggleRotation {
    param([double]$Angle)
    if (-not $UI.pathToggleLog) { return }
    $rot = $UI.pathToggleLog.RenderTransform
    if (-not ($rot -is [System.Windows.Media.RotateTransform]) -or $rot.IsFrozen) {
        $rot = New-Object System.Windows.Media.RotateTransform 0
        $UI.pathToggleLog.RenderTransformOrigin = New-Object System.Windows.Point 0.5, 0.5
        $UI.pathToggleLog.RenderTransform = $rot
    }
    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $anim.To       = $Angle
    $anim.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(400))
    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseInOut
    $anim.EasingFunction = $ease
    $rot.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $anim)
}

# ═════════════════════════════════════════════════════════════════════════════
# INITIALISATION
# Title bar, window and log view handlers. Called once from Basetune.ps1,
# after the main window is loaded and its controls registered.
# ═════════════════════════════════════════════════════════════════════════════
function Initialize-BasetuneWindow {
    $UI.Window.Add_ContentRendered({ Resize-BasetuneWindowToScreen $UI.Window })

    # ── Own title bar (WindowChrome, see BasetuneUI.xaml) ────────────────────────
    if ($UI.btnCaptionMin)   { $UI.btnCaptionMin.Add_Click({ $UI.Window.WindowState = 'Minimized' }) }
    if ($UI.btnCaptionClose) { $UI.btnCaptionClose.Add_Click({ $UI.Window.Close() }) }
    if ($UI.btnCaptionMax) {
        $UI.btnCaptionMax.Add_Click({
            $UI.Window.WindowState = if ($UI.Window.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' }
        })
    }

    # Title bar icon: the icon of the host process (pwsh), same as the taskbar.
    try {
        $exeIcon = [System.Drawing.Icon]::ExtractAssociatedIcon((Get-Process -Id $PID).Path)
        if ($exeIcon -and $UI.imgTitleIcon) {
            $UI.imgTitleIcon.Source = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
                $exeIcon.Handle, [System.Windows.Int32Rect]::Empty,
                [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        }
    } catch {}

    $UI.Window.Add_StateChanged({
        # Run after Windows has applied the new window rect.
        [void]$UI.Window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background,
            [action]{ Update-BasetuneMaximizedState })
    })

    try {
        # Policy names: TextBlock with TextTrimming and its own tooltip.
        [System.Windows.EventManager]::RegisterClassHandler([System.Windows.Controls.TextBlock],
            [System.Windows.FrameworkElement]::ToolTipOpeningEvent,
            [System.Windows.Controls.ToolTipEventHandler]{
                param($sender, $e)
                try {
                    if ($sender.TextTrimming -ne 'None' -and -not (Test-BasetuneTextTrimmed $sender)) { $e.Handled = $true }
                } catch {}
            })
        # Tenant dropdowns: check the text of the selected item in the template.
        [System.Windows.EventManager]::RegisterClassHandler([System.Windows.Controls.ComboBox],
            [System.Windows.FrameworkElement]::ToolTipOpeningEvent,
            [System.Windows.Controls.ToolTipEventHandler]{
                param($sender, $e)
                try {
                    $cp = $sender.Template.FindName('content', $sender)
                    $tb = if ($cp -and [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($cp) -gt 0) {
                        [System.Windows.Media.VisualTreeHelper]::GetChild($cp, 0) } else { $null }
                    if ($tb -is [System.Windows.Controls.TextBlock] -and -not (Test-BasetuneTextTrimmed $tb)) { $e.Handled = $true }
                } catch {}
            })
    } catch {}

    # Windows 11: rounded corners for the own frame (DWMWA_WINDOW_CORNER_PREFERENCE
    # = 33, DWMWCP_ROUND = 2). Ignored on Windows 10.
    $UI.Window.Add_SourceInitialized({
        try {
            if ('Basetune.DwmTheme' -as [type]) {
                $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($UI.Window).Handle
                $round = 2
                [void][Basetune.DwmTheme]::DwmSetWindowAttribute($hwnd, 33, [ref]$round, 4)
            }
        } catch {}
    })

    # No undo on the log view (RichTextBox): its undo stack of thousands of
    # appended lines costs 50-200 MB that the 10k-line trim cannot free.
    # Must be set BEFORE any text is appended.
    $UI.txtLog.IsUndoEnabled = $false

    # Calm, proportional scrolling for the log and both policy lists (see
    # Set-SlowScroll).
    Set-SlowScroll -Element $UI.txtLog

    # ── Collapse / expand the log ────────────────────────────────────────────────
    # Collapsed: only the last log line, so the status stays visible and the
    # policy lists get the space. Expanded at start; errors do not expand it
    # (an ERROR line is red, also as the only line shown).
    $AppState.logCollapsed  = $false

    if ($UI.btnToggleLog) {
        $UI.btnToggleLog.Add_Click({
            $AppState.logCollapsed = -not $AppState.logCollapsed
            if ($AppState.logCollapsed) {
                $UI.txtLog.Height = 36      # 1 line of 16 + padding 2x10
                $UI.btnToggleLog.ToolTip = 'Expand log'
                Set-LogToggleRotation -Angle 180
            } else {
                $UI.txtLog.Height = 100     # 5 lines of 16 + padding 2x10
                $UI.btnToggleLog.ToolTip = 'Collapse log'
                Set-LogToggleRotation -Angle 0
            }
            $UI.txtLog.ScrollToEnd()
        })
    }
    # Policy lists: whole rows (3 per mouse notch), never half a row at the top.
    Set-SlowScroll -Element $UI.lstSource -PerItem
    Set-SlowScroll -Element $UI.lstTarget -PerItem

    # Arrow keys + Space in the policy lists (see Enable-PolicyListKeys).
    Enable-PolicyListKeys -List $UI.lstSource
    Enable-PolicyListKeys -List $UI.lstTarget
    # Only whole lines visible in the policy lists (see Enable-WholeLineList).
    Enable-WholeLineList -List $UI.lstSource
    Enable-WholeLineList -List $UI.lstTarget
}

Export-ModuleMember -Function @(
    'Resize-BasetuneWindowToScreen',
    'Update-BasetuneMaximizedState',
    'Test-BasetuneTextTrimmed',
    'Set-LogToggleRotation',
    'Initialize-BasetuneWindow'
)
