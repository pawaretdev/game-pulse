<#
    Watch-RoocOnline.ps1
    เฝ้าดูว่า client ของ Ragnarok Origin Classic (rooc.exe) ยังเชื่อมต่อกับ game server อยู่หรือเปล่า
    แล้วเตือนเข้ามือถือเมื่อหลุด

    หลักการ: ตอนอยู่ในเกม rooc.exe จะมี TCP ค้างไว้กับ gate server (43.153.x.x พอร์ตช่วง 10000+)
    พอหลุด/เด้งกลับหน้า login socket นั้นจะหายไป ส่วน connection 443 (CDN) กับ localhost ยังอยู่เหมือนเดิม
    จึงใช้ "มี/ไม่มี socket เกม" เป็นตัวชี้ว่า account ออนไลน์อยู่ไหม

    ตัวอย่างการใช้:
        .\Watch-RoocOnline.ps1 -NtfyTopic "rooc-pawaret-x7k2"     # เฝ้าและเตือนเข้ามือถือ
        .\Watch-RoocOnline.ps1 -NtfyTopic "..." -TestAlert         # ยิงข้อความทดสอบ แล้วจบ
        .\Watch-RoocOnline.ps1 -Once                               # เช็คสถานะครั้งเดียว แล้วจบ
#>

[CmdletBinding()]
param(
    # --- ช่องทางเตือนเข้ามือถือ (ต้องตั้งอย่างน้อยหนึ่งอย่าง) ---

    # ntfy.sh - ตั้งง่ายสุด ไม่ต้องสมัครอะไร แค่ลงแอป ntfy แล้ว subscribe ชื่อ topic เดียวกัน
    # ตั้งชื่อ topic ให้เดายาก เพราะใครที่รู้ชื่อ topic ก็อ่านข้อความได้
    [string]$NtfyTopic = "",
    [string]$NtfyServer = "https://ntfy.sh",

    # Discord webhook หรือ endpoint อะไรก็ได้ที่รับ JSON {"content": "..."}
    [string]$WebhookUrl = "",

    # ปกติจะใส่ @here นำหน้าข้อความ Discord ตอนหลุดจริง ใส่ตัวนี้ถ้าไม่อยากให้ ping
    [switch]$NoDiscordHere,

    # Telegram bot
    [string]$TelegramToken = "",
    [string]$TelegramChatId = "",

    # --- การตรวจจับ ---

    # เช็คทุกกี่วินาที
    [int]$IntervalSec = 30,

    # ต้องไม่เจอ socket เกมติดกันกี่รอบถึงจะถือว่าหลุดจริง (กันเตือนผิดตอนสลับแมพ/เปลี่ยนตัวละคร)
    [int]$GraceChecks = 3,

    # ยังหลุดอยู่ให้เตือนซ้ำทุกกี่นาที จนกว่าจะกลับมาออนไลน์ (0 = เตือนครั้งเดียวพอ)
    # อันนี้แหละที่ทำให้ปลุกติด - ดีกว่าไปหวังพึ่ง vibration pattern ของแอปใดแอปหนึ่ง
    [double]$RepeatAlertMin = 3,

    # เตือนซ้ำได้มากสุดกี่ครั้งต่อการหลุดหนึ่งครั้ง (กันสแปมถ้าไม่มีใครมาแก้)
    [int]$MaxRepeats = 20,

    # ส่งข้อความ "ยังเฝ้าอยู่นะ" ทุกกี่ชั่วโมง เพื่อให้รู้ว่า monitor ยังไม่ตาย (0 = ปิด)
    [double]$HeartbeatHours = 0,

    # --- อื่นๆ ---

    # เปิดเสียงเตือนที่เครื่องนี้ด้วย (ค่าเริ่มต้นคือเงียบ - ถ้าไม่ได้นั่งอยู่หน้าเครื่องก็ไม่มีประโยชน์)
    [switch]$Sound,

    # ยิงข้อความทดสอบไปทุกช่องทางที่ตั้งไว้ แล้วจบ
    [switch]$TestAlert,

    # เช็คครั้งเดียวแล้วออก คืน exit code 0 = ออนไลน์ครบทุก client, 1 = มีตัวหลุด, 2 = ไม่มี rooc.exe เลย
    [switch]$Once,

    # ยอมให้รันทั้งที่ไม่ได้ตั้งช่องทางเตือนไว้ (จดลง log อย่างเดียว)
    [switch]$LogOnly,

    [string]$LogPath = "$PSScriptRoot\rooc-online.log"
)

# PowerShell 5.1 บางเครื่องยัง default เป็น TLS เก่า ซึ่ง ntfy/Discord/Telegram ไม่รับ
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# พอร์ตที่ไม่ใช่ traffic ของเกม (CDN / hot update / เว็บ)
$IgnorePorts = @(80, 443, 8080)

function Write-Log {
    param([string]$Message, [string]$Color = "Gray")
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line -ForegroundColor $Color
    try { Add-Content -Path $LogPath -Value $line -Encoding utf8 } catch { }
}

function Get-NotifyChannels {
    $ch = @()
    if ($NtfyTopic)                              { $ch += "ntfy ($NtfyTopic)" }
    if ($WebhookUrl)                             { $ch += "discord" }
    if ($TelegramToken -and $TelegramChatId)     { $ch += "telegram" }
    return $ch
}

<#
    ส่งแจ้งเตือนไปทุกช่องทางที่ตั้งไว้
    Urgent = ปลุก (ntfy priority 5, Telegram เปิดเสียง) ใช้กับตอนหลุดจริง
    ไม่ urgent ใช้กับข่าวดี เช่น กลับมาออนไลน์แล้ว จะได้ไม่ปลุกซ้ำ
#>
# สีแถบข้าง embed ของ Discord ใช้โทนเดียวกับตัว GUI
$EmbedColor = @{ down = 0xFF6B6B; up = 0x3FD68C; warn = 0xFFC65C; info = 0x7AA2F7 }
$KindIcon   = @{ down = '🔴';     up = '🟢';     warn = '🟡';     info = '🔵' }

function Send-Alert {
    param(
        [string]$Message,
        [string]$Title = "ROOC Monitor",
        [ValidateSet('down','up','warn','info')][string]$Kind = 'info',
        [switch]$Urgent
    )

    $delivered = @()

    if ($NtfyTopic) {
        try {
            # HTTP header รับได้แค่ ASCII จึงต้องกรองก่อนใส่
            $safe = ($Title -replace '[^\x20-\x7E]', '').Trim()
            if (-not $safe) { $safe = "ROOC Monitor" }
            $headers = @{
                Title    = $safe
                Priority = $(if ($Urgent) { "urgent" } else { "default" })
                Tags     = $(if ($Urgent) { "rotating_light" } else { "white_check_mark" })
            }
            Invoke-RestMethod -Uri "$($NtfyServer.TrimEnd('/'))/$NtfyTopic" -Method Post -Headers $headers `
                              -ContentType 'text/plain; charset=utf-8' `
                              -Body ([System.Text.Encoding]::UTF8.GetBytes($Message)) -TimeoutSec 20 | Out-Null
            $delivered += "ntfy"
        } catch {
            Write-Log "ntfy send failed: $($_.Exception.Message)" "DarkYellow"
        }
    }

    if ($WebhookUrl) {
        try {
            $embed = [ordered]@{
                title       = "$($KindIcon[$Kind]) $Title"
                description = $Message
                color       = [int]$EmbedColor[$Kind]
                timestamp   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                footer      = @{ text = "ROOC Monitor" }
            }
            $payload = [ordered]@{ embeds = @($embed) }
            # @here เฉพาะตอนหลุดจริง และต้องประกาศ allowed_mentions
            # ไม่งั้น Discord อาจกลืน @here ที่มาจาก webhook
            if ($Urgent -and -not $NoDiscordHere) {
                $payload.content = '@here'
                $payload.allowed_mentions = @{ parse = @('everyone') }
            }
            $body = $payload | ConvertTo-Json -Compress -Depth 8
            Invoke-RestMethod -Uri $WebhookUrl -Method Post -ContentType 'application/json; charset=utf-8' `
                              -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 20 | Out-Null
            $delivered += "discord"
        } catch {
            Write-Log "discord send failed: $($_.Exception.Message)" "DarkYellow"
        }
    }

    if ($TelegramToken -and $TelegramChatId) {
        try {
            $body = @{
                chat_id              = $TelegramChatId
                text                 = "$Title`n$Message"
                disable_notification = (-not $Urgent)
            } | ConvertTo-Json -Compress
            Invoke-RestMethod -Uri "https://api.telegram.org/bot$TelegramToken/sendMessage" -Method Post `
                              -ContentType 'application/json; charset=utf-8' `
                              -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 20 | Out-Null
            $delivered += "telegram"
        } catch {
            Write-Log "telegram send failed: $($_.Exception.Message)" "DarkYellow"
        }
    }

    if ($Sound -and $Urgent) {
        $wav = @("$env:WINDIR\Media\Alarm01.wav", "$env:WINDIR\Media\Ring01.wav") |
               Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($wav) {
            try {
                $player = [System.Media.SoundPlayer]::new($wav)
                1..10 | ForEach-Object { $player.PlaySync() }
                $player.Dispose()
            } catch { }
        }
    }

    return $delivered
}

<#
    ตัวคุมจังหวะเตือนซ้ำ ใช้ร่วมกันระหว่างเคส "เน็ตหลุด" กับ "ไม่มี process"
    คืน $true เมื่อถึงเวลาที่ควรยิงเตือน (ครั้งแรก หรือครบรอบเตือนซ้ำ)
#>
function New-AlertState { [pscustomobject]@{ Active = $false; LastAt = $null; Repeats = 0 } }

function Test-AlertDue {
    param([ref]$State)
    $s = $State.Value

    if (-not $s.Active) { $s.Active = $true; $s.LastAt = Get-Date; return $true }

    if ($RepeatAlertMin -gt 0 -and $s.Repeats -lt $MaxRepeats -and
        ((Get-Date) - $s.LastAt).TotalMinutes -ge $RepeatAlertMin) {
        $s.Repeats++
        $s.LastAt = Get-Date
        return $true
    }
    return $false
}

function Reset-Alert {
    param([ref]$State)
    $State.Value.Active  = $false
    $State.Value.LastAt  = $null
    $State.Value.Repeats = 0
}

# เน็ตออกนอกบ้านยังไปได้ไหม
# ถ้าเน็ตตายกลางดึก Windows จะยังโชว์ socket เกมค้างไว้อีกพักใหญ่ (half-open) ทำให้ดูเหมือนยังออนไลน์
function Test-InternetUp {
    foreach ($target in @('1.1.1.1', '8.8.8.8')) {
        $client = [System.Net.Sockets.TcpClient]::new()
        try {
            if ($client.ConnectAsync($target, 443).Wait(3000)) { return $true }
        } catch { } finally { $client.Dispose() }
    }
    return $false
}

# คืน list ของ socket เกมที่ process นี้เปิดอยู่
function Get-GameConnections {
    param([int]$ProcessId)

    Get-NetTCPConnection -OwningProcess $ProcessId -State Established -ErrorAction SilentlyContinue |
        Where-Object {
            $_.RemoteAddress -notmatch '^(127\.|::1$|0\.0\.0\.0)' -and
            $IgnorePorts -notcontains $_.RemotePort
        }
}

# สแกน client ทุกตัว คืนสรุปสถานะ
function Get-ClientStatus {
    $procs = @(Get-Process -Name rooc -ErrorAction SilentlyContinue)
    foreach ($p in $procs) {
        $conns = @(Get-GameConnections -ProcessId $p.Id)
        [pscustomobject]@{
            Pid       = $p.Id
            Online    = ($conns.Count -gt 0)
            Endpoint  = if ($conns) { "$($conns[0].RemoteAddress):$($conns[0].RemotePort)" } else { $null }
            SessionAt = if ($conns) { $conns[0].CreationTime } else { $null }
            StartedAt = $p.StartTime
        }
    }
}

# ---------- โหมดทดสอบการเตือน ----------
if ($TestAlert) {
    $channels = Get-NotifyChannels
    if ($channels.Count -eq 0) {
        Write-Log "No alert channel configured - pass -NtfyTopic, -WebhookUrl or -TelegramToken/-TelegramChatId" "Red"
        exit 3
    }
    Write-Log "Sending a test alert via: $($channels -join ', ')" "Cyan"
    $ok = Send-Alert -Title "Test alert" -Kind info -Message "If you can see this on your phone, delivery works." -Urgent
    if ($ok.Count -gt 0) {
        Write-Log "Delivered via: $($ok -join ', ') - go check your phone" "Green"
        exit 0
    }
    Write-Log "Every channel failed" "Red"
    exit 1
}

# ---------- โหมดเช็คครั้งเดียว ----------
if ($Once) {
    $status = @(Get-ClientStatus)
    if ($status.Count -eq 0) { Write-Log "rooc.exe is not running" "Red"; exit 2 }

    $offline = @($status | Where-Object { -not $_.Online })
    foreach ($s in $status) {
        if ($s.Online) {
            Write-Log ("PID {0} ONLINE  {1}  (session started {2})" -f $s.Pid, $s.Endpoint, $s.SessionAt.ToString('MM-dd HH:mm')) "Green"
        } else {
            Write-Log ("PID {0} OFFLINE - no socket to the game server" -f $s.Pid) "Red"
        }
    }
    exit ([int]($offline.Count -gt 0))
}

# ---------- โหมดเฝ้าต่อเนื่อง ----------

# กันกรณีเผลอรันทิ้งไว้ทั้งคืนโดยที่มันเตือนใครไม่ได้เลย
$channels = Get-NotifyChannels
if ($channels.Count -eq 0 -and -not $Sound -and -not $LogOnly) {
    Write-Log "No alert channel configured - if a client drops, nobody will know" "Red"
    Write-Log "Pass -NtfyTopic ""a-hard-to-guess-topic"" (easiest), or -WebhookUrl, or -TelegramToken/-TelegramChatId" "Yellow"
    Write-Log "If you really only want a log file, pass -LogOnly" "Yellow"
    exit 3
}

Write-Log "Watching - checking every ${IntervalSec}s, alerting after $GraceChecks consecutive misses" "Cyan"
if ($channels.Count -gt 0) {
    Write-Log "Alert channels: $($channels -join ', ')" "Cyan"
} else {
    Write-Log "Log-only mode - nothing will be sent anywhere" "DarkYellow"
}
if ($HeartbeatHours -gt 0) { Write-Log "Heartbeat every $HeartbeatHours h" "Cyan" }

# เก็บสถานะแยกราย PID
$state         = @{}
$netDownStreak = 0
$netAlert      = New-AlertState
$noProcAlert   = New-AlertState
$lastHeartbeat = Get-Date

while ($true) {
    $status = @(Get-ClientStatus)

    # เช็คเน็ตก่อน - ถ้าเน็ตตาย socket เกมที่ยังค้างอยู่เชื่อไม่ได้
    if (Test-InternetUp) {
        if ($netAlert.Active) {
            Write-Log "Internet is back" "Green"
            Send-Alert -Title "Internet is back" -Kind up -Message "The connection recovered." | Out-Null
            Reset-Alert ([ref]$netAlert)
        }
        $netDownStreak = 0
    }
    else {
        $netDownStreak++
        Write-Log "No internet ($netDownStreak/$GraceChecks) - any game socket still listed may be stale" "DarkYellow"
        if ($netDownStreak -ge $GraceChecks -and (Test-AlertDue ([ref]$netAlert))) {
            # ยิงไว้ก่อน เผื่อเน็ตกลับมาแป๊บนึงพอให้ส่งออกได้
            Write-Log "Internet down - treating the game as dropped too" "Red"
            Send-Alert -Title "Internet is down" -Kind down -Message "This PC cannot reach the internet, so the game has almost certainly dropped as well." -Urgent | Out-Null
        }
        Start-Sleep -Seconds $IntervalSec
        continue
    }

    if ($status.Count -eq 0) {
        if (Test-AlertDue ([ref]$noProcAlert)) {
            Write-Log "rooc.exe is gone (no process)" "Red"
            Send-Alert -Title "Game closed" -Kind down -Message "No rooc.exe process is running - the game exited or crashed." -Urgent | Out-Null
        }
        Start-Sleep -Seconds $IntervalSec
        continue
    }
    if ($noProcAlert.Active) {
        Write-Log "rooc.exe is running again" "Green"
        Send-Alert -Title "Game reopened" -Kind up -Message "rooc.exe is running again." | Out-Null
        Reset-Alert ([ref]$noProcAlert)
    }

    foreach ($s in $status) {
        $key = "pid$($s.Pid)"
        if (-not $state.ContainsKey($key)) {
            $state[$key] = [pscustomobject]@{
                Misses      = 0
                Alerted     = $false
                SessionAt   = $s.SessionAt
                LastAlertAt = $null
                Repeats     = 0
            }
            Write-Log ("Found client PID {0} - initial state: {1}" -f $s.Pid, $(if ($s.Online) { "ONLINE $($s.Endpoint)" } else { "OFFLINE" })) "Cyan"
        }
        $st = $state[$key]

        if ($s.Online) {
            # ตรวจว่ามีการต่อใหม่ไหม = เมื่อกี้หลุดไปแล้วเด้งกลับเอง
            # ไม่ urgent เพราะเด้งกลับได้เองแล้ว ไม่ต้องปลุก แค่ให้เห็นตอนตื่น
            if ($st.SessionAt -and $s.SessionAt -and $s.SessionAt -gt $st.SessionAt) {
                Write-Log ("PID {0} opened a new session at {1} - so it dropped a moment ago" -f $s.Pid, $s.SessionAt.ToString('HH:mm:ss')) "Yellow"
                Send-Alert -Title "Reconnected on its own" -Kind warn -Message "PID $($s.Pid) dropped but got back in at $($s.SessionAt.ToString('HH:mm:ss')). No action needed." | Out-Null
            }
            $st.SessionAt = $s.SessionAt

            if ($st.Alerted) {
                Write-Log ("PID {0} is back online {1}" -f $s.Pid, $s.Endpoint) "Green"
                Send-Alert -Title "Back online" -Kind up -Message "PID $($s.Pid) reconnected to the game server." | Out-Null
                $st.Alerted     = $false
                $st.LastAlertAt = $null
                $st.Repeats     = 0
            }
            $st.Misses = 0
        }
        else {
            $st.Misses++
            Write-Log ("PID {0} has no game socket ({1}/{2})" -f $s.Pid, $st.Misses, $GraceChecks) "DarkYellow"

            if ($st.Misses -ge $GraceChecks) {
                $downSec = $st.Misses * $IntervalSec
                $due = -not $st.Alerted -or (
                    $RepeatAlertMin -gt 0 -and
                    $st.Repeats -lt $MaxRepeats -and
                    $st.LastAlertAt -and
                    ((Get-Date) - $st.LastAlertAt).TotalMinutes -ge $RepeatAlertMin
                )

                if ($due) {
                    if ($st.Alerted) { $st.Repeats++ }
                    $st.Alerted     = $true
                    $st.LastAlertAt = Get-Date

                    $suffix = if ($st.Repeats -gt 0) { " (reminder #$($st.Repeats))" } else { "" }
                    $msg = "PID $($s.Pid) has had no connection to the game server for $([math]::Round($downSec / 60, 1)) min$suffix"
                    Write-Log $msg "Red"
                    Send-Alert -Title "Client disconnected" -Kind down -Message $msg -Urgent | Out-Null
                }
            }
        }
    }

    # heartbeat - ให้รู้ว่าเงียบเพราะทุกอย่างปกติ ไม่ใช่เพราะ monitor ตายไปแล้ว
    if ($HeartbeatHours -gt 0 -and ((Get-Date) - $lastHeartbeat).TotalHours -ge $HeartbeatHours) {
        $lastHeartbeat = Get-Date
        $onlineCount = @($status | Where-Object { $_.Online }).Count
        Send-Alert -Title "Still watching" -Kind info -Message "Routine check-in - $onlineCount of $($status.Count) clients online." | Out-Null
    }

    # ล้าง state ของ PID ที่ตายไปแล้ว
    $alive = $status.Pid | ForEach-Object { "pid$_" }
    @($state.Keys) | Where-Object { $_ -like 'pid*' -and $alive -notcontains $_ } | ForEach-Object { $state.Remove($_) }

    Start-Sleep -Seconds $IntervalSec
}
