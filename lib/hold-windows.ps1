# Persistent Win32 test harness for the occlusion and input tests.
#
# Creates two plain Win32 windows and keeps them alive, printing their handles so
# another process (or an agent) can drive them:
#   - OCCL_TARGET_MARKER_A          : the window under test, holds a real EDIT
#   - BLOCKER_ON_TOP_COVERING_...   : a maximized window that fully covers it
#
# Pair it with desktop_capture / desktop_focus / desktop_type to prove that a
# window can be captured and typed into while it is completely occluded. This is
# the scenario whose screenshot pair is archived in docs/evidence/.
#
# ⚠️ Why `WindowState = "Normal"` is re-applied after `Show()`: launching this via
# `Start-Process -WindowStyle Minimized` makes the Form inherit the minimized
# state and it lands at -32000,-32000, where capture tests silently measure an
# off-screen window. Re-asserting Normal + SetBounds after Show() is the fix.
#
# ⚠️ Keep the process alive for the whole test; the windows die with it.
param([int]$HoldSeconds = 600)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$target = New-Object System.Windows.Forms.Form
$target.Text = "OCCL_TARGET_MARKER_A"
$target.StartPosition = "Manual"
$target.SetBounds(150, 150, 900, 560)
$tb = New-Object System.Windows.Forms.TextBox
$tb.Name = "edit"
$tb.Multiline = $true
$tb.ScrollBars = "Vertical"
$tb.Dock = "Fill"
$tb.Font = New-Object System.Drawing.Font("Consolas", 14)
$target.Controls.Add($tb)
$target.Show()
$target.WindowState = "Normal"
$target.SetBounds(150, 150, 900, 560)

$blocker = New-Object System.Windows.Forms.Form
$blocker.Text = "BLOCKER_ON_TOP_COVERING_EVERYTHING"
$blocker.StartPosition = "Manual"
$blocker.SetBounds(0, 0, 1400, 900)
$blocker.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 20)
$blocker.Show()
$blocker.WindowState = "Normal"
$blocker.SetBounds(0, 0, 1400, 900)
$blocker.Activate()

# Machine-readable handles, so a caller can pipe these straight into -Handle.
"TARGET_HWND=$($target.Handle)"
"TARGET_EDIT_HWND=$($tb.Handle)"
"BLOCKER_HWND=$($blocker.Handle)"
"READY"
[Console]::Out.Flush()

$deadline = (Get-Date).AddSeconds($HoldSeconds)
while ((Get-Date) -lt $deadline) {
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 100
}
