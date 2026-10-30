$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SleepTimerPower {
    [DllImport("powrprof.dll", SetLastError = true)]
    public static extern bool SetSuspendState(bool hibernate, bool forceCritical, bool disableWakeEvent);
}
'@

function Convert-TimeInput([string]$text) {
    $s = ($text.Trim() -replace ',', '.')
    if ($s -notmatch '^\d+(\.\d+)?$') {
        throw "יש להזין מספר בלבד, לדוגמה 10 או 3.4"
    }

    $parts = $s.Split('.')
    $wholeMinutes = [int]$parts[0]
    $extraSeconds = 0

    if ($parts.Length -gt 1) {
        $fraction = [double]::Parse("0.$($parts[1])", [Globalization.CultureInfo]::InvariantCulture)

        # עד 0.59: הספרות אחרי הנקודה מייצגות שניות (3.4 = 40 שניות; 3.45 = 45).
        # מעל 0.59: מפרשים את הסיומת כחלקי דקה (3.6 = 36 שניות; 3.75 = 45).
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

function Format-Remaining([int]$seconds) {
    $span = [TimeSpan]::FromSeconds([math]::Max(0, $seconds))
    return ("{0:00}:{1:00}" -f [math]::Floor($span.TotalMinutes), $span.Seconds)
}

# חלון ההגדרות
$form = New-Object System.Windows.Forms.Form
$form.Text = "טיימר למצב שינה"
$form.Size = New-Object System.Drawing.Size(500, 465)
$form.MinimumSize = New-Object System.Drawing.Size(500, 465)
$form.MaximumSize = New-Object System.Drawing.Size(500, 465)
$form.StartPosition = "CenterScreen"
$form.BackColor = [System.Drawing.Color]::FromArgb(246, 248, 252)
$form.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$form.RightToLeft = [System.Windows.Forms.RightToLeft]::Yes
$form.RightToLeftLayout = $true

$header = New-Object System.Windows.Forms.Panel
$header.Location = New-Object System.Drawing.Point(0, 0)
$header.Size = New-Object System.Drawing.Size(500, 82)
$header.BackColor = [System.Drawing.Color]::FromArgb(35, 70, 115)
$form.Controls.Add($header)

$title = New-Object System.Windows.Forms.Label
$title.Text = "טיימר למצב שינה"
$title.ForeColor = [System.Drawing.Color]::White
$title.Font = New-Object System.Drawing.Font("Segoe UI", 19, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(270, 12)
$header.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = "קובעים זמן – ובסיומו המחשב נכנס למצב שינה"
$subtitle.ForeColor = [System.Drawing.Color]::FromArgb(225, 235, 248)
$subtitle.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$subtitle.AutoSize = $true
$subtitle.Location = New-Object System.Drawing.Point(145, 51)
$header.Controls.Add($subtitle)

$card = New-Object System.Windows.Forms.Panel
$card.Location = New-Object System.Drawing.Point(24, 98)
$card.Size = New-Object System.Drawing.Size(440, 305)
$card.BackColor = [System.Drawing.Color]::White
$card.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$form.Controls.Add($card)

$prompt = New-Object System.Windows.Forms.Label
$prompt.Text = "כמה זמן עד שהמחשב ייכנס למצב שינה?"
$prompt.Location = New-Object System.Drawing.Point(22, 15)
$prompt.Size = New-Object System.Drawing.Size(394, 28)
$prompt.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$prompt.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$card.Controls.Add($prompt)

$timeBox = New-Object System.Windows.Forms.TextBox
$timeBox.Location = New-Object System.Drawing.Point(40, 49)
$timeBox.Size = New-Object System.Drawing.Size(356, 37)
$timeBox.Font = New-Object System.Drawing.Font("Segoe UI", 16)
$timeBox.TextAlign = [System.Windows.Forms.HorizontalAlignment]::Center
$timeBox.Text = "10"
$timeBox.RightToLeft = [System.Windows.Forms.RightToLeft]::No
$card.Controls.Add($timeBox)

$examples = New-Object System.Windows.Forms.Label
$examples.Text = "דוגמאות: 10 = עשר דקות     3.4 = 3:40     3.45 = 3:45"
$examples.Location = New-Object System.Drawing.Point(12, 91)
$examples.Size = New-Object System.Drawing.Size(414, 24)
$examples.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$examples.ForeColor = [System.Drawing.Color]::FromArgb(75, 90, 110)
$examples.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$card.Controls.Add($examples)

$rule = New-Object System.Windows.Forms.Label
$rule.Text = "חשוב: עד 3.59 הסיומת נחשבת לשניות (3.59 = 3:59)." + [Environment]::NewLine + "מ-3.6 ומעלה מחשבים כחלקי דקה: 3.6 = 3:36; 3.75 = 3:45."
$rule.Location = New-Object System.Drawing.Point(12, 115)
$rule.Size = New-Object System.Drawing.Size(414, 45)
$rule.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$rule.ForeColor = [System.Drawing.Color]::FromArgb(75, 90, 110)
$rule.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$card.Controls.Add($rule)

$topCheck = New-Object System.Windows.Forms.CheckBox
$topCheck.Text = "הצג חלון צף מעל שאר החלונות ב-30 השניות האחרונות"
$topCheck.Location = New-Object System.Drawing.Point(20, 167)
$topCheck.Size = New-Object System.Drawing.Size(405, 25)
$topCheck.Checked = $true
$topCheck.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$card.Controls.Add($topCheck)

$soundCheck = New-Object System.Windows.Forms.CheckBox
$soundCheck.Text = "השמע צליל התראה 30 שניות לפני השינה"
$soundCheck.Location = New-Object System.Drawing.Point(20, 196)
$soundCheck.Size = New-Object System.Drawing.Size(405, 25)
$soundCheck.Checked = $true
$soundCheck.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$card.Controls.Add($soundCheck)

$startButton = New-Object System.Windows.Forms.Button
$startButton.Text = "התחל טיימר"
$startButton.Location = New-Object System.Drawing.Point(230, 248)
$startButton.Size = New-Object System.Drawing.Size(166, 34)
$startButton.BackColor = [System.Drawing.Color]::FromArgb(35, 105, 175)
$startButton.ForeColor = [System.Drawing.Color]::White
$startButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$startButton.FlatAppearance.BorderSize = 0
$startButton.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$card.Controls.Add($startButton)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = "סגור"
$closeButton.Location = New-Object System.Drawing.Point(40, 248)
$closeButton.Size = New-Object System.Drawing.Size(166, 34)
$closeButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$card.Controls.Add($closeButton)

$status = New-Object System.Windows.Forms.Label
$status.Text = "הטיימר עדיין לא הופעל."
$status.Location = New-Object System.Drawing.Point(25, 410)
$status.Size = New-Object System.Drawing.Size(440, 25)
$status.ForeColor = [System.Drawing.Color]::FromArgb(85, 95, 110)
$status.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$form.Controls.Add($status)

# חלון הספירה לאחור
$countForm = New-Object System.Windows.Forms.Form
$countForm.Text = "הטיימר פועל"
$countForm.Size = New-Object System.Drawing.Size(410, 245)
$countForm.MinimumSize = New-Object System.Drawing.Size(410, 245)
$countForm.MaximumSize = New-Object System.Drawing.Size(410, 245)
$countForm.StartPosition = "CenterScreen"
$countForm.BackColor = [System.Drawing.Color]::FromArgb(246, 248, 252)
$countForm.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$countForm.RightToLeft = [System.Windows.Forms.RightToLeft]::Yes
$countForm.RightToLeftLayout = $true
$countForm.ShowInTaskbar = $true

$countTitle = New-Object System.Windows.Forms.Label
$countTitle.Text = "המחשב ייכנס למצב שינה בעוד"
$countTitle.Location = New-Object System.Drawing.Point(20, 13)
$countTitle.Size = New-Object System.Drawing.Size(355, 30)
$countTitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$countTitle.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$countForm.Controls.Add($countTitle)

$countLabel = New-Object System.Windows.Forms.Label
$countLabel.Text = "00:00"
$countLabel.Location = New-Object System.Drawing.Point(20, 47)
$countLabel.Size = New-Object System.Drawing.Size(355, 72)
$countLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$countLabel.Font = New-Object System.Drawing.Font("Segoe UI", 31, [System.Drawing.FontStyle]::Bold)
$countLabel.ForeColor = [System.Drawing.Color]::FromArgb(35, 70, 115)
$countLabel.RightToLeft = [System.Windows.Forms.RightToLeft]::No
$countForm.Controls.Add($countLabel)

$addButton = New-Object System.Windows.Forms.Button
$addButton.Text = "הוסף 20 שניות"
$addButton.Location = New-Object System.Drawing.Point(195, 137)
$addButton.Size = New-Object System.Drawing.Size(180, 39)
$addButton.BackColor = [System.Drawing.Color]::FromArgb(35, 105, 175)
$addButton.ForeColor = [System.Drawing.Color]::White
$addButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$addButton.FlatAppearance.BorderSize = 0
$countForm.Controls.Add($addButton)

$stopButton = New-Object System.Windows.Forms.Button
$stopButton.Text = "בטל טיימר"
$stopButton.Location = New-Object System.Drawing.Point(20, 137)
$stopButton.Size = New-Object System.Drawing.Size(160, 39)
$stopButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$countForm.Controls.Add($stopButton)

$countNote = New-Object System.Windows.Forms.Label
$countNote.Text = "כל לחיצה מוסיפה 20 שניות. אפשר לבטל בכל עת."
$countNote.Location = New-Object System.Drawing.Point(15, 184)
$countNote.Size = New-Object System.Drawing.Size(360, 24)
$countNote.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$countNote.ForeColor = [System.Drawing.Color]::FromArgb(90, 100, 115)
$countNote.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$countForm.Controls.Add($countNote)

$script:remaining = 0
$script:timerRunning = $false
$script:alertPlayed = $false

$clock = New-Object System.Windows.Forms.Timer
$clock.Interval = 1000

$clock.Add_Tick({
    if (-not $script:timerRunning) { return }

    $script:remaining--
    if ($script:remaining -lt 0) { $script:remaining = 0 }
    $countLabel.Text = Format-Remaining $script:remaining

    if ($script:remaining -le 30) {
        if ($topCheck.Checked) {
            if ($countForm.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
                $countForm.WindowState = [System.Windows.Forms.FormWindowState]::Normal
            }
            if (-not $countForm.TopMost) {
                $countForm.TopMost = $true
                $countForm.Show()
                $countForm.BringToFront()
                $countForm.Activate()
            }
        }

        if ($soundCheck.Checked -and -not $script:alertPlayed) {
            $script:alertPlayed = $true
            try { [System.Media.SystemSounds]::Exclamation.Play() } catch {}
        }
        $countLabel.ForeColor = [System.Drawing.Color]::FromArgb(190, 70, 45)
    }

    if ($script:remaining -gt 30 -and $countForm.TopMost) {
        $countForm.TopMost = $false
        $countLabel.ForeColor = [System.Drawing.Color]::FromArgb(35, 70, 115)
    }

    if ($script:remaining -le 0) {
        $clock.Stop()
        $script:timerRunning = $false
        $countForm.Hide()
        $form.Hide()
        try {
            $ok = [SleepTimerPower]::SetSuspendState($false, $false, $false)
            if (-not $ok) { throw "Windows לא הצליח להיכנס למצב שינה." }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "לא ניתן היה להכניס את המחשב למצב שינה." + [Environment]::NewLine + $_.Exception.Message,
                "שגיאה",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
            $form.Show()
        }
    }
})

$addButton.Add_Click({
    if ($script:timerRunning) {
        $script:remaining += 20
        $countLabel.Text = Format-Remaining $script:remaining
        if ($script:remaining -gt 30) {
            $countForm.TopMost = $false
            $countLabel.ForeColor = [System.Drawing.Color]::FromArgb(35, 70, 115)
            $script:alertPlayed = $false
        }
    }
})

$stopButton.Add_Click({
    $clock.Stop()
    $script:timerRunning = $false
    $countForm.Hide()
    $countForm.TopMost = $false
    $form.Show()
    $status.Text = "הטיימר בוטל. המחשב לא ייכנס למצב שינה."
})

$countForm.Add_FormClosing({
    if ($script:timerRunning) {
        $clock.Stop()
        $script:timerRunning = $false
        $countForm.TopMost = $false
        if (-not $form.IsDisposed) {
            $form.Show()
            $status.Text = "הטיימר בוטל. המחשב לא ייכנס למצב שינה."
        }
    }
})

$startButton.Add_Click({
    try {
        $script:remaining = Convert-TimeInput $timeBox.Text
        $script:alertPlayed = $false
        $script:timerRunning = $true
        $countForm.TopMost = $false
        $countLabel.ForeColor = [System.Drawing.Color]::FromArgb(35, 70, 115)
        $countLabel.Text = Format-Remaining $script:remaining
        $form.Hide()
        $countForm.Show()
        $clock.Start()
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

$closeButton.Add_Click({ $form.Close() })
$form.Add_FormClosing({
    if ($script:timerRunning) {
        $clock.Stop()
        $script:timerRunning = $false
    }
})

[void]$form.ShowDialog()
