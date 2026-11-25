# Common.ps1 - cấu hình, trạng thái, log, hiển thị lệnh, chạy lệnh ngoài, tải file.
# Viết cho Windows PowerShell 5.1 (không dùng cú pháp riêng của PowerShell 7).

$script:IsWin = ($env:OS -eq 'Windows_NT')
$script:ToolsDir = Join-Path $script:TMM 'tools'
$script:LogDir = Join-Path $script:TMM 'logs'
$script:WorkDir = Join-Path $script:TMM 'work'
$script:ProfileDir = Join-Path $script:TMM 'profiles'
$script:StateFile = Join-Path $script:TMM 'state.json'
$script:ConfigFile = Join-Path $script:TMM 'config.json'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding $false

foreach ($d in @($script:ToolsDir, $script:LogDir, $script:WorkDir, $script:ProfileDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

# ---------------------------------------------------------------- cấu hình
function Get-DefaultConfig {
    return [pscustomobject]@{
        ProxyHostFromDevice  = '10.0.2.2'   # emulator Android Studio nhìn thấy máy host qua 10.0.2.2
        BurpHost             = '127.0.0.1'  # Burp trên máy host
        ProxyPort            = 8080
        FridaVersion         = ''           # '' = bản mới nhất trên pip; hoặc ghi cố định, ví dụ '17.27.0'
        PythonWingetId       = 'Python.Python.3.12'
        BlockQuic            = $true
        BlockIPv6            = $true
        HookWaitSec          = 90
        TrafficWaitSec       = 90
        FlutterAlsoJavaHooks = $false
        Urls                 = [pscustomobject]@{
            PlatformTools   = 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip'
            RootAVD         = 'https://gitlab.com/newbit/rootAVD/-/archive/master/rootAVD-master.zip'
            FridaRelease    = 'https://github.com/frida/frida/releases/download'
            NvisoFlutter    = 'https://raw.githubusercontent.com/NVISOsecurity/disable-flutter-tls-verification/main/disable-flutter-tls.js'
            HttpToolkitBase = 'https://raw.githubusercontent.com/httptoolkit/frida-interception-and-unpinning/main/'
        }
    }
}

function Import-Config {
    $cfg = Get-DefaultConfig
    if (Test-Path $script:ConfigFile) {
        try {
            $user = Get-Content -Raw -Path $script:ConfigFile | ConvertFrom-Json
            foreach ($p in $user.PSObject.Properties) {
                if ($p.Name -eq 'Urls' -and $p.Value) {
                    foreach ($u in $p.Value.PSObject.Properties) {
                        $cfg.Urls | Add-Member -NotePropertyName $u.Name -NotePropertyValue $u.Value -Force
                    }
                } else {
                    $cfg | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
                }
            }
        } catch {
            Write-Host "[!!] config.json lỗi cú pháp, dùng cấu hình mặc định: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    $script:Cfg = $cfg
}

# ---------------------------------------------------------------- trạng thái (state.json)
function Import-State {
    $script:State = [pscustomobject]@{}
    if (Test-Path $script:StateFile) {
        try { $script:State = Get-Content -Raw -Path $script:StateFile | ConvertFrom-Json } catch { }
    }
}

function Get-StateValue([string]$Name) {
    $p = $script:State.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Set-StateValue([string]$Name, $Value) {
    $script:State | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    $json = $script:State | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($script:StateFile, $json, $script:Utf8NoBom)
}

# ---------------------------------------------------------------- log + hiển thị
$script:LogFile = Join-Path $script:LogDir ("session-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$script:CurStage = 'main'
$script:StageCmds = @{}
$script:Report = New-Object System.Collections.ArrayList

function Write-TmmLog([string]$Text) {
    try { [IO.File]::AppendAllText($script:LogFile, $Text + "`r`n", $script:Utf8NoBom) } catch { }
}

function Say([string]$Msg, [string]$Color = 'Gray') {
    Write-Host $Msg -ForegroundColor $Color
    Write-TmmLog $Msg
}
function Ok([string]$m)   { Say "  [ OK ] $m" 'Green' }
function Bad([string]$m)  { Say "  [FAIL] $m" 'Red' }
function Info([string]$m) { Say "  [ .. ] $m" 'Cyan' }
function Warn([string]$m) { Say "  [ !! ] $m" 'Yellow' }
function Hint([string]$m) { Say "         -> $m" 'DarkYellow' }
function Title([string]$m) {
    Say ''
    Say ('=' * 72) 'White'
    Say "  $m" 'White'
    Say ('=' * 72) 'White'
}

# In lệnh ra màn hình (để học) và ghi lại theo giai đoạn (để xuất report).
function Show-Cmd([string]$Cmd) {
    Say "     > $Cmd" 'DarkGray'
    if (-not $script:StageCmds.ContainsKey($script:CurStage)) {
        $script:StageCmds[$script:CurStage] = New-Object System.Collections.ArrayList
    }
    [void]$script:StageCmds[$script:CurStage].Add($Cmd)
}

function Format-Arg([string]$a) {
    if ($a -match '[\s"]') { return '"' + $a + '"' }
    return $a
}

# Chạy chương trình ngoài, trả về các dòng output (string). Không ném lỗi khi exit code != 0.
function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string[]]$Arguments = @(),
        [string]$Display,
        [switch]$Quiet
    )
    if (-not $Display) {
        $name = [IO.Path]::GetFileNameWithoutExtension($Exe)
        $Display = $name + ' ' + (($Arguments | ForEach-Object { Format-Arg $_ }) -join ' ')
    }
    if (-not $Quiet) { Show-Cmd $Display } else { Write-TmmLog "     (quiet) $Display" }
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = @()
    try {
        $out = @(& $Exe @Arguments 2>&1 | ForEach-Object { "$_" })
        $script:LastExit = $LASTEXITCODE
    } catch {
        $out = @("$($_.Exception.Message)")
        $script:LastExit = -1
    } finally {
        $ErrorActionPreference = $old
    }
    if ($out.Count) { Write-TmmLog (($out | Select-Object -First 200) -join "`r`n") }
    return $out
}

# ---------------------------------------------------------------- tương tác với người dùng
$script:AssumeYes = $false
$script:NonInteractive = $false
$script:ManualUsed = $false

function Confirm-Yes([string]$Question, [bool]$Default = $true) {
    if ($script:AssumeYes) { return $true }
    if ($script:NonInteractive) { return $Default }
    $suffix = '[y/N]'
    if ($Default) { $suffix = '[Y/n]' }
    $a = Read-Host "  $Question $suffix"
    if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
    return ($a.Trim().ToLower() -match '^(y|c|co|yes)')
}

# Câu hỏi về sự thật (không bị -Yes tự trả lời). NonInteractive -> giá trị mặc định.
function Ask-YesNo([string]$Question, [bool]$Default = $false) {
    if ($script:NonInteractive) { return $Default }
    $suffix = '[y/N]'
    if ($Default) { $suffix = '[Y/n]' }
    $a = Read-Host "  $Question $suffix"
    Write-TmmLog "  (user) '$a'"
    if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
    return ($a.Trim().ToLower() -match '^(y|c|co|yes)')
}

# Dừng lại chờ người dùng làm 1 việc bằng tay. Enter = đã xong; s = bỏ qua giai đoạn; q = thoát.
function Wait-User([string]$What) {
    if ($script:NonInteractive) { throw 'TMM_SKIP' }
    $script:ManualUsed = $true
    Say ''
    Say "  >>> CẦN BẠN LÀM: $What" 'Magenta'
    $a = Read-Host '  Làm xong bấm [Enter] để kiểm tra lại | s = bỏ qua bước này | q = thoát'
    Write-TmmLog "  (user) '$a'"
    $a = "$a".Trim().ToLower()
    if ($a -eq 'q') { throw 'TMM_QUIT' }
    if ($a -eq 's') { throw 'TMM_SKIP' }
}

function Read-Choice([string]$Prompt, [int]$Max, [int]$Default = 0) {
    while ($true) {
        $a = Read-Host "  $Prompt"
        if ([string]::IsNullOrWhiteSpace($a) -and $Default -gt 0) { return $Default }
        if ($a -eq 'q') { throw 'TMM_QUIT' }
        $n = 0
        if ([int]::TryParse($a, [ref]$n) -and $n -ge 1 -and $n -le $Max) { return $n }
        Warn "Nhập số từ 1 đến $Max (q = thoát)"
    }
}

# ---------------------------------------------------------------- tải file / giải nén
function Enable-Tls12 {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
}

function Get-Download([string]$Url, [string]$OutFile) {
    Enable-Tls12
    Show-Cmd "Invoke-WebRequest '$Url' -OutFile '$OutFile'"
    $dir = Split-Path -Parent $OutFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = "$OutFile.part"
    try {
        $wc = New-Object Net.WebClient
        $wc.Headers.Add('User-Agent', 'TheMythOf_Mobile')
        $wc.DownloadFile($Url, $tmp)
        Move-Item -Force -Path $tmp -Destination $OutFile
        return $true
    } catch {
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
        Bad "Tải thất bại: $Url ($msg)"
        Remove-Item -Force -Path $tmp -ErrorAction SilentlyContinue
        return $false
    }
}

function Expand-ZipTo([string]$Zip, [string]$Dest) {
    Show-Cmd "Expand-Archive '$Zip' -DestinationPath '$Dest'"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path $Dest) { Remove-Item -Recurse -Force -Path $Dest }
    [IO.Compression.ZipFile]::ExtractToDirectory($Zip, $Dest)
}

function Get-ZipEntries([string]$Zip) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($Zip)
    try { return @($z.Entries | ForEach-Object { $_.FullName }) } finally { $z.Dispose() }
}

function Export-ZipEntry([string]$Zip, [string]$Entry, [string]$OutFile) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $e = $z.GetEntry($Entry)
        if (-not $e) { return $false }
        $in = $e.Open()
        $fs = [IO.File]::Create($OutFile)
        try { $in.CopyTo($fs) } finally { $fs.Dispose(); $in.Dispose() }
        return $true
    } finally { $z.Dispose() }
}

function Write-TextLF([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), $script:Utf8NoBom)
}

# ---------------------------------------------------------------- report
function Add-Report([string]$StageId, [string]$StageTitle, [string]$Status, [string]$Msg) {
    [void]$script:Report.Add([pscustomobject]@{ Id = $StageId; Title = $StageTitle; Status = $Status; Msg = $Msg })
}

function Write-Report([string]$Mode) {
    if ($script:Report.Count -eq 0) { return }
    Title "TÓM TẮT ($Mode)"
    foreach ($r in $script:Report) {
        $color = 'Gray'
        switch ($r.Status) { 'OK' { $color = 'Green' } 'FIXED' { $color = 'Green' } 'MANUAL' { $color = 'Green' } 'FAIL' { $color = 'Red' } 'SKIP' { $color = 'Yellow' } }
        Say ("  {0,-7} {1,-44} {2}" -f $r.Status, $r.Title, $r.Msg) $color
    }
    $file = Join-Path $script:LogDir ("report-{0}.md" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# TheMythOf_Mobile - report $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("- Chế độ: ``$Mode``")
    [void]$sb.AppendLine("- Thiết bị: ``$($script:Serial)``  App: ``$(Get-StateValue 'Package')``")
    [void]$sb.AppendLine("- Log đầy đủ: ``$($script:LogFile)``")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('OK = đã sẵn sàng, FIXED = script tự sửa, MANUAL = bạn làm tay rồi script kiểm tra lại.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| Giai đoạn | Kết quả | Ghi chú |')
    [void]$sb.AppendLine('|---|---|---|')
    foreach ($r in $script:Report) { [void]$sb.AppendLine("| $($r.Title) | $($r.Status) | $(($r.Msg -replace '\|', '/')) |") }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Lệnh đã chạy theo từng giai đoạn (để tự làm lại bằng tay)')
    foreach ($r in $script:Report) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("### $($r.Title)")
        [void]$sb.AppendLine('```')
        if ($script:StageCmds.ContainsKey($r.Id)) { foreach ($c in $script:StageCmds[$r.Id]) { [void]$sb.AppendLine($c) } }
        [void]$sb.AppendLine('```')
    }
    [IO.File]::WriteAllText($file, $sb.ToString(), $script:Utf8NoBom)
    Info "Report: $file"
}
