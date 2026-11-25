# Stages.ps1 - 9 giai đoạn. Mỗi giai đoạn có:
#   Why   : giải thích ngắn
#   Check : kiểm tra -> New-Result Ok/Msg/Hint
#   Fix   : tự sửa (hoặc dừng chờ bạn làm tay)
#   Learn : in các lệnh để bạn tự gõ (chế độ learn)

$script:HookResult = $null
$script:Rebooted = $false

function New-Result([bool]$Ok, [string]$Msg, [string]$Hint = '') {
    return [pscustomobject]@{ Ok = $Ok; Msg = $Msg; Hint = $Hint }
}

# In 1 lệnh hướng dẫn (chế độ learn)
function L([string]$Cmd, [string]$Comment = '') {
    $line = "     PS> $Cmd"
    if ($Comment) { $line = $line.PadRight(64) + "  # $Comment" }
    Say $line 'Yellow'
}
function LNote([string]$Text) { Say "     $Text" 'DarkCyan' }

function Get-PH { return "$($script:Cfg.ProxyHostFromDevice):$($script:Cfg.ProxyPort)" }
function Get-SuPrefix { if ($script:RootMode -eq 'magisk') { return 'adb shell su -c ' } return 'adb shell ' }

$script:StageDefs = [ordered]@{}

# ==================================================================== 1. HOST
$script:StageDefs['host'] = [pscustomobject]@{
    Id = 'host'; Title = '1. Host: adb, Python, Frida'; Critical = $true; RetryRunsFix = $false
    Why = @('Máy Windows cần adb (điều khiển máy ảo) và frida-tools (client Frida).',
        'Frida cài trong tools\venv (Python riêng của toolkit) nên version cố định, không lo PATH.')
    Check = {
        $script:AdbExe = Find-Adb
        if (-not $script:AdbExe) { return New-Result $false 'Không tìm thấy adb' 'Script sẽ tải Android platform-tools vào tools\platform-tools' }
        $v = Invoke-Native -Exe $script:AdbExe -Arguments @('version') -Display 'adb version'
        $adbVer = (($v | Where-Object { $_ -match 'version' } | Select-Object -First 1) -replace '.*version\s*', '')
        $py = Find-Python
        if (-not $py) { return New-Result $false 'Không tìm thấy Python 3' 'Script sẽ cài bằng winget (hỏi trước) hoặc bạn cài từ python.org' }
        $fv = Get-FridaClientVersion
        if (-not $fv) { return New-Result $false 'Chưa có frida trong tools\venv' 'Script sẽ tạo venv và pip install frida frida-tools' }
        if ($script:Cfg.FridaVersion -and $fv -ne $script:Cfg.FridaVersion) { return New-Result $false "frida $fv khác bản trong config.json ($($script:Cfg.FridaVersion))" }
        $script:FridaVersion = $fv
        return New-Result $true "adb $adbVer | Python OK | frida $fv"
    }
    Fix = {
        if (-not (Find-Adb)) {
            if (Confirm-Yes 'Tải Android platform-tools (~7 MB) vào tools\platform-tools?') { [void](Install-PlatformTools) }
            else { Wait-User 'Cài Android SDK Platform-Tools: Android Studio > SDK Manager > SDK Tools' }
        }
        $script:AdbExe = Find-Adb
        if (-not (Find-Python)) { Install-Python }
        if (Find-Python) { [void](Install-FridaVenv) }
    }
    Learn = {
        LNote 'adb nằm trong Android SDK: %LOCALAPPDATA%\Android\Sdk\platform-tools'
        L 'adb version'
        L 'py --version' 'cần Python 3'
        L 'py -m venv tools\venv' 'môi trường Python riêng'
        L 'tools\venv\Scripts\python -m pip install frida frida-tools'
        L 'tools\venv\Scripts\frida --version'
        LNote 'Mẹo: tạo alias trong cửa sổ PowerShell bạn đang gõ để dùng tên ngắn:'
        $a = Find-Adb
        if ($a) { L "Set-Alias adb '$a'" }
        L ("Set-Alias frida '" + (Get-VenvBin 'frida') + "'")
        L ("Set-Alias frida-ps '" + (Get-VenvBin 'frida-ps') + "'")
    }
}

# ==================================================================== 2. DEVICE
function Show-AvdManual {
    Say '     Tạo máy ảo trong Android Studio:' 'White'
    Say '       Device Manager > + (Create Virtual Device) > chọn Pixel bất kỳ > Next'
    Say '       System image x86_64, chọn 1 trong 2:'
    Say '         - "Google APIs" (API 33/34): có sẵn adb root -> KHÔNG cần Magisk. Không có Play Store.'
    Say '         - "Google Play": có Play Store để cài app, script sẽ root bằng rootAVD + Magisk.'
    Say '       Finish > bấm nút Play để bật máy ảo.'
}

$script:StageDefs['device'] = [pscustomobject]@{
    Id = 'device'; Title = '2. Máy ảo Android'; Critical = $true; RetryRunsFix = $false
    Why = @('Cần 1 máy ảo đang chạy và adb nhìn thấy. Script nhớ serial + boot_id để biết máy ảo đã khởi động lại hay chưa.')
    Check = {
        Show-Cmd 'adb devices'
        $r = Select-Device
        if ($r -eq 'unauthorized') { return New-Result $false 'Thiết bị chưa cho phép adb (unauthorized)' 'Trên máy: bấm Allow USB debugging' }
        if ($r -eq 'offline') { return New-Result $false 'Thiết bị offline' 'Đợi máy ảo boot xong hoặc chạy: adb kill-server' }
        if ($r -ne 'ok') { return New-Result $false 'Chưa có máy ảo nào đang chạy' 'Script sẽ liệt kê AVD để bật' }
        $b = ((AdbQ shell getprop sys.boot_completed) -join '').Trim()
        if ($b -ne '1') {
            Info 'Máy ảo đang boot, đợi...'
            if (-not (Wait-Boot 180)) { return New-Result $false 'Máy ảo chưa boot xong' }
        }
        Show-Cmd 'adb shell getprop   (sys.boot_completed, ro.build.version.sdk, ro.product.cpu.abi)'
        Show-Cmd 'adb shell cat /proc/sys/kernel/random/boot_id'
        $d = Get-DeviceInfo
        $prev = Get-StateValue 'BootId'
        $script:Rebooted = [bool]($prev -and $d.BootId -and $prev -ne $d.BootId)
        Set-StateValue 'Serial' $d.Serial
        if ($d.Avd) { Set-StateValue 'AvdName' $d.Avd }
        if ($script:Rebooted) {
            Warn 'Máy ảo đã KHỞI ĐỘNG LẠI so với lần cấu hình trước: frida-server, iptables và CA tạm đã mất.'
            Hint 'Các giai đoạn sau sẽ phát hiện và làm lại (đó chính là chế độ resume).'
        }
        $avd = ''
        if ($d.Avd) { $avd = " | AVD $($d.Avd)" }
        return New-Result $true "$($d.Serial) | Android $($d.Release) (API $($d.Sdk)) | $($d.Abi)$avd"
    }
    Fix = {
        $avds = @(Get-AvdList)
        if (-not $avds.Count) {
            Show-AvdManual
            Wait-User 'Tạo AVD trong Android Studio (không cần bật), rồi bấm Enter'
            $avds = @(Get-AvdList)
            if (-not $avds.Count) { return }
        }
        $name = $avds[0]
        if ($avds.Count -gt 1) {
            $def = [Array]::IndexOf($avds, (Get-StateValue 'AvdName')) + 1
            for ($i = 0; $i -lt $avds.Count; $i++) { Say ("     {0}. {1}" -f ($i + 1), $avds[$i]) }
            $name = $avds[(Read-Choice "Chọn AVD để bật (Enter = $([Math]::Max($def,1)))" $avds.Count ([Math]::Max($def, 1))) - 1]
        }
        Start-Avd $name
        Info "Đợi $name boot (tối đa 4 phút)..."
        if (-not (Wait-Boot 240)) { Wait-User 'Máy ảo chưa boot xong. Đợi màn hình chính hiện ra rồi bấm Enter' }
    }
    Learn = {
        L 'adb devices' 'thấy emulator-5554  device là OK'
        L 'emulator -list-avds' '(trong %LOCALAPPDATA%\Android\Sdk\emulator)'
        L 'emulator -avd <TEN_AVD>' 'bật máy ảo; thêm -no-snapshot-load để cold boot'
        L 'adb shell getprop sys.boot_completed' '1 = boot xong'
        L 'adb shell getprop ro.build.version.sdk' 'API level (34 = Android 14)'
        L 'adb shell getprop ro.product.cpu.abi' 'x86_64 / arm64-v8a'
        L 'adb shell cat /proc/sys/kernel/random/boot_id' 'đổi mỗi lần máy ảo khởi động lại'
    }
}

# ==================================================================== 3. ROOT
$script:StageDefs['root'] = [pscustomobject]@{
    Id = 'root'; Title = '3. Quyền root'; Critical = $true; RetryRunsFix = $false
    Why = @('iptables, frida-server và cài CA vào system đều cần root.',
        'Image "Google APIs": dùng adb root. Image "Google Play": cần Magisk (script root bằng rootAVD).')
    Check = {
        Show-Cmd 'adb shell id   ;   adb shell su -c id'
        $m = Get-RootMode -Probe
        if ($m -eq 'none') { return New-Result $false 'Chưa có quyền root' 'Script sẽ thử adb root, không được thì root bằng rootAVD + Magisk' }
        Set-StateValue 'RootMode' $m
        $how = 'adb root (adbd chạy bằng root)'
        if ($m -eq 'magisk') { $how = 'Magisk su' }
        return New-Result $true "Có root qua $how"
    }
    Fix = {
        $o = (Adb root) -join ' '
        if ($o -match 'restarting adbd as root|already running as root') {
            Adb wait-for-device | Out-Null
            Start-Sleep -Seconds 3
            [void](Select-Device -NoPrompt)
            return
        }
        Info 'adb root không dùng được trên image này (production build / Google Play).'
        if (Test-MagiskApp) {
            Wait-User ('Máy ảo đã có Magisk. Mở app Magisk > tab Superuser: cho phép Shell. ' +
                'Khi bấm Enter, nếu máy ảo hiện popup Superuser Request thì bấm GRANT')
            return
        }
        Invoke-RootAvd
    }
    Learn = {
        L 'adb shell id' 'uid=0(root) => đã root sẵn'
        L 'adb root' 'image Google APIs: chuyển adbd sang root'
        L 'adb shell su -c id' 'Magisk: uid=0(root) (lần đầu phải bấm Grant trên máy)'
        LNote 'Image Google Play chưa root -> rootAVD (https://gitlab.com/newbit/rootAVD):'
        L 'cd tools\rootAVD\rootAVD-master'
        L '.\rootAVD.bat ListAllAVDs' 'in sẵn lệnh cho từng AVD'
        $rel = $null
        if ($script:Dev -and $script:Dev.Avd) { $rel = Get-AvdRamdiskRel $script:Dev.Avd }
        if (-not $rel) { $rel = 'system-images\android-34\google_apis_playstore\x86_64\ramdisk.img' }
        L ".\rootAVD.bat $rel" 'AVD phải đang chạy'
        LNote 'Sau đó: Cold Boot AVD > mở app Magisk (Additional Setup -> OK) > adb shell su -c id > Grant'
    }
}

# ==================================================================== 4. BURP
$script:StageDefs['burp'] = [pscustomobject]@{
    Id = 'burp'; Title = '4. Burp Suite (listener + CA)'; Critical = $false; RetryRunsFix = $false
    Why = @('Burp phải nghe ở cổng proxy và bật "Support invisible proxying" (vì traffic bị DNAT tới thẳng, không có CONNECT).',
        'Script tự thử bắt tay TLS như máy ảo sẽ làm, rồi tải CA của Burp và tính hash tên file (<hash>.0).')
    Check = {
        $h = $script:Cfg.BurpHost; $p = $script:Cfg.ProxyPort
        if (-not (Test-TcpPort $h ([int]$p))) { return New-Result $false "Burp chưa lắng nghe ${h}:$p" 'Mở Burp, bật listener cổng proxy' }
        $t = Test-BurpInvisible
        if (-not $t.Ok) { return New-Result $false "Burp không bắt tay TLS trực tiếp được ($($t.Error))" 'Chưa tick "Support invisible proxying" cho listener' }
        if ($t.Issuer -notmatch 'PortSwigger') { Warn "Cert do '$($t.Issuer)' cấp, không phải PortSwigger (có upstream proxy / CA tuỳ chỉnh?)" }
        $c = Get-BurpCa
        if (-not $c) { return New-Result $false "Không tải được CA từ http://${h}:$p/cert" }
        $exp = ''
        if ($c.NotAfter) { $exp = " (hết hạn $($c.NotAfter.ToString('yyyy-MM-dd')))" }
        return New-Result $true "${h}:$p | invisible proxying BẬT | CA $($c.Hash).0$exp"
    }
    Fix = {
        Show-BurpManual
        Wait-User 'Cấu hình Burp như trên rồi bấm Enter'
    }
    Learn = {
        Show-BurpManual
        L "Test-NetConnection $($script:Cfg.BurpHost) -Port $($script:Cfg.ProxyPort)" 'TcpTestSucceeded : True'
        L "Invoke-WebRequest http://$($script:Cfg.BurpHost):$($script:Cfg.ProxyPort)/cert -OutFile burp-ca.der" 'tải CA (DER)'
        L 'openssl x509 -inform DER -in burp-ca.der -subject_hash_old -noout' 'ra hash, vd 9a5ba575 (nếu có openssl)'
        L 'openssl x509 -inform DER -in burp-ca.der -out 9a5ba575.0' 'đổi sang PEM, tên = <hash>.0'
        LNote 'Script tự tính hash không cần openssl, lưu ở tools\burp\<hash>.0'
    }
}

# ==================================================================== 5. CERT
$script:StageDefs['cert'] = [pscustomobject]@{
    Id = 'cert'; Title = '5. CA Burp trong system store'; Critical = $false; RetryRunsFix = $false
    Why = @('App Java/Kotlin chỉ tin CA hệ thống. Android 14+ đọc CA từ /apex/com.android.conscrypt/cacerts.',
        'Script inject tạm bằng tmpfs (cách của HTTP Toolkit). Mất sau reboot -> resume tự làm lại.')
    Check = {
        $c = Get-CertCached
        if (-not $c) { return New-Result $false 'Chưa có CA của Burp' 'Hoàn thành giai đoạn 4 (Burp) trước' }
        Show-Cmd ((Get-SuPrefix) + "`"ls <cacerts>/$($c.Hash).0`"   (Android 14+: xem trong namespace của zygote)")
        $t = Test-SystemCert $c.Hash
        if ($t.Ok) { return New-Result $true "$($c.Hash).0 có trong $($t.Path)" }
        return New-Result $false "Không thấy $($c.Hash).0 trong $($t.Path)" 'Script sẽ inject CA tạm thời'
    }
    Fix = {
        $c = Get-CertCached
        if (-not $c) { return }
        if (Install-SystemCertTemp $c) {
            Ok 'Đã inject CA (tạm thời tới lần reboot sau)'
            Hint 'App đang mở phải khởi động lại mới nhận CA (giai đoạn hook sẽ force-stop app).'
            Hint 'Muốn giữ qua reboot: module Magisk AlwaysTrustUserCerts / ConscryptTrustUserCerts + cài CA vào User store.'
        }
    }
    Learn = {
        $c = Get-CertCached
        $hash = '<hash>'
        if ($c) { $hash = $c.Hash }
        L "adb push tools\burp\$hash.0 /data/local/tmp/"
        LNote 'Chạy các lệnh sau bằng root (adb shell, rồi su nếu dùng Magisk):'
        foreach ($l in (Get-CertInjectLines $hash)) { Say "       $l" 'Yellow' }
        L ((Get-SuPrefix) + "`"ls /system/etc/security/cacerts/$hash.0`"") 'Android <= 13'
        L ((Get-SuPrefix) + "`"nsenter --mount=/proc/`$(pidof zygote64)/ns/mnt -- ls /apex/com.android.conscrypt/cacerts/$hash.0`"") 'Android 14+'
    }
}

# ==================================================================== 6. APP
$script:StageDefs['app'] = [pscustomobject]@{
    Id = 'app'; Title = '6. Chọn app + nhận diện framework'; Critical = $true; RetryRunsFix = $false
    Why = @('Lấy UID của app (iptables lọc theo UID), kéo APK về để biết app là Flutter / React Native / Java...',
        'rồi chọn script hook tương ứng. Mỗi app có 1 profile riêng trong profiles\.')
    Check = {
        $pkg = $script:PackageArg
        if (-not $pkg) { $pkg = Get-StateValue 'Package' }
        if (-not $pkg) { return New-Result $false 'Chưa chọn app' 'Script sẽ hiện danh sách app để chọn' }
        Show-Cmd "adb shell pm list packages -U $pkg   ;   adb shell dumpsys package $pkg"
        $prof = Update-AppProfile $pkg
        if (-not $prof) { return New-Result $false "App $pkg chưa được cài trên máy ảo" 'Chọn app khác hoặc cài app' }
        $script:App = $prof
        Set-StateValue 'Package' $pkg
        Show-AppWarnings $prof
        return New-Result $true "$pkg | uid $($prof.Uid) | $($prof.Framework) | ABI $($prof.PrimaryAbi) | hook: $($prof.Hook)"
    }
    Fix = {
        $sel = Select-App
        $script:PackageArg = $sel
        Set-StateValue 'Package' $sel
    }
    Learn = {
        L 'adb shell pm list packages -3 -U' 'app bên thứ 3 kèm UID'
        L 'adb install -r app.apk' 'cài 1 file APK'
        L 'adb install-multiple -r base.apk split_config.x86_64.apk' 'cài split APK (.apks/.xapk giải nén ra)'
        L 'adb shell pm path <package>' 'đường dẫn APK trên máy'
        L 'adb pull <đường_dẫn_base.apk> .'
        L 'adb shell dumpsys package <package> | findstr "userId primaryCpuAbi versionName"'
        LNote 'Mở APK bằng 7-Zip: có lib/<abi>/libflutter.so => Flutter; libreactnativejni.so/libhermes.so => React Native;'
        LNote 'libmonodroid.so => Xamarin; libil2cpp.so/libunity.so => Unity; không có => Java/Kotlin.'
    }
}

# ==================================================================== 7. FRIDA-SERVER
$script:StageDefs['frida'] = [pscustomobject]@{
    Id = 'frida'; Title = '7. frida-server trên máy ảo'; Critical = $false; RetryRunsFix = $false
    Why = @('frida-server phải cùng version với frida trên host và đúng kiến trúc CPU của máy ảo.',
        'Nó chạy bằng root và mất sau reboot -> resume tự chạy lại.')
    Check = {
        if (-not $script:FridaVersion) { $script:FridaVersion = Get-FridaClientVersion }
        Show-Cmd ('adb shell /data/local/tmp/frida-server --version   ;   ' + (Get-SuPrefix) + '"pidof frida-server"')
        $s = Get-FridaServerState
        if (-not $s.Version) { return New-Result $false 'Chưa có /data/local/tmp/frida-server' 'Script sẽ tải đúng version + kiến trúc và push lên' }
        if ($s.Version -ne $script:FridaVersion) { return New-Result $false "frida-server $($s.Version) khác client $($script:FridaVersion)" 'Script sẽ thay bằng bản khớp' }
        if (-not $s.Running) { return New-Result $false "frida-server $($s.Version) chưa chạy" 'Script sẽ chạy nó (nền, root)' }
        if (-not (Test-FridaPs)) { return New-Result $false 'frida-ps không kết nối được frida-server' }
        return New-Result $true "frida-server $($s.Version) đang chạy, khớp client"
    }
    Fix = {
        $s = Get-FridaServerState
        if ($s.Version -ne $script:FridaVersion) {
            $arch = Get-FridaArch $script:Dev.Abi
            if (-not $arch) { Bad "Không biết kiến trúc '$($script:Dev.Abi)'"; return }
            $bin = Get-FridaServerFile $script:FridaVersion $arch
            if (-not $bin) {
                Wait-User "Tải frida-server-$($script:FridaVersion)-android-$arch.xz (github.com/frida/frida/releases), giải nén vào tools\frida\ với tên frida-server-$($script:FridaVersion)-android-$arch"
                $bin = Get-FridaServerFile $script:FridaVersion $arch
                if (-not $bin) { return }
            }
            Invoke-Root 'pkill -f frida-server' | Out-Null
            Adb push $bin /data/local/tmp/frida-server | Out-Null
            Invoke-Root 'chmod 755 /data/local/tmp/frida-server' | Out-Null
        } elseif ($s.Running) {
            Invoke-Root 'pkill -f frida-server' | Out-Null
            Start-Sleep -Seconds 1
        }
        Start-FridaServer
    }
    Learn = {
        $v = $script:FridaVersion
        if (-not $v) { $v = '<version>' }
        $arch = '<arch>'
        if ($script:Dev) { $a = Get-FridaArch $script:Dev.Abi; if ($a) { $arch = $a } }
        L 'frida --version' "client, vd $v"
        L "Invoke-WebRequest https://github.com/frida/frida/releases/download/$v/frida-server-$v-android-$arch.xz -OutFile fs.xz"
        LNote 'Giải nén .xz bằng 7-Zip, được file frida-server-...'
        L "adb push frida-server-$v-android-$arch /data/local/tmp/frida-server"
        L ((Get-SuPrefix) + '"chmod 755 /data/local/tmp/frida-server"')
        L ((Get-SuPrefix) + '"/data/local/tmp/frida-server -D"' ) 'chạy nền (-D)'
        L 'frida-ps -U' 'liệt kê process = kết nối OK'
    }
}

# ==================================================================== 8. REDIRECT
$script:StageDefs['redirect'] = [pscustomobject]@{
    Id = 'redirect'; Title = '8. iptables: ép traffic app sang Burp'; Critical = $false; RetryRunsFix = $false
    Why = @('Flutter (và nhiều app) bỏ qua proxy hệ thống, nên dùng DNAT theo UID của app để ép TCP sang Burp.',
        'Chặn UDP (QUIC) và IPv6 để app phải đi IPv4 TCP. Rule mất sau reboot, và UID đổi khi cài lại app.')
    Check = {
        if (-not $script:App) { return New-Result $false 'Chưa có app' }
        $uid = "$($script:App.Uid)"
        $want = Get-PH
        Show-Cmd ((Get-SuPrefix) + '"iptables -t nat -S TMM_OUT"   ;   adb shell settings get global http_proxy')
        $st = Get-RedirectState
        if (-not $st.Jump -or $st.Uid -ne $uid -or $st.Dest -ne $want) {
            $extra = ''
            if ($st.Uid -and $st.Uid -ne $uid) { $extra = " (đang DNAT UID cũ $($st.Uid): app đã cài lại nên UID đổi)" }
            return New-Result $false "Chưa có DNAT cho UID $uid -> $want$extra" 'Script sẽ tạo rule trong chain TMM_OUT / TMM_FLT'
        }
        if ($script:Cfg.BlockQuic -and -not $st.Udp) { return New-Result $false 'Thiếu rule chặn QUIC' }
        $px = Get-SystemProxy
        if (-not (Test-ProxyHarmless $px)) { return New-Result $false "Proxy hệ thống đang là '$px' (cũ)" 'Script sẽ gỡ (settings put global http_proxy :0)' }
        if ($script:Dev) { Set-StateValue 'BootId' $script:Dev.BootId }
        return New-Result $true "DNAT UID $uid -> $want | đã chuyển $($st.Packets) gói"
    }
    Fix = {
        $px = Get-SystemProxy
        if (-not (Test-ProxyHarmless $px)) { Adb shell settings put global http_proxy :0 | Out-Null }
        [void](Set-Redirect "$($script:App.Uid)")
    }
    Learn = {
        $uid = '<UID>'
        if ($script:App) { $uid = $script:App.Uid }
        LNote "Chạy bằng root (adb shell, rồi su nếu Magisk). UID app = $uid, Burp = $(Get-PH):"
        foreach ($l in (Get-RedirectLines $uid)) { Say "       $l" 'Yellow' }
        L ((Get-SuPrefix) + '"iptables -t nat -L TMM_OUT -v -n -x"') 'cột pkts của DNAT tăng = đã ép được'
        L 'adb shell settings get global http_proxy' 'null hoặc :0 = không có proxy cũ'
        L 'adb shell settings put global http_proxy :0' 'gỡ proxy cũ'
    }
}

# ==================================================================== 9. HOOK
function Wait-Traffic($Before) {
    $sec = [int]$script:Cfg.TrafficWaitSec
    Info "Thao tác trong app (đăng nhập, kéo để tải lại...) để app gửi request. Đang theo dõi bộ đếm DNAT ($sec s)..."
    $end = (Get-Date).AddSeconds($sec)
    $b = 0
    if ($Before) { $b = [int64]$Before }
    while ((Get-Date) -lt $end) {
        $n = Get-DnatPackets
        if ($n -and $n -gt $b) { Ok "DNAT: +$($n - $b) gói đã bị ép sang Burp"; return ($n - $b) }
        Start-Sleep -Seconds 3
    }
    return 0
}

function Show-Diagnosis([string]$HookStatus, $Delta) {
    Say ''
    Say '     CHẨN ĐOÁN THEO 3 MỨC' 'White'
    if (-not $Delta) {
        Bad 'Mức 1 - chưa có gói nào bị DNAT:'
        Hint 'app chưa gửi request (thao tác thêm), hoặc UID sai (app cài lại -> chạy resume),'
        Hint 'hoặc app đang giữ kết nối cũ từ trước khi đặt rule -> chạy lại hook (script force-stop app).'
    } else { Ok "Mức 1 - DNAT OK (+$Delta gói tới Burp)" }
    Say '     Mức 2 - xem Burp > Dashboard > Event log:' 'White'
    Hint '"violates HTTP protocol"               -> chưa bật Support invisible proxying'
    Hint '"certificate_unknown" / "Remote host terminated the handshake" -> app từ chối CA: hook chưa patch được'
    Hint 'không có dòng nào                      -> traffic không tới Burp (sai cổng / listener / Mức 1)'
    Say '     Mức 3 - hook:' 'White'
    switch ($HookStatus) {
        'patched' { Ok 'Hook báo đã patch' }
        'nopattern' { Bad 'Flutter: pattern không khớp -> chạy flutter-scan (menu 7)' }
        'error' { Bad 'Frida lỗi khi spawn: xem cửa sổ frida, thử chạy lại (frida-server có thể đã chết)' }
        default { Warn "Hook: $HookStatus (xem cửa sổ frida)" }
    }
    Hint 'App báo lỗi ngay lúc mở (vd "-6 Lỗi kiểm tra phân quyền"): request đầu chạy trước khi hook xong -> KHÔNG tắt app, đăng xuất rồi đăng nhập lại.'
}

$script:StageDefs['hook'] = [pscustomobject]@{
    Id = 'hook'; Title = '9. Frida hook + xác nhận trong Burp'; Critical = $false; RetryRunsFix = $true
    Why = @('Mở app bằng frida (spawn) kèm script tắt kiểm tra TLS theo framework của app,',
        'đọc log để biết đã patch chưa, theo dõi bộ đếm DNAT, rồi hỏi bạn Burp đã hiện request chưa.')
    Check = {
        if ($script:HookResult) { return $script:HookResult }
        return New-Result $false 'Chưa chạy hook trong lần này'
    }
    Fix = {
        $script:HookResult = $null
        if (-not $script:App) { return }
        $c = Get-CertCached
        $scripts = @(Get-HookScripts $script:App $c)
        if (-not $scripts.Count) { Bad 'Không có script hook (tải từ GitHub thất bại?)'; Wait-User 'Kiểm tra mạng, hoặc chép script .js vào hooks\custom\'; return }
        Info ("Script nạp vào app: " + (($scripts | ForEach-Object { Split-Path -Leaf $_ }) -join ', '))
        $before = Get-DnatPackets
        $log = Start-Hook $script:App $scripts
        $hs = Watch-HookLog $log $script:App.Hook
        if ($hs -eq 'nopattern' -and (Confirm-Yes 'Chạy flutter-scan để tự tìm pattern cho libflutter.so này?')) {
            if (Invoke-FlutterScan) {
                Info 'Đã thêm pattern mới. ĐÓNG cửa sổ frida cũ rồi bấm Enter để chạy lại hook.'
                $script:HookResult = New-Result $false 'Đã có pattern mới, cần chạy lại hook'
                return
            }
        }
        $delta = Wait-Traffic $before
        $seen = Ask-YesNo 'Burp > Proxy > HTTP history đã thấy request của app (đọc được nội dung) chưa?' $false
        if ($seen) {
            $script:HookResult = New-Result $true "Hook: $hs | DNAT +$delta gói | Burp đã giải mã được"
            Hint 'Giữ nguyên cửa sổ frida. Đóng app hoặc đóng frida thì chạy lại hook.'
        } else {
            Show-Diagnosis $hs $delta
            $script:HookResult = New-Result $false "Chưa thấy request trong Burp (hook: $hs, DNAT +$delta)" 'Sửa theo chẩn đoán, đóng cửa sổ frida cũ, bấm Enter để chạy lại hook'
        }
    }
    Learn = {
        $pkg = '<package>'
        if ($script:App) { $pkg = $script:App.Package }
        L "adb shell am force-stop $pkg" 'đóng app để kết nối cũ không còn'
        if ($script:App -and $script:App.Hook -eq 'flutter') {
            L "frida -U -f $pkg -l tools\hooks\flutter-tls.patched.js" 'Flutter'
            LNote 'Đợi dòng: [+] ssl_verify_peer_cert has been patched'
        } else {
            L "frida -U -f $pkg -l config.generated.js -l native-tls-hook.js -l android-system-certificate-injection.js -l android-certificate-unpinning.js -l android-certificate-unpinning-fallback.js" 'Java/Kotlin (trong tools\hooks\httptoolkit)'
            LNote 'Đợi dòng: == Certificate unpinning completed =='
        }
        L ((Get-SuPrefix) + '"iptables -t nat -L TMM_OUT -v -n -x"') 'pkts tăng khi bạn thao tác trong app'
        LNote 'Cuối cùng: Burp > Proxy > HTTP history phải có request của app.'
    }
}

# ==================================================================== engine
function Read-RetryChoice {
    if ($script:NonInteractive) { return 's' }
    $a = Read-Host '  [Enter] = kiểm tra lại (sau khi bạn sửa) | a = để script tự xử lý lại | s = bỏ qua | q = thoát'
    Write-TmmLog "  (user) '$a'"
    return "$a".Trim().ToLower()
}

function Invoke-Stage($S, [string]$Mode) {
    $script:CurStage = $S.Id
    $script:ManualUsed = $false
    Title $S.Title
    foreach ($w in $S.Why) { Say "  $w" 'DarkCyan' }
    try {
        if ($Mode -eq 'learn') { return (Invoke-StageLearn $S) }
        $r = & $S.Check
        if ($r.Ok) { Ok $r.Msg; Add-Report $S.Id $S.Title 'OK' $r.Msg; return $true }
        Bad $r.Msg
        if ($r.Hint) { Hint $r.Hint }
        if ($Mode -eq 'check') { Add-Report $S.Id $S.Title 'FAIL' $r.Msg; return $false }
        $runFix = $true
        while ($true) {
            if ($runFix) { & $S.Fix }
            $r = & $S.Check
            if ($r.Ok) {
                $st = 'FIXED'
                if ($script:ManualUsed) { $st = 'MANUAL' }
                Ok $r.Msg
                Add-Report $S.Id $S.Title $st $r.Msg
                return $true
            }
            Bad $r.Msg
            if ($r.Hint) { Hint $r.Hint }
            $a = Read-RetryChoice
            if ($a -eq 'q') { throw 'TMM_QUIT' }
            if ($a -eq 's') { throw 'TMM_SKIP' }
            $runFix = ($a -eq 'a') -or [bool]$S.RetryRunsFix
            $script:ManualUsed = $true
        }
    } catch {
        $m = "$($_.Exception.Message)"
        if ($m -eq 'TMM_SKIP') { Warn 'Bỏ qua giai đoạn này'; Add-Report $S.Id $S.Title 'SKIP' 'bỏ qua'; return $false }
        if ($m -eq 'TMM_QUIT') { Add-Report $S.Id $S.Title 'SKIP' 'thoát giữa chừng'; throw 'TMM_QUIT' }
        Bad "Lỗi không mong muốn: $m"
        Write-TmmLog ($_ | Out-String)
        Add-Report $S.Id $S.Title 'FAIL' "lỗi: $m"
        return $false
    }
}

function Invoke-StageLearn($S) {
    Say ''
    Say '  Gõ các lệnh sau trong MỘT CỬA SỔ POWERSHELL KHÁC (đứng ở thư mục toolkit):' 'White'
    & $S.Learn
    while ($true) {
        if ($script:NonInteractive) { throw 'TMM_SKIP' }
        $a = Read-Host '  Gõ xong bấm [Enter] để script kiểm tra | a = để script tự làm | s = bỏ qua | q = thoát'
        $a = "$a".Trim().ToLower()
        if ($a -eq 'q') { throw 'TMM_QUIT' }
        if ($a -eq 's') { throw 'TMM_SKIP' }
        if ($a -eq 'a') { & $S.Fix }
        $r = & $S.Check
        if ($r.Ok) { Ok $r.Msg; Add-Report $S.Id $S.Title 'OK' $r.Msg; return $true }
        Bad $r.Msg
        if ($r.Hint) { Hint $r.Hint }
        Info 'Chưa đạt, xem lại lệnh ở trên (hoặc a = để script tự làm).'
    }
}

$script:Pipelines = @{
    auto   = @('host', 'device', 'root', 'burp', 'cert', 'app', 'frida', 'redirect', 'hook')
    resume = @('host', 'device', 'root', 'burp', 'cert', 'app', 'frida', 'redirect')
    check  = @('host', 'device', 'root', 'burp', 'cert', 'app', 'frida', 'redirect')
    learn  = @('host', 'device', 'root', 'burp', 'cert', 'app', 'frida', 'redirect', 'hook')
    hook   = @('host', 'device', 'root', 'burp', 'cert', 'app', 'frida', 'redirect', 'hook')
    base   = @('host', 'device', 'root')
}

function Invoke-Pipeline([string]$Name, [string]$StageMode) {
    $allOk = $true
    foreach ($id in $script:Pipelines[$Name]) {
        $s = $script:StageDefs[$id]
        $ok = Invoke-Stage $s $StageMode
        if (-not $ok) {
            $allOk = $false
            if ($s.Critical) { Bad 'Giai đoạn bắt buộc chưa đạt: dừng tại đây.'; break }
        }
    }
    return $allOk
}

# ==================================================================== flutter-scan
function Invoke-FlutterScan {
    $prof = $script:App
    if (-not $prof) { Bad 'Chưa chọn app'; return $false }
    if ($prof.Framework -ne 'Flutter') { Warn "App $($prof.Package) không phải Flutter ($($prof.Framework))"; return $false }
    $abi = $prof.PrimaryAbi
    if (-not $abi -and $script:Dev) { $abi = $script:Dev.Abi }
    $apks = Get-AppApks $prof.Package
    $lib = Join-Path (Join-Path (Join-Path $script:WorkDir 'apps') $prof.Package) "libflutter-$abi.so"
    $found = $false
    foreach ($a in $apks) { if (Export-ZipEntry $a "lib/$abi/libflutter.so" $lib) { $found = $true; break } }
    if (-not $found) { Bad "Không thấy lib/$abi/libflutter.so trong APK"; return $false }
    Info "Đã lấy $lib"
    $nv = Join-Path (Get-HooksDir) 'nviso-disable-flutter-tls.js'
    if (-not (Test-Path $nv)) { [void](Update-HookSources) }
    $vpy = Get-VenvBin 'python'
    $scan = Join-Path (Join-Path $script:TMM 'helpers') 'flutter_scan.py'
    $out = Invoke-Native -Exe $vpy -Arguments @($scan, $lib, '--js', $nv, '--extra', (Get-ExtraPatternsFile), '--write') -Display "python helpers\flutter_scan.py $(Split-Path -Leaf $lib) --js nviso-disable-flutter-tls.js --extra hooks\flutter\extra-patterns.json --write"
    foreach ($l in $out) { Say "     $l" }
    return ($script:LastExit -eq 0)
}
