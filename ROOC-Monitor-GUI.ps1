<#
    ROOC-Monitor-GUI.ps1
    หน้าจอเฝ้าสถานะออนไลน์ของ Ragnarok Origin Classic

    ใช้สัญญาณเดียวกับ Watch-RoocOnline.ps1 คือดูว่า rooc.exe ยังมี TCP ค้างกับ gate server อยู่ไหม
    ต่างกันแค่ตัวนี้มีหน้าจอ ย่อลง tray ได้ และตั้งค่าได้จากในหน้าต่างเลย

    งานที่ช้า (ยิง notification, เช็คเน็ต) ทำแบบ async ทั้งหมด UI จะได้ไม่ค้าง
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http

try {
    Add-Type -Namespace Win -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetProcessDPIAware();
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@
} catch { }

# ไม่ทำ DPI awareness แล้วตัวหนังสือจะเบลอบนจอความละเอียดสูง
try { [Win.Native]::SetProcessDPIAware() | Out-Null } catch { }

# ซ่อน console ของตัวเอง แทนการใช้ -WindowStyle Hidden ตอนเรียก
# เพราะ -WindowStyle Hidden จะไปตั้ง nCmdShow ของทั้ง process ทำให้ฟอร์มโดนซ่อนตามไปด้วย
try {
    $con = [Win.Native]::GetConsoleWindow()
    if ($con -ne [System.IntPtr]::Zero) { [Win.Native]::ShowWindow($con, 0) | Out-Null }
} catch { }

[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------- ค่าคงที่

$ConfigPath  = Join-Path $PSScriptRoot 'config.json'
$LogPath     = Join-Path $PSScriptRoot 'rooc-online.log'
$GameExe     = 'C:\Program Files (x86)\roocalive\exe\rooc.exe'
$IgnorePorts = @(80, 443, 8080)

$C = @{
    Bg        = [System.Drawing.Color]::FromArgb(22, 22, 30)
    Panel     = [System.Drawing.Color]::FromArgb(31, 32, 41)
    PanelHi   = [System.Drawing.Color]::FromArgb(38, 40, 51)
    Border    = [System.Drawing.Color]::FromArgb(48, 50, 64)
    Text      = [System.Drawing.Color]::FromArgb(228, 230, 240)
    Muted     = [System.Drawing.Color]::FromArgb(139, 143, 163)
    Green     = [System.Drawing.Color]::FromArgb(63, 214, 140)
    Red       = [System.Drawing.Color]::FromArgb(255, 107, 107)
    Amber     = [System.Drawing.Color]::FromArgb(255, 198, 92)
    Blue      = [System.Drawing.Color]::FromArgb(122, 162, 247)
    Faint     = [System.Drawing.Color]::FromArgb(104, 108, 128)
}

$FontFamily = if ((New-Object System.Drawing.FontFamily('Leelawadee UI')).Name -eq 'Leelawadee UI') { 'Leelawadee UI' } else { 'Segoe UI' }
function NewFont { param([single]$Size, [string]$Style = 'Regular')
    [System.Drawing.Font]::new($FontFamily, $Size, [System.Drawing.FontStyle]$Style)
}

# ---------------------------------------------------------------- config

$DefaultConfig = [ordered]@{
    NtfyTopic      = ''
    NtfyServer     = 'https://ntfy.sh'
    WebhookUrl     = ''
    TelegramToken  = ''
    TelegramChatId = ''
    IntervalSec    = 30
    GraceChecks    = 3
    RepeatAlertMin = 3
    MaxRepeats     = 20
    HeartbeatHours = 4
    Sound          = $false
    AutoStart      = $true
}

function Load-Config {
    $cfg = [ordered]@{}
    $DefaultConfig.GetEnumerator() | ForEach-Object { $cfg[$_.Key] = $_.Value }
    if (Test-Path $ConfigPath) {
        try {
            $saved = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @($cfg.Keys)) {
                if ($null -ne $saved.$k) { $cfg[$k] = $saved.$k }
            }
        } catch { }
    }
    return $cfg
}

function Save-Config {
    param($Cfg)
    try {
        ($Cfg | ConvertTo-Json) | Out-File -FilePath $ConfigPath -Encoding utf8 -Force
    } catch { }
}

$script:cfg = Load-Config

# ---------------------------------------------------------------- ตรวจจับ

# socket เกม = ไม่ใช่ localhost และไม่ใช่พอร์ตเว็บ
function Get-ClientStatus {
    $out = @()
    foreach ($p in @(Get-Process -Name rooc -ErrorAction SilentlyContinue)) {
        $conns = @(
            Get-NetTCPConnection -OwningProcess $p.Id -State Established -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.RemoteAddress -notmatch '^(127\.|::1$|0\.0\.0\.0)' -and
                    $IgnorePorts -notcontains $_.RemotePort
                }
        )
        $started = $null
        try { $started = $p.StartTime } catch { }
        $out += [pscustomobject]@{
            Pid       = $p.Id
            Online    = ($conns.Count -gt 0)
            Endpoint  = if ($conns) { "$($conns[0].RemoteAddress):$($conns[0].RemotePort)" } else { $null }
            SessionAt = if ($conns) { $conns[0].CreationTime } else { $null }
            StartedAt = $started
        }
    }
    return $out
}

function Format-Duration {
    param([timespan]$Span)
    if ($Span.TotalMinutes -lt 1)  { return "{0} วิ" -f [int]$Span.TotalSeconds }
    if ($Span.TotalHours   -lt 1)  { return "{0} นาที" -f [int]$Span.TotalMinutes }
    if ($Span.TotalDays    -lt 1)  { return "{0} ชม {1} นาที" -f [int]$Span.TotalHours, $Span.Minutes }
    return "{0} วัน {1} ชม" -f [int]$Span.TotalDays, $Span.Hours
}

# ---------------------------------------------------------------- แจ้งเตือนแบบ async

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
$script:http = [System.Net.Http.HttpClient]::new()
$script:http.Timeout = [timespan]::FromSeconds(20)
$script:pendingSends = [System.Collections.ArrayList]::new()

function Get-NotifyChannels {
    $ch = @()
    if ($script:cfg.NtfyTopic)                                     { $ch += 'ntfy' }
    if ($script:cfg.WebhookUrl)                                    { $ch += 'webhook' }
    if ($script:cfg.TelegramToken -and $script:cfg.TelegramChatId) { $ch += 'telegram' }
    return $ch
}

function Send-Alert {
    param([string]$Message, [switch]$Urgent)

    if ($script:cfg.NtfyTopic) {
        try {
            $uri = "$($script:cfg.NtfyServer.TrimEnd('/'))/$($script:cfg.NtfyTopic)"
            $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $uri)
            $req.Content = [System.Net.Http.StringContent]::new($Message, [System.Text.Encoding]::UTF8, 'text/plain')
            # header ต้องเป็น ASCII ข้อความไทยจึงอยู่ใน body
            $req.Headers.TryAddWithoutValidation('Title', 'Ragnarok Origin') | Out-Null
            $req.Headers.TryAddWithoutValidation('Priority', $(if ($Urgent) { 'urgent' } else { 'default' })) | Out-Null
            $req.Headers.TryAddWithoutValidation('Tags', $(if ($Urgent) { 'rotating_light' } else { 'white_check_mark' })) | Out-Null
            [void]$script:pendingSends.Add(@{ Name = 'ntfy'; Task = $script:http.SendAsync($req) })
        } catch { Write-Event "ยิง ntfy ไม่ออก: $($_.Exception.Message)" 'warn' }
    }

    if ($script:cfg.WebhookUrl) {
        try {
            $json = (@{ content = $Message } | ConvertTo-Json -Compress)
            $content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, 'application/json')
            [void]$script:pendingSends.Add(@{ Name = 'webhook'; Task = $script:http.PostAsync($script:cfg.WebhookUrl, $content) })
        } catch { Write-Event "ยิง webhook ไม่ออก: $($_.Exception.Message)" 'warn' }
    }

    if ($script:cfg.TelegramToken -and $script:cfg.TelegramChatId) {
        try {
            $json = (@{
                chat_id              = $script:cfg.TelegramChatId
                text                 = $Message
                disable_notification = (-not $Urgent)
            } | ConvertTo-Json -Compress)
            $content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, 'application/json')
            $uri = "https://api.telegram.org/bot$($script:cfg.TelegramToken)/sendMessage"
            [void]$script:pendingSends.Add(@{ Name = 'telegram'; Task = $script:http.PostAsync($uri, $content) })
        } catch { Write-Event "ยิง telegram ไม่ออก: $($_.Exception.Message)" 'warn' }
    }

    if ($script:cfg.Sound -and $Urgent) {
        $wav = @("$env:WINDIR\Media\Alarm01.wav", "$env:WINDIR\Media\Ring01.wav") |
               Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($wav) { try { [System.Media.SoundPlayer]::new($wav).Play() } catch { } }
    }
}

# เก็บผลการส่งที่เสร็จแล้ว เรียกทุก tick
function Reap-Sends {
    for ($i = $script:pendingSends.Count - 1; $i -ge 0; $i--) {
        $s = $script:pendingSends[$i]
        if (-not $s.Task.IsCompleted) { continue }
        try {
            if ($s.Task.IsFaulted) {
                Write-Event "ส่ง $($s.Name) ไม่สำเร็จ: $($s.Task.Exception.InnerException.Message)" 'warn'
            } else {
                $code = [int]$s.Task.Result.StatusCode
                if ($code -ge 300) { Write-Event "ส่ง $($s.Name) ได้ HTTP $code" 'warn' }
                $s.Task.Result.Dispose()
            }
        } catch { }
        $script:pendingSends.RemoveAt($i)
    }
}

# ---------------------------------------------------------------- เช็คเน็ตแบบ async

$script:netProbe   = $null
$script:netUp      = $true
$script:netChecked = [datetime]::MinValue

function Poll-Internet {
    if ($script:netProbe) {
        if (-not $script:netProbe.Task.IsCompleted) { return }
        $script:netUp = (-not $script:netProbe.Task.IsFaulted) -and $script:netProbe.Client.Connected
        try { $script:netProbe.Client.Dispose() } catch { }
        $script:netProbe = $null
        $script:netChecked = Get-Date
        return
    }
    if (((Get-Date) - $script:netChecked).TotalSeconds -lt $script:cfg.IntervalSec) { return }
    try {
        $c = [System.Net.Sockets.TcpClient]::new()
        $script:netProbe = @{ Client = $c; Task = $c.ConnectAsync('1.1.1.1', 443) }
    } catch { $script:netProbe = $null }
}

# ---------------------------------------------------------------- สถานะการเฝ้า

$script:watching    = $false
$script:state       = @{}
$script:netAlert    = @{ Active = $false; LastAt = $null; Repeats = 0 }
$script:noProcAlert = @{ Active = $false; LastAt = $null; Repeats = 0 }
$script:netDownStreak = 0
$script:lastHeartbeat = Get-Date
$script:lastCheck     = [datetime]::MinValue
$script:lastStatus    = @()

function Test-AlertDue {
    param($S)
    if (-not $S.Active) { $S.Active = $true; $S.LastAt = Get-Date; return $true }
    if ($script:cfg.RepeatAlertMin -gt 0 -and $S.Repeats -lt $script:cfg.MaxRepeats -and
        ((Get-Date) - $S.LastAt).TotalMinutes -ge $script:cfg.RepeatAlertMin) {
        $S.Repeats++; $S.LastAt = Get-Date; return $true
    }
    return $false
}

function Reset-Alert { param($S) $S.Active = $false; $S.LastAt = $null; $S.Repeats = 0 }

# ---------------------------------------------------------------- หน้าต่างหลัก

$form                 = [System.Windows.Forms.Form]::new()
$form.Text            = 'ROOC Monitor'
$form.Size            = [System.Drawing.Size]::new(760, 660)
$form.MinimumSize     = [System.Drawing.Size]::new(680, 560)
$form.StartPosition   = 'CenterScreen'
$form.BackColor       = $C.Bg
$form.ForeColor       = $C.Text
$form.Font            = NewFont 9.5

try { if (Test-Path $GameExe) { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($GameExe) } } catch { }

# ---- header
$header           = [System.Windows.Forms.Panel]::new()
$header.Dock      = 'Top'
$header.Height    = 92
$header.BackColor = $C.Panel

$lblTitle           = [System.Windows.Forms.Label]::new()
$lblTitle.Text      = 'Ragnarok Origin Classic'
$lblTitle.Font      = NewFont 15 'Bold'
$lblTitle.ForeColor = $C.Text
$lblTitle.AutoSize  = $true
$lblTitle.Location  = [System.Drawing.Point]::new(22, 16)
$header.Controls.Add($lblTitle)

$lblState           = [System.Windows.Forms.Label]::new()
$lblState.Text      = 'ยังไม่ได้เริ่มเฝ้า'
$lblState.Font      = NewFont 10
$lblState.ForeColor = $C.Muted
$lblState.AutoSize  = $true
$lblState.Location  = [System.Drawing.Point]::new(24, 50)
$header.Controls.Add($lblState)

# ---- แถบปุ่ม
$bar           = [System.Windows.Forms.Panel]::new()
$bar.Dock      = 'Top'
$bar.Height    = 62
$bar.BackColor = $C.Bg

function New-Button {
    param([string]$Text, [int]$X, [int]$W, [System.Drawing.Color]$Accent, [switch]$Primary)
    $b                          = [System.Windows.Forms.Button]::new()
    $b.Text                     = $Text
    $b.Location                 = [System.Drawing.Point]::new($X, 12)
    $b.Size                     = [System.Drawing.Size]::new($W, 38)
    $b.FlatStyle                = 'Flat'
    $b.FlatAppearance.BorderSize = 1
    $b.Font                     = NewFont 10 $(if ($Primary) { 'Bold' } else { 'Regular' })
    $b.Cursor                   = 'Hand'
    if ($Primary) {
        $b.BackColor = $Accent
        $b.ForeColor = [System.Drawing.Color]::FromArgb(16, 18, 24)
        $b.FlatAppearance.BorderColor = $Accent
    } else {
        $b.BackColor = $C.Panel
        $b.ForeColor = $Accent
        $b.FlatAppearance.BorderColor = $C.Border
    }
    return $b
}

$btnWatch = New-Button 'เริ่มเฝ้า' 22 150 $C.Green -Primary
$btnTest  = New-Button 'ทดสอบเตือน' 184 140 $C.Blue
$btnCfg   = New-Button 'ตั้งค่า' 334 110 $C.Text
$btnLog   = New-Button 'เปิดไฟล์ log' 454 130 $C.Muted
$bar.Controls.AddRange(@($btnWatch, $btnTest, $btnCfg, $btnLog))

# ---- พื้นที่การ์ด client
$cards            = [System.Windows.Forms.FlowLayoutPanel]::new()
$cards.Dock       = 'Top'
$cards.Height     = 200
$cards.BackColor  = $C.Bg
$cards.Padding    = [System.Windows.Forms.Padding]::new(16, 4, 16, 4)
$cards.AutoScroll = $true

# ---- log บนหน้าจอ
$logBox                  = [System.Windows.Forms.RichTextBox]::new()
$logBox.Dock             = 'Fill'
$logBox.BackColor        = $C.Panel
$logBox.ForeColor        = $C.Muted
$logBox.BorderStyle      = 'None'
$logBox.ReadOnly         = $true
$logBox.Font             = [System.Drawing.Font]::new('Consolas', 9)
$logBox.ScrollBars       = 'Vertical'
$logBox.HideSelection    = $true

$logWrap           = [System.Windows.Forms.Panel]::new()
$logWrap.Dock      = 'Fill'
$logWrap.BackColor = $C.Panel
$logWrap.Padding   = [System.Windows.Forms.Padding]::new(16, 12, 8, 12)
$logWrap.Controls.Add($logBox)

$logHead           = [System.Windows.Forms.Label]::new()
$logHead.Text      = '  เหตุการณ์'
$logHead.Dock      = 'Top'
$logHead.Height    = 30
$logHead.TextAlign = 'MiddleLeft'
$logHead.ForeColor = $C.Muted
$logHead.BackColor = $C.Bg
$logHead.Font      = NewFont 9.5 'Bold'

# WinForms จัด dock ไล่จาก index สูงไปต่ำ ตัว index สูงสุดจึงได้ขอบบนก่อน
# เพราะงั้นต้อง add ย้อนลำดับที่อยากให้เห็น และเอาตัว Fill ลง index 0
$form.Controls.Add($logWrap)   # Fill - กินที่เหลือ
$form.Controls.Add($logHead)
$form.Controls.Add($cards)
$form.Controls.Add($bar)
$form.Controls.Add($header)    # index สูงสุด = อยู่บนสุด

# ---- tray
$tray             = [System.Windows.Forms.NotifyIcon]::new()
$tray.Text        = 'ROOC Monitor'
$tray.Visible     = $true
try { $tray.Icon = if ($form.Icon) { $form.Icon } else { [System.Drawing.SystemIcons]::Application } } catch { $tray.Icon = [System.Drawing.SystemIcons]::Application }

$trayMenu = [System.Windows.Forms.ContextMenuStrip]::new()
$miShow   = $trayMenu.Items.Add('เปิดหน้าต่าง')
$miExit   = $trayMenu.Items.Add('ออกจากโปรแกรม')
$tray.ContextMenuStrip = $trayMenu

# ---------------------------------------------------------------- log

function Write-Event {
    param([string]$Message, [string]$Kind = 'info')

    $stamp = Get-Date -Format 'HH:mm:ss'
    $color = switch ($Kind) {
        'good' { $C.Green }
        'bad'  { $C.Red }
        'warn' { $C.Amber }
        default { $C.Muted }
    }
    $logBox.SelectionStart  = $logBox.TextLength
    $logBox.SelectionLength = 0
    $logBox.SelectionColor  = $C.Faint
    $logBox.AppendText("$stamp  ")
    $logBox.SelectionColor  = $color
    $logBox.AppendText("$Message`n")
    $logBox.ScrollToCaret()

    try {
        Add-Content -Path $LogPath -Encoding utf8 `
            -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    } catch { }
}

# ---------------------------------------------------------------- การ์ด client

function Build-Card {
    param($S)

    $card           = [System.Windows.Forms.Panel]::new()
    $card.Size      = [System.Drawing.Size]::new(216, 148)
    $card.Margin    = [System.Windows.Forms.Padding]::new(6)
    $card.BackColor = $C.Panel

    $accent = if ($S.Online) { $C.Green } else { $C.Red }

    $card.Add_Paint({
        param($sender, $e)
        $e.Graphics.SmoothingMode = 'AntiAlias'
        $pen = [System.Drawing.Pen]::new($C.Border, 1)
        $e.Graphics.DrawRectangle($pen, 0, 0, $sender.Width - 1, $sender.Height - 1)
        $pen.Dispose()
        # แถบสีสถานะด้านซ้าย
        $brush = [System.Drawing.SolidBrush]::new($sender.Tag)
        $e.Graphics.FillRectangle($brush, 0, 0, 4, $sender.Height)
        # จุดกลมสถานะ
        $e.Graphics.FillEllipse($brush, 18, 18, 11, 11)
        $brush.Dispose()
    })
    $card.Tag = $accent

    $lblStatus           = [System.Windows.Forms.Label]::new()
    $lblStatus.Text      = if ($S.Online) { 'ONLINE' } else { 'หลุด' }
    $lblStatus.Font      = NewFont 12 'Bold'
    $lblStatus.ForeColor = $accent
    $lblStatus.AutoSize  = $true
    $lblStatus.Location  = [System.Drawing.Point]::new(36, 13)
    $card.Controls.Add($lblStatus)

    $lblPid           = [System.Windows.Forms.Label]::new()
    $lblPid.Text      = "PID $($S.Pid)"
    $lblPid.Font      = NewFont 9
    $lblPid.ForeColor = $C.Muted
    $lblPid.AutoSize  = $true
    $lblPid.Location  = [System.Drawing.Point]::new(19, 44)
    $card.Controls.Add($lblPid)

    $lblEp           = [System.Windows.Forms.Label]::new()
    $lblEp.Font      = [System.Drawing.Font]::new('Consolas', 8.5)
    $lblEp.ForeColor = $C.Text
    $lblEp.AutoSize  = $false
    $lblEp.Size      = [System.Drawing.Size]::new(180, 20)
    $lblEp.Location  = [System.Drawing.Point]::new(19, 70)
    $lblEp.Text      = if ($S.Endpoint) { $S.Endpoint } else { 'ไม่มี socket เกม' }
    $card.Controls.Add($lblEp)

    $lblUp           = [System.Windows.Forms.Label]::new()
    $lblUp.Font      = NewFont 9
    $lblUp.ForeColor = $C.Muted
    $lblUp.AutoSize  = $false
    $lblUp.Size      = [System.Drawing.Size]::new(180, 40)
    $lblUp.Location  = [System.Drawing.Point]::new(19, 96)
    if ($S.Online -and $S.SessionAt) {
        $lblUp.Text = "ต่อเนื่องมา {0}`nตั้งแต่ {1}" -f (Format-Duration ((Get-Date) - $S.SessionAt)), $S.SessionAt.ToString('HH:mm')
    } else {
        $st = $script:state["pid$($S.Pid)"]
        if ($st -and $st.DownSince) {
            $lblUp.Text = "หลุดมาแล้ว {0}" -f (Format-Duration ((Get-Date) - $st.DownSince))
        } else {
            $lblUp.Text = 'รอตรวจสอบ'
        }
    }
    $card.Controls.Add($lblUp)

    return $card
}

function Refresh-Cards {
    param($Status)

    $cards.SuspendLayout()
    $cards.Controls.Clear()

    if ($Status.Count -eq 0) {
        $empty           = [System.Windows.Forms.Label]::new()
        $empty.Text      = 'ไม่พบ rooc.exe ทำงานอยู่ — เปิดเกมก่อน'
        $empty.Font      = NewFont 11
        $empty.ForeColor = $C.Amber
        $empty.AutoSize  = $true
        $empty.Margin    = [System.Windows.Forms.Padding]::new(10, 24, 0, 0)
        $cards.Controls.Add($empty)
    } else {
        foreach ($s in $Status) { $cards.Controls.Add((Build-Card $s)) }
    }
    $cards.ResumeLayout()
}

# ---------------------------------------------------------------- รอบตรวจ

function Do-Check {
    $status = @(Get-ClientStatus)
    $script:lastStatus = $status
    $script:lastCheck  = Get-Date

    if (-not $script:watching) { Refresh-Cards $status; return }

    # เน็ตตายแล้ว socket ที่เห็นเชื่อไม่ได้ เพราะ Windows ค้าง entry ไว้อีกนาน
    if (-not $script:netUp) {
        $script:netDownStreak++
        if ($script:netDownStreak -ge $script:cfg.GraceChecks -and (Test-AlertDue $script:netAlert)) {
            Write-Event 'เน็ตออกนอกไม่ได้ — เกมน่าจะหลุดตามด้วย' 'bad'
            Send-Alert -Message 'เน็ตบ้านหลุด - เกมน่าจะหลุดตามด้วย' -Urgent
        }
        Refresh-Cards $status
        return
    }
    if ($script:netAlert.Active) {
        Write-Event 'เน็ตกลับมาแล้ว' 'good'
        Send-Alert -Message 'เน็ตกลับมาแล้ว'
        Reset-Alert $script:netAlert
    }
    $script:netDownStreak = 0

    if ($status.Count -eq 0) {
        if (Test-AlertDue $script:noProcAlert) {
            Write-Event 'rooc.exe ปิดไปแล้ว' 'bad'
            Send-Alert -Message 'เกมปิดไปแล้ว - ไม่พบ rooc.exe ทำงานอยู่' -Urgent
        }
        Refresh-Cards $status
        return
    }
    if ($script:noProcAlert.Active) {
        Write-Event 'rooc.exe กลับมาแล้ว' 'good'
        Reset-Alert $script:noProcAlert
    }

    foreach ($s in $status) {
        $key = "pid$($s.Pid)"
        if (-not $script:state.ContainsKey($key)) {
            $script:state[$key] = @{
                Misses = 0; Alerted = $false; SessionAt = $s.SessionAt
                LastAlertAt = $null; Repeats = 0; DownSince = $null
            }
            Write-Event "เจอ client PID $($s.Pid) — $(if ($s.Online) { 'ออนไลน์' } else { 'หลุดอยู่' })"
        }
        $st = $script:state[$key]

        if ($s.Online) {
            # session ใหม่ = เมื่อกี้หลุดไปแล้วเด้งกลับเองได้ ไม่ต้องปลุก
            if ($st.SessionAt -and $s.SessionAt -and $s.SessionAt -gt $st.SessionAt) {
                Write-Event "PID $($s.Pid) หลุดแล้วต่อกลับเองได้ ($($s.SessionAt.ToString('HH:mm:ss')))" 'warn'
                Send-Alert -Message "PID $($s.Pid) หลุดแล้วต่อกลับเองได้ เมื่อ $($s.SessionAt.ToString('HH:mm:ss'))"
            }
            $st.SessionAt = $s.SessionAt

            if ($st.Alerted) {
                Write-Event "PID $($s.Pid) กลับมาออนไลน์แล้ว" 'good'
                Send-Alert -Message "PID $($s.Pid) กลับมาออนไลน์แล้ว"
            }
            $st.Alerted = $false; $st.Misses = 0; $st.Repeats = 0
            $st.LastAlertAt = $null; $st.DownSince = $null
        }
        else {
            $st.Misses++
            if (-not $st.DownSince) { $st.DownSince = Get-Date }

            if ($st.Misses -ge $script:cfg.GraceChecks) {
                $due = (-not $st.Alerted) -or (
                    $script:cfg.RepeatAlertMin -gt 0 -and
                    $st.Repeats -lt $script:cfg.MaxRepeats -and
                    $st.LastAlertAt -and
                    ((Get-Date) - $st.LastAlertAt).TotalMinutes -ge $script:cfg.RepeatAlertMin
                )
                if ($due) {
                    if ($st.Alerted) { $st.Repeats++ }
                    $st.Alerted = $true
                    $st.LastAlertAt = Get-Date
                    $mins = [math]::Round(((Get-Date) - $st.DownSince).TotalMinutes, 1)
                    $suffix = if ($st.Repeats -gt 0) { " (ซ้ำครั้งที่ $($st.Repeats))" } else { '' }
                    Write-Event "หลุดแล้ว! PID $($s.Pid) — $mins นาที$suffix" 'bad'
                    Send-Alert -Message "หลุดแล้ว! PID $($s.Pid) ไม่ได้ต่อกับ game server มา $mins นาที$suffix" -Urgent
                    $tray.ShowBalloonTip(5000, 'Ragnarok Origin', "PID $($s.Pid) หลุดแล้ว", 'Warning')
                }
            }
        }
    }

    # heartbeat ให้แยกออกว่าเงียบเพราะปกติ หรือเพราะ monitor ตาย
    if ($script:cfg.HeartbeatHours -gt 0 -and
        ((Get-Date) - $script:lastHeartbeat).TotalHours -ge $script:cfg.HeartbeatHours) {
        $script:lastHeartbeat = Get-Date
        $on = @($status | Where-Object { $_.Online }).Count
        Send-Alert -Message "ยังเฝ้าอยู่ - ออนไลน์ $on/$($status.Count) client"
    }

    # ล้าง state ของ PID ที่ตายไปแล้ว
    $alive = @($status | ForEach-Object { "pid$($_.Pid)" })
    @($script:state.Keys) | Where-Object { $alive -notcontains $_ } | ForEach-Object { $script:state.Remove($_) }

    Refresh-Cards $status
}

# ---------------------------------------------------------------- timer

$timer          = [System.Windows.Forms.Timer]::new()
$timer.Interval = 1000
$timer.Add_Tick({
    Reap-Sends
    Poll-Internet

    $due = ((Get-Date) - $script:lastCheck).TotalSeconds -ge $script:cfg.IntervalSec
    if ($due) { Do-Check }

    if ($script:watching) {
        $next = [math]::Max(0, $script:cfg.IntervalSec - [int]((Get-Date) - $script:lastCheck).TotalSeconds)
        $on   = @($script:lastStatus | Where-Object { $_.Online }).Count
        $tot  = $script:lastStatus.Count
        $netTxt = if ($script:netUp) { '' } else { '  ·  เน็ตหลุด' }
        $lblState.Text = "กำลังเฝ้าดู  ·  ออนไลน์ $on/$tot  ·  ตรวจอีกครั้งใน $next วิ$netTxt"
        $lblState.ForeColor = if ($on -eq $tot -and $tot -gt 0 -and $script:netUp) { $C.Green } else { $C.Red }
        $tray.Text = "ROOC Monitor — ออนไลน์ $on/$tot"
    }
})

# ---------------------------------------------------------------- หน้าตั้งค่า

function Show-Settings {
    $d              = [System.Windows.Forms.Form]::new()
    $d.Text         = 'ตั้งค่า'
    $d.Size         = [System.Drawing.Size]::new(500, 560)
    $d.StartPosition = 'CenterParent'
    $d.FormBorderStyle = 'FixedDialog'
    $d.MaximizeBox  = $false
    $d.MinimizeBox  = $false
    $d.BackColor    = $C.Bg
    $d.ForeColor    = $C.Text
    $d.Font         = NewFont 9.5

    $y = 18
    $fields = @{}

    function Add-Field {
        param([string]$Key, [string]$Label, [string]$Hint = '')
        $l           = [System.Windows.Forms.Label]::new()
        $l.Text      = $Label
        $l.ForeColor = $C.Muted
        $l.AutoSize  = $true
        $l.Location  = [System.Drawing.Point]::new(24, $script:y)
        $d.Controls.Add($l)

        $t              = [System.Windows.Forms.TextBox]::new()
        $t.Text         = [string]$script:cfg[$Key]
        $t.Location     = [System.Drawing.Point]::new(24, $script:y + 22)
        $t.Size         = [System.Drawing.Size]::new(430, 26)
        $t.BackColor    = $C.Panel
        $t.ForeColor    = $C.Text
        $t.BorderStyle  = 'FixedSingle'
        $d.Controls.Add($t)
        $fields[$Key] = $t

        $script:y += 52
        if ($Hint) {
            $h           = [System.Windows.Forms.Label]::new()
            $h.Text      = $Hint
            $h.ForeColor = $C.Faint
            $h.Font      = NewFont 8.5
            $h.AutoSize  = $true
            $h.Location  = [System.Drawing.Point]::new(24, $script:y - 6)
            $d.Controls.Add($h)
            $script:y += 16
        }
    }

    $script:y = 18
    Add-Field 'NtfyTopic'      'ntfy topic'          'ลงแอป ntfy แล้ว subscribe ชื่อนี้ให้ตรงกัน — ห้ามบอกใคร'
    Add-Field 'WebhookUrl'     'Discord webhook URL' 'เว้นว่างได้ ถ้าใช้ ntfy อยู่แล้ว'
    Add-Field 'IntervalSec'    'ตรวจทุกกี่วินาที'
    Add-Field 'GraceChecks'    'หลุดกี่รอบติดถึงเตือน'  'คูณกับช่วงตรวจ = เวลาที่ต้องหลุดจริงก่อนปลุก'
    Add-Field 'RepeatAlertMin' 'เตือนซ้ำทุกกี่นาที'     '0 = เตือนครั้งเดียว'
    Add-Field 'HeartbeatHours' 'ส่ง "ยังเฝ้าอยู่" ทุกกี่ชม.' '0 = ปิด'

    $chkSound           = [System.Windows.Forms.CheckBox]::new()
    $chkSound.Text      = 'เปิดเสียงที่เครื่องนี้ด้วย'
    $chkSound.Checked   = [bool]$script:cfg.Sound
    $chkSound.ForeColor = $C.Text
    $chkSound.AutoSize  = $true
    $chkSound.Location  = [System.Drawing.Point]::new(24, $script:y)
    $d.Controls.Add($chkSound)

    $ok           = New-Button 'บันทึก' 24 120 $C.Green -Primary
    $ok.Location  = [System.Drawing.Point]::new(24, $script:y + 44)
    $cancel       = New-Button 'ยกเลิก' 24 120 $C.Muted
    $cancel.Location = [System.Drawing.Point]::new(156, $script:y + 44)
    $d.Controls.AddRange(@($ok, $cancel))

    $ok.Add_Click({
        foreach ($k in $fields.Keys) {
            $raw = $fields[$k].Text.Trim()
            if ($DefaultConfig[$k] -is [int] -or $DefaultConfig[$k] -is [double]) {
                $n = 0.0
                if ([double]::TryParse($raw, [ref]$n)) { $script:cfg[$k] = $n }
            } else {
                $script:cfg[$k] = $raw
            }
        }
        $script:cfg.Sound = $chkSound.Checked
        Save-Config $script:cfg
        $d.DialogResult = 'OK'
        $d.Close()
    })
    $cancel.Add_Click({ $d.DialogResult = 'Cancel'; $d.Close() })

    if ($d.ShowDialog($form) -eq 'OK') {
        Write-Event 'บันทึกการตั้งค่าแล้ว' 'good'
        Update-WatchButton
    }
    $d.Dispose()
}

# ---------------------------------------------------------------- ปุ่ม

function Update-WatchButton {
    if ($script:watching) {
        $btnWatch.Text      = 'หยุดเฝ้า'
        $btnWatch.BackColor = $C.Red
        $btnWatch.FlatAppearance.BorderColor = $C.Red
    } else {
        $btnWatch.Text      = 'เริ่มเฝ้า'
        $btnWatch.BackColor = $C.Green
        $btnWatch.FlatAppearance.BorderColor = $C.Green
        $lblState.Text      = 'ยังไม่ได้เริ่มเฝ้า'
        $lblState.ForeColor = $C.Muted
    }
}

$btnWatch.Add_Click({
    if ($script:watching) {
        $script:watching = $false
        $timer.Stop()
        Write-Event 'หยุดเฝ้าแล้ว' 'warn'
    } else {
        if ((Get-NotifyChannels).Count -eq 0 -and -not $script:cfg.Sound) {
            [System.Windows.Forms.MessageBox]::Show(
                "ยังไม่ได้ตั้งช่องทางเตือนเลย ถ้าเฝ้าแบบนี้ตอนหลุดจะไม่มีใครรู้`n`nกดตั้งค่า แล้วใส่ ntfy topic ก่อน",
                'ยังเตือนใครไม่ได้', 'OK', 'Warning') | Out-Null
            Show-Settings
            return
        }
        $script:watching = $true
        $script:state.Clear()
        Reset-Alert $script:netAlert
        Reset-Alert $script:noProcAlert
        $script:lastHeartbeat = Get-Date
        $script:lastCheck = [datetime]::MinValue
        $timer.Start()
        Write-Event "เริ่มเฝ้าดู — ตรวจทุก $($script:cfg.IntervalSec) วิ, เตือนผ่าน $((Get-NotifyChannels) -join ', ')" 'good'
    }
    Update-WatchButton
})

$btnTest.Add_Click({
    if ((Get-NotifyChannels).Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('ยังไม่ได้ตั้งช่องทางเตือน กดตั้งค่าก่อน', 'ยังไม่พร้อม', 'OK', 'Warning') | Out-Null
        return
    }
    Send-Alert -Message 'ทดสอบการแจ้งเตือน - ถ้าเห็นข้อความนี้บนมือถือ แปลว่าพร้อมใช้งานแล้ว' -Urgent
    Write-Event "ยิงข้อความทดสอบไป $((Get-NotifyChannels) -join ', ') แล้ว — ไปเช็คมือถือ" 'good'
})

$btnCfg.Add_Click({ Show-Settings })
$btnLog.Add_Click({
    if (Test-Path $LogPath) { Start-Process notepad.exe $LogPath } else { Write-Event 'ยังไม่มีไฟล์ log' 'warn' }
})

# ---------------------------------------------------------------- tray + ปิดหน้าต่าง

$script:reallyExit = $false

$form.Add_FormClosing({
    param($sender, $e)
    # ปิดหน้าต่างตอนกำลังเฝ้า = ย่อลง tray ไม่ใช่ปิดโปรแกรม
    if (-not $script:reallyExit -and $script:watching) {
        $e.Cancel = $true
        $form.Hide()
        $tray.ShowBalloonTip(3000, 'ROOC Monitor', 'ย่อลง tray แล้ว ยังเฝ้าให้อยู่', 'Info')
    }
})

$miShow.Add_Click({ $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })
$miExit.Add_Click({ $script:reallyExit = $true; $form.Close() })
$tray.Add_DoubleClick({ $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })

$form.Add_Shown({
    # ถูกเรียกมาจาก .vbs แบบ nCmdShow=0 ฟอร์มจะโผล่มาแบบย่อ ต้อง SW_RESTORE (9) ไม่ใช่ SW_SHOW
    try { [Win.Native]::ShowWindow($form.Handle, 9) | Out-Null } catch { }
    $form.WindowState = 'Normal'
    $form.Activate()

    Write-Event 'พร้อมใช้งาน'
    if ((Get-NotifyChannels).Count -eq 0) {
        Write-Event 'ยังไม่ได้ตั้งช่องทางเตือน — กดปุ่มตั้งค่าก่อน' 'warn'
    }
    Do-Check
    if ($script:cfg.AutoStart -and (Get-NotifyChannels).Count -gt 0) { $btnWatch.PerformClick() }
})

[void]$form.ShowDialog()

$timer.Stop()
$tray.Visible = $false
$tray.Dispose()
$script:http.Dispose()
