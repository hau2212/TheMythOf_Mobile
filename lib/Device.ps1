# Device.ps1 - Android SDK, adb, chọn thiết bị, quyền root, rootAVD.

$script:Serial = $null
$script:RootMode = $null
$script:Dev = $null

# ---------------------------------------------------------------- SDK / adb / emulator
function Find-Sdk {
    $c = @()
    if ($env:ANDROID_HOME) { $c += $env:ANDROID_HOME }
    if ($env:ANDROID_SDK_ROOT) { $c += $env:ANDROID_SDK_ROOT }
    if ($env:LOCALAPPDATA) { $c += (Join-Path $env:LOCALAPPDATA 'Android\Sdk') }
    foreach ($p in $c) {
        if ($p -and ((Test-Path (Join-Path $p 'platform-tools')) -or (Test-Path (Join-Path $p 'emulator')))) { return $p }
    }
    return $null
}

function Find-Adb {
    if ($env:TMM_ADB) { return $env:TMM_ADB }
    $exe = 'adb'
    if ($script:IsWin) { $exe = 'adb.exe' }
    $cands = @()
    $sdk = Find-Sdk
    if ($sdk) { $cands += (Join-Path (Join-Path $sdk 'platform-tools') $exe) }
    $cands += (Join-Path (Join-Path $script:ToolsDir 'platform-tools') $exe)
    foreach ($c in $cands) { if (Test-Path $c) { return $c } }
    $g = Get-Command adb -ErrorAction SilentlyContinue
    if ($g) { return $g.Source }
    return $null
}

function Find-Emulator {
    if ($env:TMM_EMULATOR) { return $env:TMM_EMULATOR }
    $sdk = Find-Sdk
    if (-not $sdk) { return $null }
    $exe = 'emulator'
    if ($script:IsWin) { $exe = 'emulator.exe' }
    $p = Join-Path (Join-Path $sdk 'emulator') $exe
    if (Test-Path $p) { return $p }
    return $null
}

function Install-PlatformTools {
    $zip = Join-Path $script:ToolsDir 'platform-tools.zip'
    if (-not (Get-Download $script:Cfg.Urls.PlatformTools $zip)) { return $false }
    $tmp = Join-Path $script:ToolsDir 'pt-tmp'
    Expand-ZipTo $zip $tmp
    $dst = Join-Path $script:ToolsDir 'platform-tools'
    if (Test-Path $dst) { Remove-Item -Recurse -Force $dst }
    Move-Item (Join-Path $tmp 'platform-tools') $dst
    Remove-Item -Recurse -Force $tmp
    return $true
}

# ---------------------------------------------------------------- adb wrappers
function Get-AdbBase {
    $a = @()
    if ($script:Serial) { $a += @('-s', $script:Serial) }
    return $a
}

# adb có in lệnh ra màn hình
function Adb {
    $a = @(Get-AdbBase) + @($args)
    return Invoke-Native -Exe $script:AdbExe -Arguments $a -Display ('adb ' + (($args | ForEach-Object { Format-Arg "$_" }) -join ' '))
}

# adb im lặng (dùng khi kiểm tra/polling)
function AdbQ {
    $a = @(Get-AdbBase) + @($args)
    return Invoke-Native -Exe $script:AdbExe -Arguments $a -Quiet
}

# Chạy 1 lệnh với quyền root. Lệnh KHÔNG được chứa dấu nháy đơn/kép; lệnh phức tạp dùng Invoke-RootScript.
function Invoke-Root([string]$Cmd, [switch]$Quiet) {
    $a = @(Get-AdbBase)
    if ($script:RootMode -eq 'magisk') {
        $a += @('shell', "su -c '$Cmd'")
        $disp = "adb shell su -c '$Cmd'"
    } else {
        $a += @('shell', $Cmd)
        $disp = "adb shell $Cmd"
    }
    if ($Quiet) { return Invoke-Native -Exe $script:AdbExe -Arguments $a -Quiet }
    return Invoke-Native -Exe $script:AdbExe -Arguments $a -Display $disp
}

# Ghi nhiều dòng lệnh shell thành file .sh, đẩy lên máy ảo rồi chạy bằng root.
# File cũng được giữ lại trong work\ để bạn đọc / chạy lại bằng tay.
function Invoke-RootScript([string]$Name, [string[]]$Lines, [switch]$Quiet) {
    $local = Join-Path $script:WorkDir "tmm_$Name.sh"
    Write-TextLF $local (($Lines -join "`n") + "`n")
    $remote = "/data/local/tmp/tmm_$Name.sh"
    if (-not $Quiet) {
        Info "Script chạy trên máy ảo (lưu tại work\tmm_$Name.sh):"
        foreach ($l in $Lines) { Show-Cmd "  | $l" }
        Show-Cmd "adb push work\tmm_$Name.sh $remote"
    }
    AdbQ push $local $remote | Out-Null
    return Invoke-Root "sh $remote" -Quiet:$Quiet
}

# ---------------------------------------------------------------- thiết bị
function Get-AdbDevices {
    $out = Invoke-Native -Exe $script:AdbExe -Arguments @('devices') -Quiet
    $list = @()
    foreach ($l in $out) {
        if ($l -match '^(\S+)\s+(device|unauthorized|offline|authorizing)\s*$') {
            $list += [pscustomobject]@{ Serial = $Matches[1]; State = $Matches[2] }
        }
    }
    return $list
}

function Select-Device([switch]$NoPrompt) {
    $devs = @(Get-AdbDevices)
    $ready = @($devs | Where-Object { $_.State -eq 'device' })
    if ($ready.Count -eq 0) {
        $script:Serial = $null
        if (@($devs | Where-Object { $_.State -eq 'unauthorized' }).Count) { return 'unauthorized' }
        if (@($devs | Where-Object { $_.State -ne 'device' }).Count) { return 'offline' }
        return 'none'
    }
    $want = $script:SerialArg
    if (-not $want) { $want = Get-StateValue 'Serial' }
    $pick = $ready | Where-Object { $_.Serial -eq $want } | Select-Object -First 1
    if (-not $pick) {
        if ($ready.Count -eq 1 -or $NoPrompt -or $script:NonInteractive) {
            $pick = $ready[0]
        } else {
            Info 'Có nhiều thiết bị đang kết nối:'
            for ($i = 0; $i -lt $ready.Count; $i++) { Say ("     {0}. {1}" -f ($i + 1), $ready[$i].Serial) }
            $n = Read-Choice 'Chọn thiết bị' $ready.Count 1
            $pick = $ready[$n - 1]
        }
    }
    $script:Serial = $pick.Serial
    return 'ok'
}

function Get-Props {
    $h = @{}
    foreach ($l in (AdbQ shell getprop)) {
        if ($l -match '^\[([^\]]+)\]: \[(.*)\]$') { $h[$Matches[1]] = $Matches[2] }
    }
    return $h
}

function Wait-Boot([int]$TimeoutSec = 180) {
    $end = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $end) {
        if ((Select-Device -NoPrompt) -eq 'ok') {
            $b = (AdbQ shell getprop sys.boot_completed) -join ''
            if ($b.Trim() -eq '1') { return $true }
        }
        Start-Sleep -Seconds 3
    }
    return $false
}

function Get-DeviceInfo {
    $p = Get-Props
    $sdk = 0
    [void][int]::TryParse("$($p['ro.build.version.sdk'])", [ref]$sdk)
    $isEmu = ($script:Serial -like 'emulator-*') -or ($p['ro.kernel.qemu'] -eq '1') -or ($p['ro.boot.qemu'] -eq '1')
    $avd = $null
    if ($isEmu) {
        $n = AdbQ emu avd name
        if ($n.Count -and $n[0] -notmatch 'error|unknown|KO') { $avd = $n[0].Trim() }
    }
    $boot = ((AdbQ shell cat /proc/sys/kernel/random/boot_id) -join '').Trim()
    $script:Dev = [pscustomobject]@{
        Serial = $script:Serial; Sdk = $sdk; Release = $p['ro.build.version.release']
        Abi = $p['ro.product.cpu.abi']; AbiList = $p['ro.product.cpu.abilist']
        Model = $p['ro.product.model']; IsEmulator = $isEmu; Avd = $avd; BootId = $boot
        BuildType = $p['ro.build.type']; Tags = $p['ro.build.tags']; Flavor = $p['ro.build.flavor']
    }
    return $script:Dev
}

# ---------------------------------------------------------------- AVD
function Get-AvdHome {
    if ($env:ANDROID_AVD_HOME) { return $env:ANDROID_AVD_HOME }
    if ($env:ANDROID_USER_HOME) { return (Join-Path $env:ANDROID_USER_HOME 'avd') }
    $h = $env:USERPROFILE
    if (-not $h) { $h = $HOME }
    return (Join-Path (Join-Path $h '.android') 'avd')
}

function Get-AvdList {
    $emu = Find-Emulator
    if (-not $emu) { return @() }
    $out = Invoke-Native -Exe $emu -Arguments @('-list-avds') -Display 'emulator -list-avds'
    return @($out | Where-Object { $_ -and $_ -notmatch '^(INFO|WARNING|ERROR)' } | ForEach-Object { $_.Trim() })
}

function Start-Avd([string]$Name, [switch]$Cold) {
    $emu = Find-Emulator
    $a = @('-avd', $Name)
    if ($Cold) { $a += '-no-snapshot-load' }
    Show-Cmd ('emulator ' + ($a -join ' '))
    Start-Process -FilePath $emu -ArgumentList $a | Out-Null
}

# Đường dẫn ramdisk.img (tương đối với SDK) của AVD, đọc từ config.ini - dùng cho rootAVD.
function Get-AvdRamdiskRel([string]$AvdName) {
    $avdHome = Get-AvdHome
    $avdDir = Join-Path $avdHome "$AvdName.avd"
    $ini = Join-Path $avdHome "$AvdName.ini"
    if (Test-Path $ini) {
        foreach ($l in (Get-Content $ini)) { if ($l -match '^path=(.+)$') { $avdDir = $Matches[1].Trim() } }
    }
    $cfgIni = Join-Path $avdDir 'config.ini'
    if (-not (Test-Path $cfgIni)) { return $null }
    foreach ($l in (Get-Content $cfgIni)) {
        if ($l -match '^image\.sysdir\.1\s*=\s*(.+)$') {
            $rel = $Matches[1].Trim().Replace('/', '\').TrimEnd('\')
            return "$rel\ramdisk.img"
        }
    }
    return $null
}

# ---------------------------------------------------------------- root
# Kết quả: 'adbd' (adb root), 'magisk' (su -c), 'none'
function Get-RootMode([switch]$Probe) {
    if ($script:RootMode -and -not $Probe) { return $script:RootMode }
    $id = (AdbQ shell id) -join ' '
    if ($id -match 'uid=0\(') { $script:RootMode = 'adbd'; return 'adbd' }
    $su = (AdbQ shell 'su -c id') -join ' '
    if ($su -match 'uid=0\(') { $script:RootMode = 'magisk'; return 'magisk' }
    $script:RootMode = 'none'
    return 'none'
}

function Test-MagiskApp {
    $l = (AdbQ shell pm list packages com.topjohnwu.magisk) -join ' '
    return ($l -match 'com\.topjohnwu\.magisk')
}

function Get-RootAvdDir {
    $base = Join-Path $script:ToolsDir 'rootAVD'
    $dir = Get-ChildItem -Path $base -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'rootAVD.bat') } | Select-Object -First 1
    if ($dir) { return $dir.FullName }
    $zip = Join-Path $script:ToolsDir 'rootAVD.zip'
    if (-not (Get-Download $script:Cfg.Urls.RootAVD $zip)) { return $null }
    Expand-ZipTo $zip $base
    $dir = Get-ChildItem -Path $base -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'rootAVD.bat') } | Select-Object -First 1
    if ($dir) { return $dir.FullName }
    return $null
}

function Invoke-RootAvd {
    $d = Get-DeviceInfo
    if (-not $d.IsEmulator) {
        Bad 'Thiết bị không phải emulator: script không tự root máy thật.'
        Hint 'Máy thật: root bằng Magisk theo hướng dẫn riêng của dòng máy (unlock bootloader, patch boot.img).'
        Wait-User 'Root máy bằng Magisk, mở Magisk và cấp quyền Superuser cho Shell'
        return
    }
    $avd = $d.Avd
    if (-not $avd) { $avd = Get-StateValue 'AvdName' }
    $rel = $null
    if ($avd) { $rel = Get-AvdRamdiskRel $avd }
    if (-not $rel) {
        Bad "Không đọc được đường dẫn ramdisk.img của AVD '$avd'."
        Hint 'Mở tools\rootAVD-...\, chạy: rootAVD.bat ListAllAVDs  rồi chạy lệnh nó gợi ý cho AVD đang bật.'
        Wait-User 'Chạy rootAVD bằng tay theo gợi ý trên'
        return
    }
    Info "AVD: $avd  |  Android $($d.Release) (API $($d.Sdk))  |  image: $rel"
    Warn 'rootAVD sẽ patch ramdisk.img trong Android SDK (có tạo bản backup .backup).'
    Warn 'Mọi AVD dùng chung system image này cũng sẽ có Magisk sau khi cold boot.'
    if (-not (Confirm-Yes 'Tải và chạy rootAVD ngay bây giờ?')) { throw 'TMM_SKIP' }
    $dir = Get-RootAvdDir
    if (-not $dir) { Wait-User 'Tải rootAVD bằng tay từ https://gitlab.com/newbit/rootAVD và giải nén vào tools\rootAVD\'; return }
    $sdk = Find-Sdk
    if ($sdk) { $env:ANDROID_HOME = $sdk }
    $env:ANDROID_SERIAL = $script:Serial
    $adbDir = Split-Path -Parent $script:AdbExe
    if ($env:PATH -notlike "*$adbDir*") { $env:PATH = "$adbDir;$env:PATH" }
    Info 'rootAVD bắt đầu. Nếu nó hỏi chọn phiên bản Magisk: chọn bản stable (thường bấm Enter là được).'
    Show-Cmd "cd `"$dir`""
    Show-Cmd "rootAVD.bat $rel"
    Push-Location $dir
    try { & cmd.exe /c "rootAVD.bat $rel" } finally { Pop-Location }
    Info 'rootAVD xong. Đợi AVD tắt rồi cold boot lại...'
    $end = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $end -and (@(Get-AdbDevices | Where-Object { $_.Serial -eq $script:Serial }).Count)) { Start-Sleep 3 }
    if (@(Get-AdbDevices | Where-Object { $_.Serial -eq $script:Serial }).Count) { Adb emu kill | Out-Null; Start-Sleep 5 }
    Start-Avd $avd -Cold
    Info 'Đang chờ máy ảo boot (cold boot, có thể mất 1-3 phút)...'
    if (-not (Wait-Boot 240)) { Wait-User 'Máy ảo chưa boot xong. Mở lại AVD bằng Device Manager > Cold Boot Now' }
    if (-not (Test-MagiskApp)) {
        $mz = Get-ChildItem -Path $dir -Filter 'Magisk*.zip' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($mz) {
            $apk = Join-Path $script:WorkDir 'Magisk.apk'
            Copy-Item -Force $mz.FullName $apk
            Info 'Cài app Magisk (file Magisk.zip của rootAVD chính là APK)'
            Adb install -r $apk | Out-Null
        }
    }
    Wait-User ('Mở app Magisk trên máy ảo. Nếu nó báo "Requires Additional Setup" bấm OK (máy sẽ reboot, đợi boot xong). ' +
        'Khi bấm Enter, script sẽ gọi su: trên máy ảo hiện popup Superuser Request -> bấm GRANT trong 10 giây.')
}
