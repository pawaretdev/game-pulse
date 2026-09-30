<#
    ROOC-Monitor-WPF.ps1
    หน้าจอเฝ้าสถานะออนไลน์ของ Ragnarok Origin Classic (เวอร์ชัน WPF)

    ตรรกะตรวจจับเหมือน Watch-RoocOnline.ps1 ทุกอย่าง คือดูว่า rooc.exe
    ยังมี TCP ค้างกับ gate server อยู่ไหม ต่างกันแค่ชั้นหน้าตา

    ใช้ config.json ร่วมกับเวอร์ชัน WinForms
#>

<#
    ตัวนี้ถูกเรียกจาก .vbs แบบซ่อน (nCmdShow = 0) จึงไม่มีหน้าต่าง console โผล่อยู่แล้ว
    การซ่อน console ตรงนี้เป็นแค่กันเหนียวเวลารันจาก terminal ตรงๆ

    ผลข้างเคียงของการเปิดแบบซ่อนคือหน้าต่าง WPF จะถูกสร้างแบบซ่อนตามไปด้วยทุกบาน
    แก้ด้วยฟังก์ชัน Force-Show ที่อยู่ข้างล่าง ต้องเรียกก่อน ShowDialog ของทุกหน้าต่าง
#>
try {
    Add-Type -Namespace Win -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
[System.Runtime.InteropServices.DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int val, int size);
'@
    $con = [Win.Native]::GetConsoleWindow()
    if ($con -ne [System.IntPtr]::Zero) { [Win.Native]::ShowWindow($con, 0) | Out-Null }
} catch { }

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http

# ---------------------------------------------------------------- ค่าคงที่

$ConfigPath  = Join-Path $PSScriptRoot 'config.json'
$LogPath     = Join-Path $PSScriptRoot 'rooc-online.log'
$GameExe     = 'C:\Program Files (x86)\roocalive\exe\rooc.exe'
$IgnorePorts = @(80, 443, 8080)

# ---------------------------------------------------------------- view model

# ใช้คลาส C# จริงเพื่อให้ binding อัปเดตเองได้ ไม่ต้อง rebuild การ์ดทุกรอบ
if (-not ('RoocVm.Client' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
namespace RoocVm {
    public class Client : INotifyPropertyChanged {
        public event PropertyChangedEventHandler PropertyChanged;
        void N(string p) {
            var h = PropertyChanged;
            if (h != null) h(this, new PropertyChangedEventArgs(p));
        }
        int _pid;         public int    Pid        { get { return _pid; }        set { _pid = value; N("Pid"); N("PidText"); } }
        public string PidText { get { return "PID " + _pid; } }
        bool _online;     public bool   Online     { get { return _online; }     set { _online = value; N("Online"); } }
        string _status = "";   public string Status   { get { return _status; }   set { _status = value; N("Status"); } }
        string _endpoint = ""; public string Endpoint { get { return _endpoint; } set { _endpoint = value; N("Endpoint"); } }
        string _detail = "";   public string Detail   { get { return _detail; }   set { _detail = value; N("Detail"); } }
        string _since = "";    public string Since    { get { return _since; }    set { _since = value; N("Since"); } }
    }
    public class Entry {
        public string Time { get; set; }
        public string Message { get; set; }
        public string Kind { get; set; }
    }
}
'@
}

$script:clients = [System.Collections.ObjectModel.ObservableCollection[RoocVm.Client]]::new()
$script:entries = [System.Collections.ObjectModel.ObservableCollection[RoocVm.Entry]]::new()

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
    # หนึ่งรอบเตือนยิงกี่ใบ - แต่ละใบมือถือจะสั่นหนึ่งที ยิงหลายใบติดกันจึงได้สั่นรัว
    # ทำแบบนี้เพราะ vibration pattern เป็นของ OS สั่งจากฝั่งเราไม่ได้
    BurstCount     = 4
    BurstGapSec    = 4
    # ใส่ @here นำหน้าข้อความ Discord ตอนหลุดจริง (ข่าวดีกับ heartbeat ไม่ ping)
    DiscordHere    = $true
    Sound          = $false
    AutoStart      = $true
}

function Load-Config {
    $c = [ordered]@{}
    $DefaultConfig.GetEnumerator() | ForEach-Object { $c[$_.Key] = $_.Value }
    if (Test-Path $ConfigPath) {
        try {
            $saved = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @($c.Keys)) { if ($null -ne $saved.$k) { $c[$k] = $saved.$k } }
        } catch { }
    }
    return $c
}

function Save-Config { param($Cfg)
    try { ($Cfg | ConvertTo-Json) | Out-File -FilePath $ConfigPath -Encoding utf8 -Force } catch { }
}

$script:cfg = Load-Config

# ---------------------------------------------------------------- ตรวจจับ

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
        $out += [pscustomobject]@{
            Pid       = $p.Id
            Online    = ($conns.Count -gt 0)
            Endpoint  = if ($conns) { "$($conns[0].RemoteAddress):$($conns[0].RemotePort)" } else { $null }
            SessionAt = if ($conns) { $conns[0].CreationTime } else { $null }
        }
    }
    return $out
}

function Format-Duration { param([timespan]$Span)
    if ($Span.TotalMinutes -lt 1) { return "{0}s" -f [int]$Span.TotalSeconds }
    if ($Span.TotalHours   -lt 1) { return "{0}m" -f [int]$Span.TotalMinutes }
    if ($Span.TotalDays    -lt 1) { return "{0}h {1}m" -f [int]$Span.TotalHours, $Span.Minutes }
    return "{0}d {1}h" -f [int]$Span.TotalDays, $Span.Hours
}

# ---------------------------------------------------------------- แจ้งเตือน (async ล้วน)

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
$script:http = [System.Net.Http.HttpClient]::new()
$script:http.Timeout = [timespan]::FromSeconds(20)
$script:pending = [System.Collections.ArrayList]::new()

function Get-NotifyChannels {
    $ch = @()
    if ($script:cfg.NtfyTopic)                                 { $ch += 'ntfy' }
    if ($script:cfg.WebhookUrl)                                { $ch += 'discord' }
    if ($script:cfg.TelegramToken -and $script:cfg.TelegramChatId) { $ch += 'telegram' }
    return $ch
}

# สีแถบข้าง embed ของ Discord (ต้องเป็นเลขฐานสิบ) ใช้โทนเดียวกับ UI
$EmbedColor = @{
    down = 0xFF6B6B
    up   = 0x3FD68C
    warn = 0xFFC65C
    info = 0x7AA2F7
}

# ไอคอนนำหน้าหัวข้อ ช่วยให้กวาดตาดูใน Discord ออกเร็ว
$KindIcon = @{ down = '🔴'; up = '🟢'; warn = '🟡'; info = '🔵' }

function New-DiscordPayload {
    param([string]$Title, [string]$Message, [string]$Kind, $Fields, [string]$Footer, [switch]$Ping)

    $embed = [ordered]@{
        title     = "$($KindIcon[$Kind]) $Title"
        color     = [int]$EmbedColor[$Kind]
        timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    if ($Message) { $embed.description = $Message }
    if ($Fields -and $Fields.Count -gt 0) {
        $embed.fields = @(foreach ($k in $Fields.Keys) {
            @{ name = [string]$k; value = "``$($Fields[$k])``"; inline = $true }
        })
    }
    $embed.footer = @{ text = $Footer }

    $payload = [ordered]@{ embeds = @($embed) }
    if ($Ping) {
        # ต้องประกาศ allowed_mentions ด้วย ไม่งั้น Discord กลืน @here ที่มาจาก webhook
        $payload.content = '@here'
        $payload.allowed_mentions = @{ parse = @('everyone') }
    }
    return ($payload | ConvertTo-Json -Compress -Depth 8)
}

# ยิงจริงหนึ่งใบ
function Send-Now {
    param(
        [string]$Message,
        [string]$Title  = 'ROOC Monitor',
        [string]$Kind   = 'info',
        $Fields,
        [string]$Footer = 'ROOC Monitor',
        [switch]$Urgent
    )

    if ($script:cfg.NtfyTopic) {
        try {
            $uri = "$($script:cfg.NtfyServer.TrimEnd('/'))/$($script:cfg.NtfyTopic)"
            $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $uri)
            $req.Content = [System.Net.Http.StringContent]::new($Message, [System.Text.Encoding]::UTF8, 'text/plain')
            # HTTP header รับได้แค่ ASCII จึงต้องกรองก่อนใส่
            $safe = ($Title -replace '[^\x20-\x7E]', '').Trim()
            if (-not $safe) { $safe = 'ROOC Monitor' }
            $req.Headers.TryAddWithoutValidation('Title', $safe) | Out-Null
            $req.Headers.TryAddWithoutValidation('Priority', $(if ($Urgent) { 'urgent' } else { 'default' })) | Out-Null
            $req.Headers.TryAddWithoutValidation('Tags', $(if ($Urgent) { 'rotating_light' } else { 'white_check_mark' })) | Out-Null
            [void]$script:pending.Add(@{ Name = 'ntfy'; Task = $script:http.SendAsync($req) })
        } catch { Write-Event "ntfy send failed: $($_.Exception.Message)" 'warn' }
    }

    if ($script:cfg.WebhookUrl) {
        try {
            $json = New-DiscordPayload -Title $Title -Message $Message -Kind $Kind -Fields $Fields `
                                       -Footer $Footer -Ping:($Urgent -and $script:cfg.DiscordHere)
            $c = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, 'application/json')
            [void]$script:pending.Add(@{ Name = 'discord'; Task = $script:http.PostAsync($script:cfg.WebhookUrl, $c) })
        } catch { Write-Event "discord send failed: $($_.Exception.Message)" 'warn' }
    }

    if ($script:cfg.TelegramToken -and $script:cfg.TelegramChatId) {
        try {
            $json = @{ chat_id = $script:cfg.TelegramChatId; text = "$Title`n$Message"
                       disable_notification = (-not $Urgent) } | ConvertTo-Json -Compress
            $c = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, 'application/json')
            $uri = "https://api.telegram.org/bot$($script:cfg.TelegramToken)/sendMessage"
            [void]$script:pending.Add(@{ Name = 'telegram'; Task = $script:http.PostAsync($uri, $c) })
        } catch { Write-Event "telegram send failed: $($_.Exception.Message)" 'warn' }
    }

    if ($script:cfg.Sound -and $Urgent) {
        $wav = @("$env:WINDIR\Media\Alarm01.wav", "$env:WINDIR\Media\Ring01.wav") |
               Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($wav) { try { [System.Media.SoundPlayer]::new($wav).Play() } catch { } }
    }
}

<#
    คิวยิงชุด - ใบแรกไปทันที ที่เหลือทยอยตามทุก BurstGapSec วินาที
    มือถือสั่นหนึ่งทีต่อ notification หนึ่งใบ อยากให้สั่นรัวก็ต้องยิงหลายใบ
    จะสั่งให้สั่นยาวจากฝั่งเราไม่ได้ เพราะ vibration pattern เป็นของ notification channel ฝั่ง OS
#>
$script:burstQueue = [System.Collections.ArrayList]::new()

function Send-Alert {
    param([string]$Message, [string]$Title = 'ROOC Monitor', [string]$Kind = 'info', $Fields, [switch]$Urgent)

    if (-not $Urgent) {
        Send-Now -Message $Message -Title $Title -Kind $Kind -Fields $Fields
        return
    }

    $n = [int]$script:cfg.BurstCount
    if ($n -lt 1) { $n = 1 }
    $gap = [double]$script:cfg.BurstGapSec
    if ($gap -lt 1) { $gap = 1 }

    # ใบที่เท่าไหร่ของชุด ไปอยู่ใน footer ของ embed จะได้ไม่รกตัวข้อความ
    $foot = { param($i) if ($n -gt 1) { "ROOC Monitor  ·  alert $i of $n" } else { 'ROOC Monitor' } }

    Send-Now -Message $Message -Title $Title -Kind $Kind -Fields $Fields -Footer (& $foot 1) -Urgent
    for ($i = 2; $i -le $n; $i++) {
        [void]$script:burstQueue.Add(@{
            At     = (Get-Date).AddSeconds($gap * ($i - 1))
            Msg    = $Message
            Title  = $Title
            Kind   = $Kind
            Fields = $Fields
            Footer = (& $foot $i)
        })
    }
}

# เรียกทุก tick
function Drain-Burst {
    if ($script:burstQueue.Count -eq 0) { return }
    $now = Get-Date
    for ($i = $script:burstQueue.Count - 1; $i -ge 0; $i--) {
        $item = $script:burstQueue[$i]
        if ($now -lt $item.At) { continue }
        Send-Now -Message $item.Msg -Title $item.Title -Kind $item.Kind `
                 -Fields $item.Fields -Footer $item.Footer -Urgent
        $script:burstQueue.RemoveAt($i)
    }
}

function Reap-Sends {
    for ($i = $script:pending.Count - 1; $i -ge 0; $i--) {
        $s = $script:pending[$i]
        if (-not $s.Task.IsCompleted) { continue }
        try {
            if ($s.Task.IsFaulted) {
                Write-Event "$($s.Name) delivery failed: $($s.Task.Exception.InnerException.Message)" 'warn'
            } else {
                $code = [int]$s.Task.Result.StatusCode
                if ($code -ge 300) { Write-Event "$($s.Name) returned HTTP $code" 'warn' }
                $s.Task.Result.Dispose()
            }
        } catch { }
        $script:pending.RemoveAt($i)
    }
}

# ---------------------------------------------------------------- เช็คเน็ต (async)

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

# ---------------------------------------------------------------- สถานะ

$script:watching      = $false
$script:state         = @{}
$script:netAlert      = @{ Active = $false; LastAt = $null; Repeats = 0 }
$script:noProcAlert   = @{ Active = $false; LastAt = $null; Repeats = 0 }
$script:netDownStreak = 0
$script:lastHeartbeat = Get-Date
$script:lastCheck     = [datetime]::MinValue
$script:lastStatus    = @()
$script:reallyExit    = $false

# โหมดซ้อม - ยิงชุดข้อความแบบเดียวกับตอนหลุดจริง รวมถึงการเตือนซ้ำ
# เพื่อพิสูจน์ว่าตอนตีสามมันปลุกติดจริงไหม ปุ่มยิงทีเดียวพิสูจน์แค่ว่าข้อความส่งถึง
$script:drill = @{ Active = $false; Sent = 0; Total = 5; NextAt = $null }

function Test-AlertDue { param($S)
    if (-not $S.Active) { $S.Active = $true; $S.LastAt = Get-Date; return $true }
    if ($script:cfg.RepeatAlertMin -gt 0 -and $S.Repeats -lt $script:cfg.MaxRepeats -and
        ((Get-Date) - $S.LastAt).TotalMinutes -ge $script:cfg.RepeatAlertMin) {
        $S.Repeats++; $S.LastAt = Get-Date; return $true
    }
    return $false
}
function Reset-Alert { param($S) $S.Active = $false; $S.LastAt = $null; $S.Repeats = 0 }

# ---------------------------------------------------------------- XAML

$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ROOC Monitor" Height="700" Width="820" MinHeight="600" MinWidth="720"
        WindowStartupLocation="CenterScreen"
        Background="#14141B" UseLayoutRounding="True" TextOptions.TextFormattingMode="Ideal">

  <Window.Resources>
    <FontFamily x:Key="UiFont">Leelawadee UI, Segoe UI</FontFamily>
    <FontFamily x:Key="MonoFont">Cascadia Mono, Consolas</FontFamily>

    <SolidColorBrush x:Key="Bg"      Color="#14141B"/>
    <SolidColorBrush x:Key="Card"    Color="#1E1F29"/>
    <SolidColorBrush x:Key="CardHi"  Color="#252734"/>
    <SolidColorBrush x:Key="Stroke"  Color="#2E3040"/>
    <SolidColorBrush x:Key="Fg"      Color="#E6E8F2"/>
    <SolidColorBrush x:Key="Muted"   Color="#8B8FA3"/>
    <SolidColorBrush x:Key="Faint"   Color="#5C6076"/>
    <SolidColorBrush x:Key="Green"   Color="#3FD68C"/>
    <SolidColorBrush x:Key="Red"     Color="#FF6B6B"/>
    <SolidColorBrush x:Key="Amber"   Color="#FFC65C"/>
    <SolidColorBrush x:Key="Blue"    Color="#7AA2F7"/>

    <!-- ปุ่มมุมโค้ง มี hover นุ่มๆ -->
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Height" Value="40"/>
      <Setter Property="Padding" Value="20,0"/>
      <Setter Property="Margin" Value="0,0,10,0"/>
      <Setter Property="FontFamily" Value="{StaticResource UiFont}"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="Background" Value="{StaticResource Card}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Stroke}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="10" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1">
              <ContentPresenter Margin="{TemplateBinding Padding}"
                                HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource CardHi}"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="#3D4055"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.75"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ปุ่มหลัก สีพื้น -->
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#101219"/>
      <Setter Property="Background" Value="{StaticResource Green}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Green}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="10" Background="{TemplateBinding Background}">
              <ContentPresenter Margin="{TemplateBinding Padding}"
                                HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.88"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.7"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- การ์ด client -->
    <DataTemplate x:Key="ClientCard">
      <Border Width="238" Height="164" Margin="0,0,14,14" CornerRadius="14"
              Background="{StaticResource Card}" BorderBrush="{StaticResource Stroke}" BorderThickness="1">
        <Border.Effect>
          <DropShadowEffect Color="#000000" BlurRadius="18" ShadowDepth="3" Opacity="0.45"/>
        </Border.Effect>
        <Grid Margin="20,18,20,18">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <StackPanel Orientation="Horizontal" Grid.Row="0">
            <!-- วงกลมสองอันซ้อนกัน สลับ Visibility เอา เพราะ trigger เปลี่ยนสีใน Effect ไม่ได้ -->
            <Grid Width="11" Height="11" VerticalAlignment="Center">
              <Ellipse x:Name="dotOn" Fill="{StaticResource Green}">
                <Ellipse.Effect>
                  <DropShadowEffect Color="#3FD68C" BlurRadius="12" ShadowDepth="0" Opacity="0.9"/>
                </Ellipse.Effect>
              </Ellipse>
              <Ellipse x:Name="dotOff" Fill="{StaticResource Red}" Visibility="Collapsed">
                <Ellipse.Effect>
                  <DropShadowEffect Color="#FF6B6B" BlurRadius="12" ShadowDepth="0" Opacity="0.9"/>
                </Ellipse.Effect>
              </Ellipse>
            </Grid>
            <TextBlock x:Name="statusText" Text="{Binding Status}" Margin="10,0,0,0"
                       FontFamily="{StaticResource UiFont}" FontSize="17" FontWeight="SemiBold"
                       Foreground="{StaticResource Green}" VerticalAlignment="Center"/>
          </StackPanel>

          <TextBlock Grid.Row="1" Text="{Binding PidText}" Margin="0,10,0,0"
                     FontFamily="{StaticResource UiFont}" FontSize="12.5" Foreground="{StaticResource Muted}"/>

          <TextBlock Grid.Row="2" Text="{Binding Endpoint}" Margin="0,12,0,0" VerticalAlignment="Top"
                     FontFamily="{StaticResource MonoFont}" FontSize="12.5" Foreground="{StaticResource Fg}"/>

          <StackPanel Grid.Row="3">
            <TextBlock Text="{Binding Detail}" FontFamily="{StaticResource UiFont}"
                       FontSize="12.5" Foreground="{StaticResource Muted}"/>
            <TextBlock Text="{Binding Since}" Margin="0,3,0,0" FontFamily="{StaticResource UiFont}"
                       FontSize="11.5" Foreground="{StaticResource Faint}"/>
          </StackPanel>
        </Grid>
      </Border>
      <DataTemplate.Triggers>
        <DataTrigger Binding="{Binding Online}" Value="False">
          <Setter TargetName="dotOn"  Property="Visibility" Value="Collapsed"/>
          <Setter TargetName="dotOff" Property="Visibility" Value="Visible"/>
          <Setter TargetName="statusText" Property="Foreground" Value="{StaticResource Red}"/>
        </DataTrigger>
      </DataTemplate.Triggers>
    </DataTemplate>

    <!-- บรรทัด log -->
    <DataTemplate x:Key="EntryRow">
      <Grid Margin="0,0,0,5">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="74"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" Text="{Binding Time}" FontFamily="{StaticResource MonoFont}"
                   FontSize="11.5" Foreground="{StaticResource Faint}"/>
        <TextBlock x:Name="msg" Grid.Column="1" Text="{Binding Message}" TextWrapping="Wrap"
                   FontFamily="{StaticResource UiFont}" FontSize="12.5" Foreground="{StaticResource Muted}"/>
      </Grid>
      <DataTemplate.Triggers>
        <DataTrigger Binding="{Binding Kind}" Value="good">
          <Setter TargetName="msg" Property="Foreground" Value="{StaticResource Green}"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Kind}" Value="bad">
          <Setter TargetName="msg" Property="Foreground" Value="{StaticResource Red}"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Kind}" Value="warn">
          <Setter TargetName="msg" Property="Foreground" Value="{StaticResource Amber}"/>
        </DataTrigger>
      </DataTemplate.Triggers>
    </DataTemplate>
  </Window.Resources>

  <Grid Margin="26,22,26,22">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <!-- หัวเรื่อง -->
    <StackPanel Grid.Row="0">
      <TextBlock Text="Ragnarok Origin Classic" FontFamily="{StaticResource UiFont}"
                 FontSize="25" FontWeight="Bold" Foreground="{StaticResource Fg}"/>
      <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
        <Ellipse x:Name="StateDot" Width="9" Height="9" VerticalAlignment="Center" Fill="{StaticResource Faint}"/>
        <TextBlock x:Name="StateText" Text="Not watching" Margin="9,0,0,0"
                   FontFamily="{StaticResource UiFont}" FontSize="13.5"
                   Foreground="{StaticResource Muted}" VerticalAlignment="Center"/>
      </StackPanel>
    </StackPanel>

    <!-- ปุ่ม -->
    <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,24,0,0">
      <Button x:Name="BtnWatch" Style="{StaticResource BtnPrimary}" Content="Start watching" MinWidth="150"/>
      <Button x:Name="BtnDrill" Style="{StaticResource Btn}" Content="Run drill" Foreground="#FFC65C"/>
      <Button x:Name="BtnTest"  Style="{StaticResource Btn}" Content="Send one" Foreground="#7AA2F7"/>
      <Button x:Name="BtnCfg"   Style="{StaticResource Btn}" Content="Settings"/>
      <Button x:Name="BtnLog"   Style="{StaticResource Btn}" Content="Log" Foreground="#8B8FA3"/>
    </StackPanel>

    <!-- การ์ด -->
    <ItemsControl x:Name="Cards" Grid.Row="2" Margin="0,26,0,0"
                  ItemsSource="{Binding}" ItemTemplate="{StaticResource ClientCard}">
      <ItemsControl.ItemsPanel>
        <ItemsPanelTemplate><WrapPanel Orientation="Horizontal"/></ItemsPanelTemplate>
      </ItemsControl.ItemsPanel>
    </ItemsControl>

    <TextBlock x:Name="EmptyNote" Grid.Row="2" Margin="2,32,0,0" Visibility="Collapsed"
               Text="rooc.exe is not running — start the game first"
               FontFamily="{StaticResource UiFont}" FontSize="14" Foreground="{StaticResource Amber}"/>

    <TextBlock Grid.Row="3" Text="Activity" Margin="2,6,0,10"
               FontFamily="{StaticResource UiFont}" FontSize="12.5" FontWeight="SemiBold"
               Foreground="{StaticResource Faint}"/>

    <!-- log -->
    <Border Grid.Row="4" CornerRadius="14" Background="{StaticResource Card}"
            BorderBrush="{StaticResource Stroke}" BorderThickness="1">
      <ScrollViewer x:Name="LogScroll" Margin="18,14,10,14" VerticalScrollBarVisibility="Auto">
        <ItemsControl x:Name="LogList" ItemsSource="{Binding}" ItemTemplate="{StaticResource EntryRow}"/>
      </ScrollViewer>
    </Border>
  </Grid>
</Window>
'@

<#
    โปรแกรมถูกเรียกจาก .vbs ด้วย nCmdShow = 0 เพื่อไม่ให้มีหน้าต่าง console โผล่เลย
    ผลข้างเคียงคือหน้าต่าง WPF จะถูกสร้างแบบซ่อนตามไปด้วย ทั้งหน้าหลักและหน้าตั้งค่า
    (อาการคือกดปุ่มตั้งค่าแล้วเหมือนแอปค้าง เพราะ ShowDialog block อยู่แต่มองไม่เห็นหน้าต่าง)

    บังคับใน SourceInitialized หรือ Loaded ไม่ได้ผล เพราะ WPF ไปซ่อนทับทีหลัง
    ต้องรอให้ dispatcher เริ่มเดินก่อนแล้วค่อยสั่ง SW_RESTORE ยิงครั้งเดียวพอ
    เรียกก่อน ShowDialog ของทุกหน้าต่าง
#>
function Force-Show {
    param($Window)
    $t = [System.Windows.Threading.DispatcherTimer]::new()
    $t.Interval = [timespan]::FromMilliseconds(200)
    $t.Add_Tick({
        $t.Stop()
        try {
            $hh = [System.Windows.Interop.WindowInteropHelper]::new($Window).Handle
            if ($hh -ne [System.IntPtr]::Zero) { [Win.Native]::ShowWindow($hh, 9) | Out-Null }
        } catch { }
        try {
            if ($Window.WindowState -eq 'Minimized') { $Window.WindowState = 'Normal' }
            $Window.Activate()
        } catch { }
    })
    $t.Start()
}

$reader = [System.Xml.XmlNodeReader]::new(([xml]$xamlText))
$win    = [Windows.Markup.XamlReader]::Load($reader)

$BtnWatch  = $win.FindName('BtnWatch')
$BtnDrill  = $win.FindName('BtnDrill')
$BtnTest   = $win.FindName('BtnTest')
$BtnCfg    = $win.FindName('BtnCfg')
$BtnLog    = $win.FindName('BtnLog')
$StateText = $win.FindName('StateText')
$StateDot  = $win.FindName('StateDot')
$Cards     = $win.FindName('Cards')
$EmptyNote = $win.FindName('EmptyNote')
$LogList   = $win.FindName('LogList')
$LogScroll = $win.FindName('LogScroll')

$Cards.ItemsSource   = $script:clients
$LogList.ItemsSource = $script:entries

$Brush = @{
    Green = $win.FindResource('Green')
    Red   = $win.FindResource('Red')
    Amber = $win.FindResource('Amber')
    Muted = $win.FindResource('Muted')
    Faint = $win.FindResource('Faint')
}

try { if (Test-Path $GameExe) { $win.Icon = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
        ([System.Drawing.Icon]::ExtractAssociatedIcon($GameExe)).Handle,
        [System.Windows.Int32Rect]::Empty,
        [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions()) } } catch { }

$win.Add_SourceInitialized({
    $h = [System.Windows.Interop.WindowInteropHelper]::new($win).Handle

    # แถบชื่อหน้าต่างเป็นสีเข้ม ให้เข้ากับตัวแอป (DWMWA_USE_IMMERSIVE_DARK_MODE = 20)
    try { $on = 1; [Win.Native]::DwmSetWindowAttribute($h, 20, [ref]$on, 4) | Out-Null } catch { }

})

# ---------------------------------------------------------------- log

function Write-Event {
    param([string]$Message, [string]$Kind = 'info')

    $e = [RoocVm.Entry]::new()
    $e.Time    = Get-Date -Format 'HH:mm:ss'
    $e.Message = $Message
    $e.Kind    = $Kind
    $script:entries.Add($e)
    while ($script:entries.Count -gt 300) { $script:entries.RemoveAt(0) }
    try { $LogScroll.ScrollToEnd() } catch { }

    try {
        Add-Content -Path $LogPath -Encoding utf8 `
            -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    } catch { }
}

# ---------------------------------------------------------------- อัปเดตการ์ด

function Sync-Cards {
    param($Status)

    $EmptyNote.Visibility = if ($Status.Count -eq 0) { 'Visible' } else { 'Collapsed' }

    # เอาการ์ดของ PID ที่หายไปออก
    for ($i = $script:clients.Count - 1; $i -ge 0; $i--) {
        if ($Status.Pid -notcontains $script:clients[$i].Pid) { $script:clients.RemoveAt($i) }
    }

    foreach ($s in $Status) {
        $vm = $script:clients | Where-Object { $_.Pid -eq $s.Pid } | Select-Object -First 1
        if (-not $vm) {
            $vm = [RoocVm.Client]::new()
            $vm.Pid = $s.Pid
            $script:clients.Add($vm)
        }
        $vm.Online   = $s.Online
        $vm.Status   = if ($s.Online) { 'ONLINE' } else { 'OFFLINE' }
        $vm.Endpoint = if ($s.Endpoint) { $s.Endpoint } else { '— no game socket —' }

        if ($s.Online -and $s.SessionAt) {
            $vm.Detail = "Connected for {0}" -f (Format-Duration ((Get-Date) - $s.SessionAt))
            $vm.Since  = "since {0}" -f $s.SessionAt.ToString('HH:mm')
        } else {
            $st = $script:state["pid$($s.Pid)"]
            if ($st -and $st.DownSince) {
                $vm.Detail = "Down for {0}" -f (Format-Duration ((Get-Date) - $st.DownSince))
                $vm.Since  = "since {0}" -f $st.DownSince.ToString('HH:mm:ss')
            } else {
                $vm.Detail = 'Checking…'
                $vm.Since  = ''
            }
        }
    }
}

# ---------------------------------------------------------------- รอบตรวจ

function Do-Check {
    $status = @(Get-ClientStatus)
    $script:lastStatus = $status
    $script:lastCheck  = Get-Date

    if (-not $script:watching) { Sync-Cards $status; return }

    if (-not $script:netUp) {
        $script:netDownStreak++
        if ($script:netDownStreak -ge $script:cfg.GraceChecks -and (Test-AlertDue $script:netAlert)) {
            Write-Event 'No internet — the game has probably dropped too' 'bad'
            Send-Alert -Title 'Internet is down' -Kind down -Urgent `
                       -Message 'This PC cannot reach the internet, so the game has almost certainly dropped as well.'
        }
        Sync-Cards $status
        return
    }
    if ($script:netAlert.Active) {
        Write-Event 'Internet is back' 'good'
        Send-Alert -Title 'Internet is back' -Kind up -Message 'The connection recovered.'
        Reset-Alert $script:netAlert
    }
    $script:netDownStreak = 0

    if ($status.Count -eq 0) {
        if (Test-AlertDue $script:noProcAlert) {
            Write-Event 'rooc.exe is gone' 'bad'
            Send-Alert -Title 'Game closed' -Kind down -Urgent `
                       -Message 'No rooc.exe process is running — the game exited or crashed.'
        }
        Sync-Cards $status
        return
    }
    if ($script:noProcAlert.Active) {
        Write-Event 'rooc.exe is running again' 'good'
        Reset-Alert $script:noProcAlert
    }

    foreach ($s in $status) {
        $key = "pid$($s.Pid)"
        if (-not $script:state.ContainsKey($key)) {
            $script:state[$key] = @{
                Misses = 0; Alerted = $false; SessionAt = $s.SessionAt
                LastAlertAt = $null; Repeats = 0; DownSince = $null
            }
            Write-Event "Found client PID $($s.Pid) — $(if ($s.Online) { 'online' } else { 'offline' })"
        }
        $st = $script:state[$key]

        if ($s.Online) {
            # session ใหม่ = เมื่อกี้หลุดแล้วเด้งกลับเองได้ ไม่ต้องปลุก
            if ($st.SessionAt -and $s.SessionAt -and $s.SessionAt -gt $st.SessionAt) {
                Write-Event "PID $($s.Pid) dropped and reconnected on its own at $($s.SessionAt.ToString('HH:mm:ss'))" 'warn'
                Send-Alert -Title 'Reconnected on its own' -Kind warn `
                           -Message 'The client dropped but got back in without help. No action needed.' `
                           -Fields ([ordered]@{
                               'Client'       = "PID $($s.Pid)"
                               'New session'  = $s.SessionAt.ToString('HH:mm:ss')
                               'Server'       = $s.Endpoint
                           })
            }
            $st.SessionAt = $s.SessionAt

            if ($st.Alerted) {
                # DownSince ควรมีค่าเสมอถ้าเคยเตือนไปแล้ว แต่กันไว้เผื่อ state เพี้ยน
                $wasDown = if ($st.DownSince) { Format-Duration ((Get-Date) - $st.DownSince) } else { 'unknown' }
                Write-Event "PID $($s.Pid) is back online" 'good'
                Send-Alert -Title 'Back online' -Kind up `
                           -Message 'The client reconnected to the game server.' `
                           -Fields ([ordered]@{
                               'Client'   = "PID $($s.Pid)"
                               'Was down' = $wasDown
                               'Server'   = $s.Endpoint
                           })
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
                    $down = Format-Duration ((Get-Date) - $st.DownSince)
                    Write-Event "DISCONNECTED — PID $($s.Pid), down $down$(if ($st.Repeats -gt 0) { " (reminder $($st.Repeats))" })" 'bad'
                    Send-Alert -Title 'Client disconnected' -Kind down -Urgent `
                               -Message 'No connection to the game server. You are logged out.' `
                               -Fields ([ordered]@{
                                   'Client'    = "PID $($s.Pid)"
                                   'Down for'  = $down
                                   'Since'     = $st.DownSince.ToString('HH:mm:ss')
                                   'Reminder'  = $(if ($st.Repeats -gt 0) { "#$($st.Repeats)" } else { 'first alert' })
                               })
                    try { $script:tray.ShowBalloonTip(5000, 'Ragnarok Origin', "PID $($s.Pid) disconnected", 'Warning') } catch { }
                }
            }
        }
    }

    if ($script:cfg.HeartbeatHours -gt 0 -and
        ((Get-Date) - $script:lastHeartbeat).TotalHours -ge $script:cfg.HeartbeatHours) {
        $script:lastHeartbeat = Get-Date
        $on = @($status | Where-Object { $_.Online }).Count
        Send-Alert -Title 'Still watching' -Kind info `
                   -Message 'Routine check-in — the monitor is alive and nothing is wrong.' `
                   -Fields ([ordered]@{ 'Online' = "$on of $($status.Count)" })
    }

    $alive = @($status | ForEach-Object { "pid$($_.Pid)" })
    @($script:state.Keys) | Where-Object { $alive -notcontains $_ } | ForEach-Object { $script:state.Remove($_) }

    Sync-Cards $status
}

# ---------------------------------------------------------------- โหมดซ้อม

function Stop-Drill {
    param([string]$Why = 'Drill finished')
    $script:drill.Active = $false
    $script:drill.Sent   = 0
    $script:drill.NextAt = $null
    $script:burstQueue.Clear()     # หยุดซ้อมแล้วใบที่ค้างคิวอยู่ต้องไม่ตามไปยิงต่อ
    $BtnDrill.Content    = 'Run drill'
    Write-Event $Why 'warn'
}

function Step-Drill {
    if (-not $script:drill.Active) { return }
    if ((Get-Date) -lt $script:drill.NextAt) {
        $left = [int]((($script:drill.NextAt) - (Get-Date)).TotalSeconds)
        $BtnDrill.Content = "Stop drill ($($script:drill.Sent)/$($script:drill.Total) · ${left}s)"
        return
    }

    $script:drill.Sent++
    # หน้าตาเหมือนของจริงทุกอย่าง ต่างแค่มี DRILL กำกับ จะได้ไม่ตกใจ
    $target  = if ($script:lastStatus.Count -gt 0) { $script:lastStatus[0].Pid } else { 0 }
    $fakeMin = [math]::Round(
        (($script:cfg.GraceChecks * $script:cfg.IntervalSec) / 60.0) +
        ($script:cfg.RepeatAlertMin * ($script:drill.Sent - 1)), 1)

    Send-Alert -Title 'DRILL — Client disconnected' -Kind warn -Urgent `
               -Message 'This is a practice alert. Nothing is actually wrong.' `
               -Fields ([ordered]@{
                   'Client'   = "PID $target"
                   'Down for' = "$fakeMin min"
                   'Round'    = "$($script:drill.Sent) of $($script:drill.Total)"
               })

    Write-Event "Drill — round $($script:drill.Sent)/$($script:drill.Total) sent" 'warn'

    if ($script:drill.Sent -ge $script:drill.Total) {
        Stop-Drill "Drill complete ($($script:drill.Total) rounds). If that did not wake you, fix the phone side."
        return
    }
    $script:drill.NextAt = (Get-Date).AddMinutes($script:cfg.RepeatAlertMin)
}

# ---------------------------------------------------------------- timer

$timer = [System.Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [timespan]::FromSeconds(1)
$timer.Add_Tick({
    Reap-Sends
    Drain-Burst
    Poll-Internet
    Step-Drill

    if (((Get-Date) - $script:lastCheck).TotalSeconds -ge $script:cfg.IntervalSec) { Do-Check }

    if ($script:watching) {
        $next = [math]::Max(0, [int]$script:cfg.IntervalSec - [int]((Get-Date) - $script:lastCheck).TotalSeconds)
        $on   = @($script:lastStatus | Where-Object { $_.Online }).Count
        $tot  = $script:lastStatus.Count
        $okAll = ($tot -gt 0 -and $on -eq $tot -and $script:netUp)
        $netTxt = if ($script:netUp) { '' } else { '   ·   no internet' }
        $StateText.Text = "Watching   ·   $on of $tot online   ·   next check in ${next}s$netTxt"
        $StateText.Foreground = if ($okAll) { $Brush.Green } else { $Brush.Red }
        $StateDot.Fill        = if ($okAll) { $Brush.Green } else { $Brush.Red }
        try { $script:tray.Text = "ROOC Monitor — $on of $tot online" } catch { }
    }
})

# ---------------------------------------------------------------- หน้าตั้งค่า

$settingsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Settings" Width="560" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" Background="#14141B">
  <Window.Resources>
    <FontFamily x:Key="UiFont">Leelawadee UI, Segoe UI</FontFamily>
    <SolidColorBrush x:Key="Fg"     Color="#E6E8F2"/>
    <SolidColorBrush x:Key="Muted"  Color="#8B8FA3"/>
    <SolidColorBrush x:Key="Faint"  Color="#5C6076"/>
    <SolidColorBrush x:Key="Green"  Color="#3FD68C"/>

    <Style TargetType="TextBlock">
      <Setter Property="FontFamily" Value="{StaticResource UiFont}"/>
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontSize" Value="13"/>
    </Style>
    <Style x:Key="Hint" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="{StaticResource UiFont}"/>
      <Setter Property="Foreground" Value="{StaticResource Faint}"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="Margin" Value="2,4,0,0"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="FontFamily" Value="{StaticResource UiFont}"/>
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="Margin" Value="0,7,0,0"/>
      <Setter Property="Padding" Value="10,0"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="CaretBrush" Value="{StaticResource Fg}"/>
      <Setter Property="Background" Value="#1E1F29"/>
      <Setter Property="BorderBrush" Value="#2E3040"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border CornerRadius="8" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"
                            VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Height" Value="40"/>
      <Setter Property="Width" Value="130"/>
      <Setter Property="Margin" Value="0,0,10,0"/>
      <Setter Property="FontFamily" Value="{StaticResource UiFont}"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="Background" Value="#1E1F29"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="10" Background="{TemplateBinding Background}"
                    BorderBrush="#2E3040" BorderThickness="1">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.85"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <StackPanel Margin="28,20,28,20">
    <TextBlock Text="ntfy topic"/>
    <TextBox x:Name="TbTopic"/>
    <TextBlock Style="{StaticResource Hint}" Text="Subscribe to this exact name in the ntfy app. Keep it private — anyone who knows it can read your alerts."/>

    <TextBlock Text="Discord webhook URL" Margin="0,18,0,0"/>
    <TextBox x:Name="TbHook"/>
    <TextBlock Style="{StaticResource Hint}" Text="Optional. Drop alerts are posted as an embed and ping @here."/>

    <TextBlock Text="Check every (seconds)" Margin="0,18,0,0"/>
    <TextBox x:Name="TbInterval"/>

    <TextBlock Text="Missed checks before alerting" Margin="0,18,0,0"/>
    <TextBox x:Name="TbGrace"/>
    <TextBlock Style="{StaticResource Hint}" Text="Multiplied by the check interval — that is how long a drop must last before you get woken."/>

    <TextBlock Text="Repeat alert every (minutes)" Margin="0,18,0,0"/>
    <TextBox x:Name="TbRepeat"/>
    <TextBlock Style="{StaticResource Hint}" Text="0 = alert once and stay quiet."/>

    <Grid Margin="0,18,0,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="18"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <StackPanel Grid.Column="0">
        <TextBlock Text="Notifications per alert"/>
        <TextBox x:Name="TbBurst"/>
      </StackPanel>
      <StackPanel Grid.Column="2">
        <TextBlock Text="Seconds between them"/>
        <TextBox x:Name="TbBurstGap"/>
      </StackPanel>
    </Grid>
    <TextBlock Style="{StaticResource Hint}"
               Text="Your phone buzzes once per notification, so more notifications means more buzzes. Keep the gap at 3s or more."/>

    <TextBlock Text="Heartbeat every (hours)" Margin="0,18,0,0"/>
    <TextBox x:Name="TbHeartbeat"/>
    <TextBlock Style="{StaticResource Hint}" Text="A quiet 'still watching' ping so silence means all is well, not that the monitor died. 0 = off."/>

    <CheckBox x:Name="CbSound" Margin="0,22,0,0" Foreground="#E6E8F2"
              FontFamily="{StaticResource UiFont}" FontSize="13.5"
              Content="Also play a sound on this PC"/>

    <StackPanel Orientation="Horizontal" Margin="0,26,0,0">
      <Button x:Name="BtnSave" Content="Save" Background="#3FD68C" Foreground="#101219" FontWeight="SemiBold"/>
      <Button x:Name="BtnCancel" Content="Cancel"/>
    </StackPanel>
  </StackPanel>
</Window>
'@

function Show-Settings {
    $r = [System.Xml.XmlNodeReader]::new(([xml]$settingsXaml))
    $d = [Windows.Markup.XamlReader]::Load($r)
    $d.Owner = $win

    $map = @{
        NtfyTopic      = $d.FindName('TbTopic')
        WebhookUrl     = $d.FindName('TbHook')
        IntervalSec    = $d.FindName('TbInterval')
        GraceChecks    = $d.FindName('TbGrace')
        RepeatAlertMin = $d.FindName('TbRepeat')
        BurstCount     = $d.FindName('TbBurst')
        BurstGapSec    = $d.FindName('TbBurstGap')
        HeartbeatHours = $d.FindName('TbHeartbeat')
    }
    foreach ($k in $map.Keys) { $map[$k].Text = [string]$script:cfg[$k] }
    $cb = $d.FindName('CbSound')
    $cb.IsChecked = [bool]$script:cfg.Sound

    $d.Add_SourceInitialized({
        try {
            $h = [System.Windows.Interop.WindowInteropHelper]::new($d).Handle
            $on = 1
            [Win.Native]::DwmSetWindowAttribute($h, 20, [ref]$on, 4) | Out-Null
        } catch { }
    })

    $d.FindName('BtnSave').Add_Click({
        foreach ($k in $map.Keys) {
            $raw = $map[$k].Text.Trim()
            if ($DefaultConfig[$k] -is [int] -or $DefaultConfig[$k] -is [double]) {
                $n = 0.0
                if ([double]::TryParse($raw, [ref]$n)) { $script:cfg[$k] = $n }
            } else {
                $script:cfg[$k] = $raw
            }
        }
        $script:cfg.Sound = [bool]$cb.IsChecked
        Save-Config $script:cfg
        $d.DialogResult = $true
        $d.Close()
    })
    $d.FindName('BtnCancel').Add_Click({ $d.DialogResult = $false; $d.Close() })

    Force-Show $d
    if ($d.ShowDialog()) {
        Write-Event 'Settings saved' 'good'
        Update-WatchButton
    }
}

# ---------------------------------------------------------------- ปุ่ม

function Update-WatchButton {
    if ($script:watching) {
        $BtnWatch.Content    = 'Stop watching'
        $BtnWatch.Background = $Brush.Red
    } else {
        $BtnWatch.Content     = 'Start watching'
        $BtnWatch.Background  = $Brush.Green
        $StateText.Text       = 'Not watching'
        $StateText.Foreground = $Brush.Muted
        $StateDot.Fill        = $Brush.Faint
    }
}

$BtnWatch.Add_Click({
    if ($script:watching) {
        # timer เดินต่อไป เพราะโหมดซ้อมกับการรีเฟรชการ์ดยังต้องใช้
        $script:watching = $false
        Write-Event 'Stopped watching' 'warn'
    } else {
        if ((Get-NotifyChannels).Count -eq 0 -and -not $script:cfg.Sound) {
            [System.Windows.MessageBox]::Show(
                "No alert channel is configured. If a client drops right now, nobody will ever know.`n`n" +
                "Open Settings and fill in an ntfy topic first.",
                'Nothing to alert with', 'OK', 'Warning') | Out-Null
            Show-Settings
            return
        }
        $script:watching = $true
        $script:state.Clear()
        Reset-Alert $script:netAlert
        Reset-Alert $script:noProcAlert
        $script:lastHeartbeat = Get-Date
        $script:lastCheck = [datetime]::MinValue
        Write-Event "Watching — checking every $([int]$script:cfg.IntervalSec)s via $((Get-NotifyChannels) -join ', ')" 'good'
    }
    Update-WatchButton
})

$BtnTest.Add_Click({
    if ((Get-NotifyChannels).Count -eq 0) {
        [System.Windows.MessageBox]::Show('No alert channel is configured. Open Settings first.', 'Not ready', 'OK', 'Warning') | Out-Null
        return
    }
    Send-Alert -Title 'Test alert' -Kind info -Urgent `
               -Message 'If you can see this on your phone, delivery works.' `
               -Fields ([ordered]@{ 'Sent at' = (Get-Date).ToString('HH:mm:ss') })
    Write-Event "Test sent via $((Get-NotifyChannels) -join ', ') — proves delivery, not that it wakes you" 'good'
})

$BtnDrill.Add_Click({
    if ($script:drill.Active) { Stop-Drill 'Drill stopped early'; return }

    if ((Get-NotifyChannels).Count -eq 0) {
        [System.Windows.MessageBox]::Show('No alert channel is configured. Open Settings first.', 'Not ready', 'OK', 'Warning') | Out-Null
        return
    }

    $every = $script:cfg.RepeatAlertMin
    $total = $script:drill.Total
    $burst = [int]$script:cfg.BurstCount
    $ans = [System.Windows.MessageBox]::Show(
        "This fires the real disconnect alert $total times, $every minutes apart — about $([math]::Round($every * ($total - 1), 0)) minutes in total, $($total * $burst) notifications.`n`n" +
        "Leave your phone where it normally sits at night and see whether it actually wakes you.`n`nStart the drill?",
        'Run drill', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }

    $script:drill.Active = $true
    $script:drill.Sent   = 0
    $script:drill.NextAt = Get-Date          # ยิงนัดแรกทันที
    Write-Event "Drill started — $total rounds, $every min apart. Press the button again to stop." 'warn'
})

$BtnCfg.Add_Click({ Show-Settings })
$BtnLog.Add_Click({
    if (Test-Path $LogPath) { Start-Process notepad.exe $LogPath } else { Write-Event 'No log file yet' 'warn' }
})

# ---------------------------------------------------------------- tray

$script:tray         = [System.Windows.Forms.NotifyIcon]::new()
$script:tray.Text    = 'ROOC Monitor'
$script:tray.Visible = $true
try {
    $script:tray.Icon = if (Test-Path $GameExe) { [System.Drawing.Icon]::ExtractAssociatedIcon($GameExe) }
                        else { [System.Drawing.SystemIcons]::Application }
} catch { $script:tray.Icon = [System.Drawing.SystemIcons]::Application }

$menu   = [System.Windows.Forms.ContextMenuStrip]::new()
$miShow = $menu.Items.Add('Open window')
$miExit = $menu.Items.Add('Exit')
$script:tray.ContextMenuStrip = $menu

$miShow.Add_Click({ $win.Show(); $win.WindowState = 'Normal'; $win.Activate() })
$miExit.Add_Click({ $script:reallyExit = $true; $win.Close() })
$script:tray.Add_DoubleClick({ $win.Show(); $win.WindowState = 'Normal'; $win.Activate() })

$win.Add_Closing({
    param($sender, $e)
    # ปิดหน้าต่างตอนกำลังเฝ้า = ย่อลง tray ไม่ใช่ปิดโปรแกรม
    if (-not $script:reallyExit -and $script:watching) {
        $e.Cancel = $true
        $win.Hide()
        try { $script:tray.ShowBalloonTip(3000, 'ROOC Monitor', 'Still watching from the tray', 'Info') } catch { }
    }
})

$win.Add_ContentRendered({
    Write-Event 'Ready'
    if ((Get-NotifyChannels).Count -eq 0) {
        Write-Event 'No alert channel configured — open Settings first' 'warn'
    }
    Do-Check
    if ($script:cfg.AutoStart -and (Get-NotifyChannels).Count -gt 0) {
        $BtnWatch.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    }
})

# เดินตลอดอายุโปรแกรม ตัว tick เช็คเองว่ากำลังเฝ้าอยู่ไหม
$timer.Start()

Force-Show $win
[void]$win.ShowDialog()

$timer.Stop()
$script:tray.Visible = $false
$script:tray.Dispose()
$script:http.Dispose()
