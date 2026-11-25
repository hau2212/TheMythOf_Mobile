<#
  TheMythOf_Mobile - bắt HTTPS của app Android (kể cả Flutter) qua Burp Suite trên emulator.

  Double-click Start.cmd để mở menu, hoặc chạy trực tiếp:
    .\mobile.ps1                 menu
    .\mobile.ps1 auto            chạy từ đầu đến cuối, dừng ở bước cần bạn làm tay
    .\mobile.ps1 resume          sau khi tắt/mở máy ảo: kiểm tra + khôi phục cấu hình bị mất
    .\mobile.ps1 check           chỉ kiểm tra, không sửa gì
    .\mobile.ps1 learn           hướng dẫn từng bước, bạn tự gõ lệnh, script kiểm tra
    .\mobile.ps1 app             chọn / cài app khác
    .\mobile.ps1 hook            chạy Frida vào app đang chọn
    .\mobile.ps1 flutter-scan    tìm pattern mới cho libflutter.so (khi báo "could not be located")
    .\mobile.ps1 clean           gỡ iptables, tắt frida-server, gỡ proxy hệ thống
    .\mobile.ps1 prefetch        tải trước mọi công cụ
    .\mobile.ps1 update-hooks    tải lại script hook mới nhất (NVISO, HTTP Toolkit)

  Tuỳ chọn: -Package <id>  -Serial <emulator-5554>  -Yes (tự đồng ý)  -NonInteractive
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'auto', 'resume', 'check', 'learn', 'app', 'hook', 'flutter-scan', 'clean', 'prefetch', 'update-hooks')]
    [string]$Action = 'menu',
    [string]$Package,
    [string]$Serial,
    [switch]$Yes,
    [switch]$NonInteractive
)

# Lưu tham số trước khi nạp lib (lib có biến script trùng tên như $Serial, $NonInteractive).
$argPackage = $Package
$argSerial = $Serial
$argYes = [bool]$Yes
$argNonInteractive = [bool]$NonInteractive

$ErrorActionPreference = 'Continue'
$script:TMM = $PSScriptRoot
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
if ($env:OS -eq 'Windows_NT') {
    # File tải từ GitHub bị Windows đánh dấu "từ Internet": gỡ để PowerShell không chặn.
    Get-ChildItem -Path $PSScriptRoot -Recurse -File -Include '*.ps1', '*.cmd', '*.py' -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
}

foreach ($f in @('Common', 'Device', 'Burp', 'App', 'Frida', 'Redirect', 'Stages')) {
    . (Join-Path (Join-Path $PSScriptRoot 'lib') "$f.ps1")
}

Import-Config
Import-State
$script:PackageArg = $argPackage
$script:SerialArg = $argSerial
$script:AssumeYes = $argYes
$script:NonInteractive = $argNonInteractive

function Reset-Run {
    $script:Report = New-Object System.Collections.ArrayList
    $script:StageCmds = @{}
    $script:HookResult = $null
    $script:CurStage = 'main'
}

function Invoke-Action([string]$Name) {
    Reset-Run
    try {
        switch ($Name) {
            'auto' {
                [void](Invoke-Pipeline 'auto' 'auto')
            }
            'resume' {
                Info 'Resume: kiểm tra lại từng thứ bị mất khi máy ảo khởi động lại (frida-server, iptables, CA tạm, UID app) và làm lại.'
                $ok = Invoke-Pipeline 'resume' 'auto'
                if ($ok -and (Confirm-Yes 'Mọi thứ đã sẵn sàng. Chạy hook vào app ngay?')) {
                    [void](Invoke-Stage $script:StageDefs['hook'] 'auto')
                }
            }
            'check' {
                [void](Invoke-Pipeline 'check' 'check')
            }
            'learn' {
                Say ''
                Say '  CHẾ ĐỘ LEARN: mỗi giai đoạn script giải thích, in lệnh để bạn tự gõ ở cửa sổ PowerShell khác,' 'White'
                Say '  bạn bấm Enter thì script kiểm tra. Gõ a nếu muốn script tự làm bước đó.' 'White'
                [void](Invoke-Pipeline 'learn' 'learn')
            }
            'app' {
                if (Invoke-Pipeline 'base' 'auto') {
                    $script:CurStage = 'app'
                    Title 'Chọn / cài app'
                    $sel = Select-App
                    $prof = Update-AppProfile $sel -Force
                    if ($prof) {
                        Set-StateValue 'Package' $sel
                        $script:App = $prof
                        Show-AppWarnings $prof
                        Ok "Đã chọn $sel | $($prof.Framework) | uid $($prof.Uid) | hook: $($prof.Hook)"
                        Add-Report 'app' 'Chọn app' 'OK' "$sel ($($prof.Framework))"
                        if (Confirm-Yes 'Cấu hình iptables + chạy hook cho app này luôn?') {
                            $script:PackageArg = $sel
                            [void](Invoke-Pipeline 'hook' 'auto')
                        }
                    }
                }
            }
            'hook' {
                [void](Invoke-Pipeline 'hook' 'auto')
            }
            'flutter-scan' {
                if (Invoke-Pipeline 'base' 'auto') {
                    if (Invoke-Stage $script:StageDefs['app'] 'auto') {
                        $script:CurStage = 'flutter-scan'
                        Title 'flutter-scan: tìm pattern ssl_verify_peer_cert'
                        $ok = Invoke-FlutterScan
                        $st = 'FAIL'
                        if ($ok) { $st = 'OK' }
                        Add-Report 'flutter-scan' 'flutter-scan' $st (Split-Path -Leaf (Get-ExtraPatternsFile))
                    }
                }
            }
            'clean' {
                if (Invoke-Pipeline 'base' 'auto') {
                    $script:CurStage = 'clean'
                    Title 'Clean'
                    $ok = Clear-Redirect
                    Invoke-Root 'pkill -f frida-server' | Out-Null
                    $px = Get-SystemProxy
                    if ($px -and $px -notin @('null', ':0')) {
                        if (Confirm-Yes "Gỡ proxy hệ thống '$px'?") { Adb shell settings put global http_proxy :0 | Out-Null }
                    }
                    Info 'CA inject tạm sẽ tự mất khi reboot máy ảo (không cần gỡ).'
                    $st = 'FAIL'
                    if ($ok) { $st = 'OK' }
                    Add-Report 'clean' 'Clean' $st 'gỡ chain TMM_*, rule DNAT/REJECT cũ, tắt frida-server'
                }
            }
            'prefetch' {
                if (Invoke-Stage $script:StageDefs['host'] 'auto') {
                    $script:CurStage = 'prefetch'
                    Title 'Prefetch: tải trước công cụ vào tools\'
                    $okHooks = Update-HookSources -Force
                    $v = Get-FridaClientVersion
                    foreach ($arch in @('x86_64', 'arm64')) { [void](Get-FridaServerFile $v $arch) }
                    $okRoot = [bool](Get-RootAvdDir)
                    $st = 'OK'
                    if (-not ($okHooks -and $okRoot)) { $st = 'FAIL' }
                    Add-Report 'prefetch' 'Prefetch' $st "frida-server $v (x86_64, arm64) | rootAVD: $okRoot | script hook: $okHooks"
                }
            }
            'update-hooks' {
                $script:CurStage = 'update-hooks'
                Title 'Tải lại script hook'
                $ok = Update-HookSources -Force
                $st = 'FAIL'
                if ($ok) { $st = 'OK' }
                Add-Report 'update-hooks' 'Update hooks' $st 'tools\hooks\'
            }
        }
    } catch {
        if ("$($_.Exception.Message)" -eq 'TMM_QUIT') { Warn 'Đã dừng theo yêu cầu.' }
        else { Bad "Lỗi: $($_.Exception.Message)"; Write-TmmLog ($_ | Out-String) }
    } finally {
        Write-Report $Name
    }
}

function Show-Status {
    $adb = Find-Adb
    if (-not $adb) { Say '  Trạng thái: chưa có adb (chọn 1 để script tự cài)' 'DarkGray'; return }
    $script:AdbExe = $adb
    $r = Select-Device -NoPrompt
    if ($r -ne 'ok') { Say '  Trạng thái: chưa có máy ảo nào đang chạy' 'DarkGray'; return }
    $boot = ((AdbQ shell cat /proc/sys/kernel/random/boot_id) -join '').Trim()
    $pkg = Get-StateValue 'Package'
    if (-not $pkg) { $pkg = '(chưa chọn)' }
    Say "  Thiết bị: $($script:Serial)   App: $pkg" 'DarkGray'
    $prev = Get-StateValue 'BootId'
    if ($prev -and $boot -and $prev -ne $boot) {
        Say '  >> Máy ảo đã khởi động lại từ lần cấu hình trước: chọn 2 (Resume) để khôi phục.' 'Yellow'
    }
}

function Show-Menu {
    while ($true) {
        Title 'TheMythOf_Mobile - bắt HTTPS app Android qua Burp'
        Show-Status
        Say ''
        Say '   1. Auto          chạy từ đầu đến cuối (dừng ở bước cần bạn làm)'
        Say '   2. Resume        sau khi tắt/mở máy ảo: kiểm tra + khôi phục cấu hình bị mất'
        Say '   3. Check         chỉ kiểm tra, không sửa'
        Say '   4. Learn         hướng dẫn từng bước, bạn tự gõ lệnh'
        Say '   5. App           chọn / cài app khác'
        Say '   6. Hook          chạy Frida vào app đang chọn'
        Say '   7. Flutter-scan  tìm pattern mới khi Flutter báo "could not be located"'
        Say '   8. Clean         gỡ iptables, tắt frida-server'
        Say '   9. Prefetch      tải trước toàn bộ công cụ'
        Say '   0. Thoát'
        $a = Read-Host '  Chọn'
        $map = @{ '1' = 'auto'; '2' = 'resume'; '3' = 'check'; '4' = 'learn'; '5' = 'app'; '6' = 'hook'; '7' = 'flutter-scan'; '8' = 'clean'; '9' = 'prefetch' }
        if ($a -eq '0' -or $a -eq 'q') { return }
        if ($map.ContainsKey("$a")) { Invoke-Action $map["$a"] } else { Warn 'Chọn 0-9' }
    }
}

Say "TheMythOf_Mobile | log: $($script:LogFile)" 'DarkGray'
if ($Action -eq 'menu') { Show-Menu } else { Invoke-Action $Action }
