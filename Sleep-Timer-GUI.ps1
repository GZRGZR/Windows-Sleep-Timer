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

    # Main window
    $script:form = New-Object System.Windows.Forms.Form
    $script:form.Text = "טיימר למצב שינה"
    $script:form.Size = New-Object System.Drawing.Size(510, 470)
    $script:form.MinimumSize = New-Object System.Drawing.Size(510, 470)
    $script:form.MaximumSize = New-Object System.Drawing.Size(510, 470)
    $script:form.StartPosition = "CenterScreen"
    $script:form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $script:form.MaximizeBox = $false
    $script:form.BackColor = [System.Drawing.Color]::FromArgb(246, 248, 252)
    $script:form.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $script:form.RightToLeft = [System.Windows.Forms.RightToLeft]::Yes
    $script:form.RightToLeftLayout = $true

    $header = New-Object System.Windows.Forms.Panel
    $header.Location = New-Object System.Drawing.Point(0, 0)
    $header.Size = New-Object System.Drawing.Size(510, 82)
    $header.BackColor = [System.Drawing.Color]::FromArgb(35, 70, 115)
    $script:form.Controls.Add($header)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = "טיימר למצב שינה"
    $title.ForeColor = [System.Drawing.Color]::White
    $title.Font = New-Object System.Drawing.Font("Segoe UI", 19, [System.Drawing.FontStyle]::Bold)
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(275, 12)
    $header.Controls.Add($title)

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = "קובעים זמן – ובסיומו המחשב נכנס למצב שינה"
    $subtitle.ForeColor = [System.Drawing.Color]::FromArgb(225, 235, 248)
    $subtitle.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $subtitle.AutoSize = $true
    $subtitle.Location = New-Object System.Drawing.Point(145, 51)
    $header.Controls.Add($subtitle)

    # Settings view
    $script:settingsPanel = New-Object System.Windows.Forms.Panel
    $script:settingsPanel.Location = New-Object System.Drawing.Point(24, 98)
    $script:settingsPanel.Size = New-Object System.Drawing.Size(450, 305)
    $script:settingsPanel.BackColor = [System.Drawing.Color]::White
    $script:settingsPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $script:form.Controls.Add($script:settingsPanel)

    $prompt = New-Object System.Windows.Forms.Label
    $prompt.Text = "כמה זמן עד שהמחשב ייכנס למצב שינה?"
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

    $script:topCheck = New-Object System.Windows.Forms.CheckBox
    $script:topCheck.Text = "הצג חלון מעל שאר החלונות רק ב-20 השניות האחרונות"
    $script:topCheck.Location = New-Object System.Drawing.Point(20, 167)
    $script:topCheck.Size = New-Object System.Drawing.Size(410, 25)
    $script:topCheck.Checked = $true
    $script:topCheck.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $script:settingsPanel.Controls.Add($script:topCheck)

    $script:soundCheck = New-Object System.Windows.Forms.CheckBox
    $script:soundCheck.Text = "השמע צליל התראה 30 שניות לפני השינה"
    $script:soundCheck.Location = New-Object System.Drawing.Point(20, 196)
    $script:soundCheck.Size = New-Object System.Drawing.Size(410, 25)
    $script:soundCheck.Checked = $true
    $script:soundCheck.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $script:settingsPanel.Controls.Add($script:soundCheck)

    $script:startButton = New-Object System.Windows.Forms.Button
    $script:startButton.Text = "התחל טיימר"
    $script:startButton.Location = New-Object System.Drawing.Point(230, 248)
    $script:startButton.Size = New-Object System.Drawing.Size(176, 34)
    $script:startButton.BackColor = [System.Drawing.Color]::FromArgb(35, 105, 175)
    $script:startButton.ForeColor = [System.Drawing.Color]::White
    $script:startButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $script:startButton.FlatAppearance.BorderSize = 0
    $script:startButton.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $script:settingsPanel.Controls.Add($script:startButton)

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = "סגור"
    $closeButton.Location = New-Object System.Drawing.Point(40, 248)
    $closeButton.Size = New-Object System.Drawing.Size(166, 34)
    $closeButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $script:settingsPanel.Controls.Add($closeButton)

    # Countdown view is on the SAME form. The window is never hidden after Start.
    $script:countdownPanel = New-Object System.Windows.Forms.Panel
    $script:countdownPanel.Location = New-Object System.Drawing.Point(24, 98)
    $script:countdownPanel.Size = New-Object System.Drawing.Size(450, 305)
    $script:countdownPanel.BackColor = [System.Drawing.Color]::White
    $script:countdownPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $script:countdownPanel.Visible = $false
    $script:form.Controls.Add($script:countdownPanel)

    $countTitle = New-Object System.Windows.Forms.Label
    $countTitle.Text = "הזמן שנותר עד למצב שינה"
    $countTitle.Location = New-Object System.Drawing.Point(20, 28)
    $countTitle.Size = New-Object System.Drawing.Size(406, 35)
    $countTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $countTitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $script:countdownPanel.Controls.Add($countTitle)

    $script:countLabel = New-Object System.Windows.Forms.Label
    $script:countLabel.Text = "00:00"
    $script:countLabel.Location = New-Object System.Drawing.Point(20, 72)
    $script:countLabel.Size = New-Object System.Drawing.Size(406, 90)
    $script:countLabel.Font = New-Object System.Drawing.Font("Segoe UI", 34, [System.Drawing.FontStyle]::Bold)
    $script:countLabel.ForeColor = [System.Drawing.Color]::FromArgb(35, 70, 115)
    $script:countLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $script:countLabel.RightToLeft = [System.Windows.Forms.RightToLeft]::No
    $script:countdownPanel.Controls.Add($script:countLabel)

    $script:addButton = New-Object System.Windows.Forms.Button
    $script:addButton.Text = "הוסף 20 שניות"
    $script:addButton.Location = New-Object System.Drawing.Point(220, 190)
    $script:addButton.Size = New-Object System.Drawing.Size(185, 42)
    $script:addButton.BackColor = [System.Drawing.Color]::FromArgb(35, 105, 175)
    $script:addButton.ForeColor = [System.Drawing.Color]::White
    $script:addButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $script:addButton.FlatAppearance.BorderSize = 0
    $script:countdownPanel.Controls.Add($script:addButton)

    $script:cancelButton = New-Object System.Windows.Forms.Button
    $script:cancelButton.Text = "בטל טיימר"
    $script:cancelButton.Location = New-Object System.Drawing.Point(40, 190)
    $script:cancelButton.Size = New-Object System.Drawing.Size(165, 42)
    $script:cancelButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $script:countdownPanel.Controls.Add($script:cancelButton)

    $script:status = New-Object System.Windows.Forms.Label
    $script:status.Text = "הטיימר עדיין לא הופעל."
    $script:status.Location = New-Object System.Drawing.Point(24, 410)
    $script:status.Size = New-Object System.Drawing.Size(450, 25)
    $script:status.ForeColor = [System.Drawing.Color]::FromArgb(85, 95, 110)
    $script:status.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $script:form.Controls.Add($script:status)

    $script:clock = New-Object System.Windows.Forms.Timer
    $script:clock.Interval = 200

    $script:clock.Add_Tick({
        if (-not $script:timerRunning) { return }

        try {
            $left = [int][math]::Ceiling(($script:deadlineUtc - [DateTime]::UtcNow).TotalSeconds)
            if ($left -lt 0) { $left = 0 }
            $script:remainingSeconds = $left
            $script:countLabel.Text = Format-Remaining $left

            # Bring the compact countdown window forward only during the final 20 seconds.
            if ($left -le 20 -and $script:topCheck.Checked) {
                if (-not $script:form.TopMost) {
                    $script:form.TopMost = $true
                    $script:form.BringToFront()
                    $script:form.Activate()
                }
            }
            elseif ($script:form.TopMost) {
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
                $script:status.Text = "מכניס את המחשב למצב שינה..."
                $script:form.TopMost = $false
                $script:form.Refresh()

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
        catch {
            $script:clock.Stop()
            $script:timerRunning = $false
            $script:form.TopMost = $false
            $script:settingsPanel.Visible = $true
            $script:countdownPanel.Visible = $false
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
            $script:deadlineUtc = [DateTime]::UtcNow.AddSeconds($seconds)
            $script:alertPlayed = $false
            $script:timerRunning = $true
            $script:form.TopMost = $false
            $script:countLabel.ForeColor = [System.Drawing.Color]::FromArgb(35, 70, 115)
            $script:countLabel.Text = Format-Remaining $seconds
            $script:settingsPanel.Visible = $false
            $script:countdownPanel.Visible = $true

            # Switch to a small compact timer window instead of keeping the large settings window.
            $script:form.MinimumSize = New-Object System.Drawing.Size(370, 205)
            $script:form.MaximumSize = New-Object System.Drawing.Size(370, 205)
            $script:form.Size = New-Object System.Drawing.Size(370, 205)
            $header.Visible = $false
            $script:status.Visible = $false
            $script:countdownPanel.Location = New-Object System.Drawing.Point(8, 8)
            $script:countdownPanel.Size = New-Object System.Drawing.Size(338, 148)
            $countTitle.Location = New-Object System.Drawing.Point(10, 6)
            $countTitle.Size = New-Object System.Drawing.Size(314, 24)
            $countTitle.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
            $script:countLabel.Location = New-Object System.Drawing.Point(10, 30)
            $script:countLabel.Size = New-Object System.Drawing.Size(314, 52)
            $script:countLabel.Font = New-Object System.Drawing.Font("Segoe UI", 26, [System.Drawing.FontStyle]::Bold)
            $script:addButton.Location = New-Object System.Drawing.Point(174, 93)
            $script:addButton.Size = New-Object System.Drawing.Size(140, 35)
            $script:cancelButton.Location = New-Object System.Drawing.Point(18, 93)
            $script:cancelButton.Size = New-Object System.Drawing.Size(140, 35)

            $screenArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
            $script:form.Location = New-Object System.Drawing.Point(
                ($screenArea.Left + [int](($screenArea.Width - $script:form.Width) / 2)),
                ($screenArea.Top + [int](($screenArea.Height - $script:form.Height) / 2))
            )
            $script:status.Text = "הטיימר פועל. אפשר להוסיף 20 שניות או לבטל."
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
            $script:deadlineUtc = $script:deadlineUtc.AddSeconds(20)
            $script:alertPlayed = $false
            $script:form.TopMost = $false
            $script:countLabel.ForeColor = [System.Drawing.Color]::FromArgb(35, 70, 115)
            $left = [int][math]::Ceiling(($script:deadlineUtc - [DateTime]::UtcNow).TotalSeconds)
            $script:countLabel.Text = Format-Remaining $left
            $script:status.Text = "נוספו 20 שניות."
        }
    })

    $script:cancelButton.Add_Click({
        $script:clock.Stop()
        $script:timerRunning = $false
        $script:form.TopMost = $false
        $script:countdownPanel.Visible = $false
        $script:settingsPanel.Visible = $true

        # Restore the full settings window after cancellation.
        $script:form.MinimumSize = New-Object System.Drawing.Size(510, 470)
        $script:form.MaximumSize = New-Object System.Drawing.Size(510, 470)
        $script:form.Size = New-Object System.Drawing.Size(510, 470)
        $header.Visible = $true
        $script:status.Visible = $true
        $script:countdownPanel.Location = New-Object System.Drawing.Point(24, 98)
        $script:countdownPanel.Size = New-Object System.Drawing.Size(450, 305)
        $countTitle.Location = New-Object System.Drawing.Point(20, 28)
        $countTitle.Size = New-Object System.Drawing.Size(406, 35)
        $countTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
        $script:countLabel.Location = New-Object System.Drawing.Point(20, 72)
        $script:countLabel.Size = New-Object System.Drawing.Size(406, 90)
        $script:countLabel.Font = New-Object System.Drawing.Font("Segoe UI", 34, [System.Drawing.FontStyle]::Bold)
        $script:addButton.Location = New-Object System.Drawing.Point(220, 190)
        $script:addButton.Size = New-Object System.Drawing.Size(185, 42)
        $script:cancelButton.Location = New-Object System.Drawing.Point(40, 190)
        $script:cancelButton.Size = New-Object System.Drawing.Size(165, 42)

        $script:status.Text = "הטיימר בוטל. המחשב לא ייכנס למצב שינה."
    })

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
