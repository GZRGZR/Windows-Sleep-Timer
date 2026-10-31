$ErrorActionPreference = 'Stop'

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SleepTimerPower {
    [DllImport("powrprof.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.U1)]
    public static extern bool SetSuspendState(
        [MarshalAs(UnmanagedType.U1)] bool hibernate,
        [MarshalAs(UnmanagedType.U1)] bool forceCritical,
        [MarshalAs(UnmanagedType.U1)] bool disableWakeEvent
    );
}
'@

    function script:Convert-TimeInput([string]$text) {
        $s = ($text.Trim() -replace ',', '.')
        if ($s -notmatch '^\d+(\.\d+)?$') {
            throw "יש להזין מספר בלבד, לדוגמה 10 או 3.4"
        }

        $parts = $s.Split('.')
        $wholeMinutes = [int]$parts[0]
        $extraSeconds = 0

        if ($parts.Length -gt 1) {
            $fraction = [double]::Parse("0.$($parts[1])", [Globalization.CultureInfo]::InvariantCulture)

            # עד 0.59 כולל: הסיומת היא שניות (3.4 = 40 שניות; 3.59 = 59).
            # מעל 0.59: הסיומת נחשבת חלקי דקה (3.6 = 36 שניות; 3.75 = 45).
            if ($fraction -le 0.59) {
                $extraSeconds = [int][math]::Round($fraction * 100, [MidpointRounding]::AwayFromZero)
            }
            else {
                $extraSeconds = [int][math]::Round($fraction * 60, [MidpointRounding]::AwayFromZero)
            }
        }

        $totalSeconds = ($wholeMinutes * 60) + $extraSeconds
        if ($totalSeconds -le 0 -or $totalSeconds -gt 86400) {
            throw "יש לבחור זמן גדול מאפס ועד 24 שעות."
        }
        return [int]$totalSeconds
    }

    function script:Format-Remaining([int]$seconds) {
        $span = [TimeSpan]::FromSeconds([math]::Max(0, $seconds))
        return ("{0:00}:{1:00}" -f [math]::Floor($span.TotalMinutes), $span.Seconds)
    }

    # State and controls are script-scoped so the event callbacks always see them.
    $script:timerRunning = $false
    $script:alertPlayed = $false
    $script:deadlineUtc = [DateTime]::UtcNow
    $script:remainingSeconds = 0
    $script:initialDurationSeconds = 0
    $script:extensionCount = 0
    $script:latePhase = $false
    $script:selectedAction = "sleep"

    # Main window
    $script:form = New-Object System.Windows.Forms.Form
    $script:form.Text = "טיימר שינה / כיבוי"
    $script:form.Size = New-Object System.Drawing.Size(510, 525)
    $script:form.MinimumSize = New-Object System.Drawing.Size(510, 525)
    $script:form.MaximumSize = New-Object System.Drawing.Size(510, 525)
    $script:form.StartPosition = "CenterScreen"
    $script:form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $script:form.MaximizeBox = $false
    $script:form.BackColor = [System.Drawing.Color]::FromArgb(246, 248, 252)
    $script:form.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $script:form.RightToLeft = [System.Windows.Forms.RightToLeft]::Yes
    $script:form.RightToLeftLayout = $true

    $script:header = New-Object System.Windows.Forms.Panel
    $script:header.Location = New-Object System.Drawing.Point(0, 0)
    $script:header.Size = New-Object System.Drawing.Size(510, 82)
    $script:header.BackColor = [System.Drawing.Color]::FromArgb(35, 70, 115)
    $script:form.Controls.Add($script:header)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = "טיימר שינה / כיבוי"
    $title.ForeColor = [System.Drawing.Color]::White
    $title.Font = New-Object System.Drawing.Font("Segoe UI", 19, [System.Drawing.FontStyle]::Bold)
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(275, 12)
    $script:header.Controls.Add($title)

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = "קובעים זמן – ובסיומו המחשב יפעל לפי הבחירה"
    $subtitle.ForeColor = [System.Drawing.Color]::FromArgb(225, 235, 248)
    $subtitle.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $subtitle.AutoSize = $true
    $subtitle.Location = New-Object System.Drawing.Point(145, 51)
    $script:header.Controls.Add($subtitle)

    # Settings view
    $script:settingsPanel = New-Object System.Windows.Forms.Panel
    $script:settingsPanel.Location = New-Object System.Drawing.Point(24, 98)
    $script:settingsPanel.Size = New-Object System.Drawing.Size(450, 355)
    $script:settingsPanel.BackColor = [System.Drawing.Color]::White
    $script:settingsPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $script:form.Controls.Add($script:settingsPanel)

    $prompt = New-Object System.Windows.Forms.Label
    $prompt.Text = "כמה זמן עד שהמחשב ייכנס לשינה או יכבה?"
    $prompt.Location = New-Object System.Drawing.Point(22, 15)
    $prompt.Size = New-Object System.Drawing.Size(404, 28)
    $prompt.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $prompt.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $script:settingsPanel.Controls.Add($prompt)

    $script:timeBox = New-Object System.Windows.Forms.TextBox
    $script:timeBox.Location = New-Object System.Drawing.Point(40, 49)
    $script:timeBox.Size = New-Object System.Drawing.Size(366, 37)
    $script:timeBox.Font = New-Object System.Drawing.Font("Segoe UI", 16)
    $script:timeBox.TextAlign = [System.Windows.Forms.HorizontalAlignment]::Center
    $script:timeBox.Text = "10"
    $script:timeBox.RightToLeft = [System.Windows.Forms.RightToLeft]::No
    $script:settingsPanel.Controls.Add($script:timeBox)

    $examples = New-Object System.Windows.Forms.Label
    $examples.Text = "דוגמאות: 10 = עשר דקות     3.4 = 3:40     3.45 = 3:45"
    $examples.Location = New-Object System.Drawing.Point(12, 91)
    $examples.Size = New-Object System.Drawing.Size(424, 24)
    $examples.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
    $examples.ForeColor = [System.Drawing.Color]::FromArgb(75, 90, 110)
    $examples.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $script:settingsPanel.Controls.Add($examples)

    $rule = New-Object System.Windows.Forms.Label
    $rule.Text = "עד 3.59 הסיומת נחשבת לשניות (3.59 = 3:59)." + [Environment]::NewLine + "מ-3.6 ומעלה מחשבים כחלקי דקה: 3.6 = 3:36; 3.75 = 3:45."
    $rule.Location = New-Object System.Drawing.Point(12, 115)
    $rule.Size = New-Object System.Drawing.Size(424, 45)
    $rule.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
    $rule.ForeColor = [System.Drawing.Color]::FromArgb(75, 90, 110)
    $rule.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $script:settingsPanel.Controls.Add($rule)

    $actionLabel = New-Object System.Windows.Forms.Label
    $actionLabel.Text = "מה לבצע כשהטיימר מסתיים?"
    $actionLabel.Location = New-Object System.Drawing.Point(18, 160)
    $actionLabel.Size = New-Object System.Drawing.Size(410, 24)
    $actionLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $actionLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $script:settingsPanel.Controls.Add($actionLabel)

    $script:sleepRadio = New-Object System.Windows.Forms.RadioButton
    $script:sleepRadio.Text = "שינה (ברירת מחדל)"
    $script:sleepRadio.Location = New-Object System.Drawing.Point(230, 185)
    $script:sleepRadio.Size = New-Object System.Drawing.Size(190, 25)
    $script:sleepRadio.Checked = $true
    $script:sleepRadio.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $script:settingsPanel.Controls.Add($script:sleepRadio)

    $script:shutdownRadio = New-Object System.Windows.Forms.RadioButton
    $script:shutdownRadio.Text = "כיבוי"
    $script:shutdownRadio.Location = New-Object System.Drawing.Point(65, 185)
    $script:shutdownRadio.Size = New-Object System.Drawing.Size(130, 25)
    $script:shutdownRadio.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $script:settingsPanel.Controls.Add($script:shutdownRadio)

    $script:shutdownWarning = New-Object System.Windows.Forms.Label
    $script:shutdownWarning.Text = "אזהרה: כיבוי עלול לסגור תוכנות ולגרום לאובדן נתונים שלא נשמרו!"
    $script:shutdownWarning.Location = New-Object System.Drawing.Point(12, 211)
    $script:shutdownWarning.Size = New-Object System.Drawing.Size(424, 29)
    $script:shutdownWarning.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
    $script:shutdownWarning.ForeColor = [System.Drawing.Color]::FromArgb(180, 45, 35)
    $script:shutdownWarning.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $script:settingsPanel.Controls.Add($script:shutdownWarning)

    $script:shutdownRadio.Add_CheckedChanged({
        if ($script:shutdownRadio.Checked) {
            $script:selectedAction = "shutdown"
        }
        else {
            $script:selectedAction = "sleep"
        }
    })

    $script:topCheck = New-Object System.Windows.Forms.CheckBox
    $script:topCheck.Text = "הצג חלון מעל שאר החלונות בשלב הסיום"
    $script:topCheck.Location = New-Object System.Drawing.Point(20, 246)
    $script:topCheck.Size = New-Object System.Drawing.Size(410, 25)
    $script:topCheck.Checked = $true
    $script:topCheck.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $script:settingsPanel.Controls.Add($script:topCheck)

    $script:soundCheck = New-Object System.Windows.Forms.CheckBox
    $script:soundCheck.Text = "השמע צליל התראה 30 שניות לפני סיום הטיימר"
    $script:soundCheck.Location = New-Object System.Drawing.Point(20, 273)
    $script:soundCheck.Size = New-Object System.Drawing.Size(410, 25)
    $script:soundCheck.Checked = $true
    $script:soundCheck.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $script:settingsPanel.Controls.Add($script:soundCheck)

    $script:startButton = New-Object System.Windows.Forms.Button
    $script:startButton.Text = "התחל טיימר"
    $script:startButton.Location = New-Object System.Drawing.Point(230, 310)
    $script:startButton.Size = New-Object System.Drawing.Size(176, 34)
    $script:startButton.BackColor = [System.Drawing.Color]::FromArgb(35, 105, 175)
    $script:startButton.ForeColor = [System.Drawing.Color]::White
    $script:startButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $script:startButton.FlatAppearance.BorderSize = 0
    $script:startButton.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $script:settingsPanel.Controls.Add($script:startButton)

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = "סגור"
    $closeButton.Location = New-Object System.Drawing.Point(40, 310)
    $closeButton.Size = New-Object System.Drawing.Size(166, 34)
    $closeButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $script:settingsPanel.Controls.Add($closeButton)

    # Countdown view is on the SAME form. The window is never hidden after Start.
    $script:countdownPanel = New-Object System.Windows.Forms.Panel
    $script:countdownPanel.Location = New-Object System.Drawing.Point(24, 98)
    $script:countdownPanel.Size = New-Object System.Drawing.Size(450, 355)
    $script:countdownPanel.BackColor = [System.Drawing.Color]::White
    $script:countdownPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $script:countdownPanel.Visible = $false
    $script:form.Controls.Add($script:countdownPanel)

    $script:countTitle = New-Object System.Windows.Forms.Label
    $script:countTitle.Text = "הזמן שנותר עד למצב שינה"
    $script:countTitle.Location = New-Object System.Drawing.Point(20, 28)
    $script:countTitle.Size = New-Object System.Drawing.Size(406, 35)
    $script:countTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $script:countTitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $script:countdownPanel.Controls.Add($script:countTitle)

    $script:countLabel = New-Object System.Windows.Forms.Label
    $script:countLabel.Text = "00:00"
    $script:countLabel.Location = New-Object System.Drawing.Point(20, 72)
    $script:countLabel.Size = New-Object System.Drawing.Size(406, 90)
    $script:countLabel.Font = New-Object System.Drawing.Font("Segoe UI", 34, [System.Drawing.FontStyle]::Bold)
    $script:countLabel.ForeColor = [System.Drawing.Color]::FromArgb(35, 70, 115)
    $script:countLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $script:countLabel.RightToLeft = [System.Windows.Forms.RightToLeft]::No
    $script:countdownPanel.Controls.Add($script:countLabel)

    $script:detailsLabel = New-Object System.Windows.Forms.Label
    $script:detailsLabel.Text = "משך התחלתי: 00:00  |  הארכות: 0"
    $script:detailsLabel.Location = New-Object System.Drawing.Point(20, 164)
    $script:detailsLabel.Size = New-Object System.Drawing.Size(406, 24)
    $script:detailsLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $script:detailsLabel.ForeColor = [System.Drawing.Color]::FromArgb(85, 95, 110)
    $script:detailsLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $script:countdownPanel.Controls.Add($script:detailsLabel)

    $script:limitLabel = New-Object System.Windows.Forms.Label
    $script:limitLabel.Text = "בשלב הסיום ניתן להוסיף שוב רק כשיישארו 20 שניות."
    $script:limitLabel.Location = New-Object System.Drawing.Point(20, 238)
    $script:limitLabel.Size = New-Object System.Drawing.Size(406, 22)
    $script:limitLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $script:limitLabel.ForeColor = [System.Drawing.Color]::FromArgb(100, 105, 115)
    $script:limitLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $script:countdownPanel.Controls.Add($script:limitLabel)

    $script:addButton = New-Object System.Windows.Forms.Button
    $script:addButton.Text = "הוסף 20 שניות"
    $script:addButton.Location = New-Object System.Drawing.Point(220, 190)
    $script:addButton.Size = New-Object System.Drawing.Size(185, 42)
    $script:addButton.BackColor = [System.Drawing.Color]::FromArgb(35, 105, 175)
    $script:addButton.ForeColor = [System.Drawing.Color]::White
    $script:addButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $script:addButton.FlatAppearance.BorderSize = 0
    $script:countdownPanel.Controls.Add($script:addButton)

    $script:addToolTip = New-Object System.Windows.Forms.ToolTip
    $script:addToolTip.SetToolTip($script:addButton, "בשלב הסיום אפשר להוסיף שוב רק כשנותרו 20 שניות או פחות.")

    $script:countdownMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $script:returnSettingsItem = New-Object System.Windows.Forms.ToolStripMenuItem("אפשרויות נוספות: חזרה לבחירת זמן...")
    [void]$script:countdownMenu.Items.Add($script:returnSettingsItem)

    $script:returnSettingsItem.Add_Click({
        if (-not $script:timerRunning) { return }
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "לחזור לבחירת הזמן? הטיימר הנוכחי יבוטל.",
            "חזרה לבחירת זמן",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            Return-ToSettings
        }
    })

    $script:cancelButton = New-Object System.Windows.Forms.Button
    $script:cancelButton.Text = "בטל טיימר"
    $script:cancelButton.Location = New-Object System.Drawing.Point(40, 190)
    $script:cancelButton.Size = New-Object System.Drawing.Size(165, 42)
    $script:cancelButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $script:countdownPanel.Controls.Add($script:cancelButton)

    foreach ($control in @(
        $script:countdownPanel,
        $script:countTitle,
        $script:countLabel,
        $script:detailsLabel,
        $script:limitLabel,
        $script:addButton,
        $script:cancelButton
    )) {
        $control.ContextMenuStrip = $script:countdownMenu
    }

    $script:status = New-Object System.Windows.Forms.Label
    $script:status.Text = "הטיימר עדיין לא הופעל."
    $script:status.Location = New-Object System.Drawing.Point(24, 455)
    $script:status.Size = New-Object System.Drawing.Size(450, 25)
    $script:status.ForeColor = [System.Drawing.Color]::FromArgb(85, 95, 110)
    $script:status.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $script:form.Controls.Add($script:status)

    function script:Update-DetailsLabel {
        $initialText = Format-Remaining $script:initialDurationSeconds
        $script:detailsLabel.Text = "משך התחלתי: $initialText  |  הארכות: $script:extensionCount"
    }

    function script:Return-ToSettings {
        $script:clock.Stop()
        $script:timerRunning = $false
        $script:latePhase = $false
        $script:addButton.Enabled = $true
        $script:form.TopMost = $false

        $script:form.MinimumSize = New-Object System.Drawing.Size(510, 525)
        $script:form.MaximumSize = New-Object System.Drawing.Size(510, 525)
        $script:form.Size = New-Object System.Drawing.Size(510, 525)
        $screenArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $restoreX = $screenArea.Left + [int](($screenArea.Width - $script:form.Width) / 2)
        $restoreY = $screenArea.Top + [int](($screenArea.Height - $script:form.Height) / 2)
        $script:form.Location = New-Object System.Drawing.Point($restoreX, $restoreY)
        $script:header.Visible = $true
        $script:status.Visible = $true
        $script:settingsPanel.Visible = $true
        $script:countdownPanel.Visible = $false

        $script:countdownPanel.Location = New-Object System.Drawing.Point(24, 98)
        $script:countdownPanel.Size = New-Object System.Drawing.Size(450, 355)
        $script:countTitle.Location = New-Object System.Drawing.Point(20, 28)
        $script:countTitle.Size = New-Object System.Drawing.Size(406, 35)
        $script:countTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
        $script:countLabel.Location = New-Object System.Drawing.Point(20, 72)
        $script:countLabel.Size = New-Object System.Drawing.Size(406, 90)
        $script:countLabel.Font = New-Object System.Drawing.Font("Segoe UI", 34, [System.Drawing.FontStyle]::Bold)
        $script:detailsLabel.Location = New-Object System.Drawing.Point(20, 164)
        $script:detailsLabel.Size = New-Object System.Drawing.Size(406, 24)
        $script:limitLabel.Location = New-Object System.Drawing.Point(20, 238)
        $script:limitLabel.Size = New-Object System.Drawing.Size(406, 22)
        $script:addButton.Location = New-Object System.Drawing.Point(220, 190)
        $script:addButton.Size = New-Object System.Drawing.Size(185, 42)
        $script:cancelButton.Visible = $false
        $script:status.Text = "הטיימר בוטל. אפשר לבחור זמן חדש."
    }

    $script:clock = New-Object System.Windows.Forms.Timer
    $script:clock.Interval = 200

    $script:clock.Add_Tick({
        if (-not $script:timerRunning) { return }

        try {
            $left = [int][math]::Ceiling(($script:deadlineUtc - [DateTime]::UtcNow).TotalSeconds)
            if ($left -lt 0) { $left = 0 }
            $script:remainingSeconds = $left
            $script:countLabel.Text = Format-Remaining $left

            # Enter the end phase once the original/extended timer reaches 20 seconds.
            if (-not $script:latePhase -and $left -le 20) {
                $script:latePhase = $true
            }

            if ($script:latePhase) {
                # After the end phase begins, one extension may raise the remaining time
                # to at most 40 seconds. The next extension is enabled only at <=20 seconds.
                $script:addButton.Enabled = ($left -le 20)
                if ($script:topCheck.Checked) {
                    $script:form.TopMost = $true
                }
                else {
                    $script:form.TopMost = $false
                }
            }
            else {
                $script:addButton.Enabled = $true
                $script:form.TopMost = $false
            }

            # The sound alert remains independent and plays at 30 seconds.
            if ($left -le 30) {
                if ($script:soundCheck.Checked -and -not $script:alertPlayed) {
                    $script:alertPlayed = $true
                    try { [System.Media.SystemSounds]::Exclamation.Play() } catch {}
                }
                $script:countLabel.ForeColor = [System.Drawing.Color]::FromArgb(190, 70, 45)
            }
            else {
                $script:countLabel.ForeColor = [System.Drawing.Color]::FromArgb(35, 70, 115)
            }

            if ($left -le 0) {
                $script:clock.Stop()
                $script:timerRunning = $false
                if ($script:selectedAction -eq "shutdown") {
                    $script:status.Text = "מכבה את המחשב..."
                }
                else {
                    $script:status.Text = "מכניס את המחשב למצב שינה..."
                }
                $script:form.TopMost = $false
                $script:form.Refresh()

                if ($script:selectedAction -eq "shutdown") {
                    # Normal Windows shutdown. No /f switch is used.
                    $shutdownExe = Join-Path $env:SystemRoot "System32\shutdown.exe"
                    & $shutdownExe /s /t 0
                    if ($LASTEXITCODE -ne 0) {
                        throw "Windows לא הצליח לבצע כיבוי. קוד שגיאה: $LASTEXITCODE"
                    }
                    $script:form.Close()
                    return
                }
                else {
                    $ok = [SleepTimerPower]::SetSuspendState($false, $false, $false)
                    if (-not $ok) {
                        $winError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                        throw "Windows לא הצליח להיכנס למצב שינה. קוד שגיאה: $winError"
                    }

                    # SetSuspendState returns after Windows wakes up again.
                    # Close the timer immediately so it is not left open after wake.
                    $script:status.Text = "המחשב התעורר; התוכנה נסגרת."
                    $script:form.Close()
                    return
                }
            }
        }
        catch {
            $script:clock.Stop()
            $script:timerRunning = $false
            $script:form.TopMost = $false
            $script:form.MinimumSize = New-Object System.Drawing.Size(510, 525)
            $script:form.MaximumSize = New-Object System.Drawing.Size(510, 525)
            $script:form.Size = New-Object System.Drawing.Size(510, 525)
            $script:header.Visible = $true
            $script:status.Visible = $true
            $script:settingsPanel.Visible = $true
            $script:countdownPanel.Visible = $false
            $script:countdownPanel.Location = New-Object System.Drawing.Point(24, 98)
            $script:countdownPanel.Size = New-Object System.Drawing.Size(450, 355)
            $script:countTitle.Location = New-Object System.Drawing.Point(20, 28)
            $script:countTitle.Size = New-Object System.Drawing.Size(406, 35)
            $script:countTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
            $script:countLabel.Location = New-Object System.Drawing.Point(20, 72)
            $script:countLabel.Size = New-Object System.Drawing.Size(406, 90)
            $script:countLabel.Font = New-Object System.Drawing.Font("Segoe UI", 34, [System.Drawing.FontStyle]::Bold)
            $script:addButton.Location = New-Object System.Drawing.Point(220, 190)
            $script:addButton.Size = New-Object System.Drawing.Size(185, 42)
            $script:cancelButton.Location = New-Object System.Drawing.Point(40, 190)
            $script:cancelButton.Size = New-Object System.Drawing.Size(165, 42)
            $script:status.Text = "הטיימר נעצר עקב שגיאה."
            [System.Windows.Forms.MessageBox]::Show(
                $_.Exception.Message,
                "שגיאה בטיימר",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
    })

    $script:startButton.Add_Click({
        try {
            $seconds = Convert-TimeInput $script:timeBox.Text
            $script:remainingSeconds = $seconds
            $script:initialDurationSeconds = $seconds
            $script:extensionCount = 0
            $script:latePhase = $false
            $script:deadlineUtc = [DateTime]::UtcNow.AddSeconds($seconds)
            $script:alertPlayed = $false
            $script:timerRunning = $true
            $script:addButton.Enabled = $true
            Update-DetailsLabel
            $script:form.TopMost = $false
            $script:countLabel.ForeColor = [System.Drawing.Color]::FromArgb(35, 70, 115)
            $script:countLabel.Text = Format-Remaining $seconds
            if ($script:shutdownRadio.Checked) {
                $script:selectedAction = "shutdown"
                $script:countTitle.Text = "הזמן שנותר עד לכיבוי המחשב"
            }
            else {
                $script:selectedAction = "sleep"
                $script:countTitle.Text = "הזמן שנותר עד למצב שינה"
            }
            $script:settingsPanel.Visible = $false
            $script:countdownPanel.Visible = $true

            # Switch to a small compact timer window instead of keeping the large settings window.
            $script:form.MinimumSize = New-Object System.Drawing.Size(390, 240)
            $script:form.MaximumSize = New-Object System.Drawing.Size(390, 240)
            $script:form.Size = New-Object System.Drawing.Size(390, 240)
            $screenArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
            $smallX = $screenArea.Left + [int](($screenArea.Width - $script:form.Width) / 2)
            $smallY = $screenArea.Top + [int](($screenArea.Height - $script:form.Height) / 2)
            $script:form.Location = New-Object System.Drawing.Point($smallX, $smallY)
            $script:header.Visible = $false
            $script:status.Visible = $false
            $script:countdownPanel.Location = New-Object System.Drawing.Point(8, 8)
            $script:countdownPanel.Size = New-Object System.Drawing.Size(358, 185)
            $script:countTitle.Location = New-Object System.Drawing.Point(10, 5)
            $script:countTitle.Size = New-Object System.Drawing.Size(334, 24)
            $script:countTitle.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
            $script:countLabel.Location = New-Object System.Drawing.Point(10, 29)
            $script:countLabel.Size = New-Object System.Drawing.Size(334, 48)
            $script:countLabel.Font = New-Object System.Drawing.Font("Segoe UI", 25, [System.Drawing.FontStyle]::Bold)
            $script:detailsLabel.Location = New-Object System.Drawing.Point(10, 78)
            $script:detailsLabel.Size = New-Object System.Drawing.Size(334, 24)
            $script:limitLabel.Location = New-Object System.Drawing.Point(10, 151)
            $script:limitLabel.Size = New-Object System.Drawing.Size(334, 22)
            $script:addButton.Location = New-Object System.Drawing.Point(104, 112)
            $script:addButton.Size = New-Object System.Drawing.Size(150, 35)
            $script:cancelButton.Visible = $false

            $script:status.Text = "הטיימר פועל."
            $script:clock.Start()
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                $_.Exception.Message,
                "בדיקת זמן",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        }
    })

    $script:addButton.Add_Click({
        if ($script:timerRunning) {
            $rawLeftNow = ($script:deadlineUtc - [DateTime]::UtcNow).TotalSeconds

            # If the user clicks exactly as the final 20-second phase begins,
            # latch the phase here too (not only on the next timer tick).
            if (-not $script:latePhase -and $rawLeftNow -le 20) {
                $script:latePhase = $true
            }

            # During the end phase, extensions are only allowed at <=20 seconds.
            # Each click can therefore raise the remaining time to at most 40 seconds.
            if ($script:latePhase -and $rawLeftNow -gt 20) {
                $script:addButton.Enabled = $false
                return
            }

            $script:deadlineUtc = $script:deadlineUtc.AddSeconds(20)
            $script:extensionCount++
            $script:alertPlayed = $false
            Update-DetailsLabel

            $left = [int][math]::Ceiling(($script:deadlineUtc - [DateTime]::UtcNow).TotalSeconds)
            $script:countLabel.Text = Format-Remaining $left

            if ($script:latePhase) {
                $script:addButton.Enabled = $false
                $script:status.Text = "נוספו 20 שניות. אפשר להוסיף שוב כשייוותרו 20 שניות."
            }
            else {
                $script:status.Text = "נוספו 20 שניות."
            }
        }
    })

    $script:cancelButton.Add_Click({ Return-ToSettings })

$closeButton.Add_Click({ $script:form.Close() })

    $script:form.Add_FormClosing({
        if ($script:timerRunning) {
            $script:clock.Stop()
            $script:timerRunning = $false
        }
    })

    [void]$script:form.ShowDialog()
}
catch {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.ToString(),
            "שגיאה בהפעלת טיימר השינה",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    catch {
        Write-Error $_
        Read-Host "הקש Enter לסגירה" | Out-Null
    }
}
