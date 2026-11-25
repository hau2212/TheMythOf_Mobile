# App.ps1 - liệt kê / cài / chọn app, nhận diện framework, profile theo từng app.

$script:App = $null

function Get-ThirdPartyApps {
    $list = @()
    foreach ($l in (AdbQ shell pm list packages -3 -U)) {
        if ($l -match '^package:(\S+)\s+uid:(\d+)') { $list += [pscustomobject]@{ Package = $Matches[1]; Uid = $Matches[2] } }
    }
    return @($list | Sort-Object Package)
}

function Get-AppUid([string]$Pkg) {
    foreach ($l in (AdbQ shell pm list packages -U $Pkg)) {
        if ($l -match '^package:(\S+)\s+uid:(\d+)' -and $Matches[1] -eq $Pkg) { return $Matches[2] }
    }
    return $null
}

function Get-AppDumpInfo([string]$Pkg) {
    $txt = (AdbQ shell dumpsys package $Pkg) -join "`n"
    $info = [pscustomobject]@{ VersionName = ''; VersionCode = ''; PrimaryAbi = '' }
    if ($txt -match 'versionName=(\S+)') { $info.VersionName = $Matches[1] }
    if ($txt -match 'versionCode=(\d+)') { $info.VersionCode = $Matches[1] }
    if ($txt -match 'primaryCpuAbi=(\S+)') { $info.PrimaryAbi = $Matches[1] }
    return $info
}

function Get-ProfilePath([string]$Pkg) { return (Join-Path $script:ProfileDir "$Pkg.json") }

function Get-AppProfile([string]$Pkg) {
    $f = Get-ProfilePath $Pkg
    if (Test-Path $f) { try { return (Get-Content -Raw $f | ConvertFrom-Json) } catch { } }
    return $null
}

function Save-AppProfile($Prof) {
    $f = Get-ProfilePath $Prof.Package
    [IO.File]::WriteAllText($f, ($Prof | ConvertTo-Json -Depth 5), $script:Utf8NoBom)
}

# Kéo các file APK (base + split) của app về work\apps\<pkg>\ để phân tích.
function Get-AppApks([string]$Pkg) {
    $dir = Join-Path (Join-Path $script:WorkDir 'apps') $Pkg
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $files = @()
    foreach ($l in (Adb shell pm path $Pkg)) {
        if ($l -match '^package:(.+\.apk)\s*$') {
            $remote = $Matches[1]
            $local = Join-Path $dir ([IO.Path]::GetFileName($remote))
            $size = ((AdbQ shell stat -c %s $remote) -join '').Trim()
            if (-not ((Test-Path $local) -and ("$((Get-Item $local).Length)" -eq $size))) {
                Adb pull $remote $local | Out-Null
            }
            if (Test-Path $local) { $files += $local }
        }
    }
    return $files
}

# Nhận diện framework dựa vào file bên trong APK.
function Get-AppFramework([string[]]$Apks) {
    $entries = @()
    foreach ($a in $Apks) { try { $entries += Get-ZipEntries $a } catch { } }
    $abis = @($entries | Where-Object { $_ -match '^lib/([^/]+)/[^/]+\.so$' } | ForEach-Object { ($_ -split '/')[1] } | Sort-Object -Unique)
    $has = { param($rx) [bool](@($entries | Where-Object { $_ -match $rx }).Count) }
    $fw = 'Native (Java/Kotlin)'
    if (& $has '^lib/[^/]+/libflutter\.so$') { $fw = 'Flutter' }
    elseif ((& $has '^lib/[^/]+/libreactnativejni\.so$') -or (& $has '^lib/[^/]+/libhermes\.so$') -or (& $has '^assets/index\.android\.bundle$')) { $fw = 'React Native' }
    elseif ((& $has '^lib/[^/]+/libmonodroid\.so$') -or (& $has '^lib/[^/]+/libmonosgen') -or (& $has '^assemblies/')) { $fw = 'Xamarin/.NET MAUI' }
    elseif ((& $has '^lib/[^/]+/libunity\.so$') -or (& $has '^lib/[^/]+/libil2cpp\.so$')) { $fw = 'Unity' }
    elseif ((& $has '^assets/(www|public)/cordova\.js$') -or (& $has '^assets/capacitor\.config\.json$')) { $fw = 'Cordova/Capacitor (WebView)' }
    return [pscustomobject]@{ Framework = $fw; Abis = $abis }
}

function Get-HookKind([string]$Framework) {
    if ($Framework -eq 'Flutter') { return 'flutter' }
    return 'android'
}

# Tạo hoặc cập nhật profile cho app (phân tích lại khi app đổi versionCode).
function Update-AppProfile([string]$Pkg, [switch]$Force) {
    $uid = Get-AppUid $Pkg
    if (-not $uid) { return $null }
    $dump = Get-AppDumpInfo $Pkg
    $prof = Get-AppProfile $Pkg
    if ($Force -or -not $prof -or "$($prof.VersionCode)" -ne "$($dump.VersionCode)") {
        Info "Phân tích $Pkg (kéo APK về work\apps\$Pkg\ ...)"
        $apks = Get-AppApks $Pkg
        $fw = Get-AppFramework $apks
        $prof = [pscustomobject]@{
            Package = $Pkg; VersionName = $dump.VersionName; VersionCode = $dump.VersionCode
            Framework = $fw.Framework; Abis = $fw.Abis; PrimaryAbi = $dump.PrimaryAbi
            Hook = (Get-HookKind $fw.Framework); Uid = $uid; Analyzed = (Get-Date -Format 's')
        }
    }
    $prof | Add-Member -NotePropertyName Uid -NotePropertyValue $uid -Force
    $prof | Add-Member -NotePropertyName PrimaryAbi -NotePropertyValue $dump.PrimaryAbi -Force
    Save-AppProfile $prof
    return $prof
}

function Show-AppWarnings($Prof) {
    $devAbi = ''
    if ($script:Dev) { $devAbi = $script:Dev.Abi }
    if ($Prof.Framework -eq 'Flutter' -and $Prof.PrimaryAbi -and $devAbi -and $Prof.PrimaryAbi -ne $devAbi) {
        Warn "App chạy bằng thư viện $($Prof.PrimaryAbi) trên máy $devAbi (qua lớp dịch ARM)."
        Hint 'Frida không patch được libflutter.so khi app chạy qua lớp dịch ARM. Cần app có lib x86_64, hoặc dùng máy thật/emulator ARM64.'
    }
    switch -Wildcard ($Prof.Framework) {
        'Xamarin*' { Warn 'Xamarin/.NET dùng TLS riêng (Mono/BoringSSL). Script unpinning Java có thể chưa đủ.' }
        'Unity' { Warn 'Unity (il2cpp) thường dùng UnityWebRequest/BoringSSL riêng. Script unpinning Java có thể chưa đủ.' }
        'React Native' { Info 'React Native dùng OkHttp phía Java: script unpinning Android thường bắt được.' }
    }
}

# ---------------------------------------------------------------- cài app
function Install-ApkFile([string]$File) {
    $ext = [IO.Path]::GetExtension($File).ToLower()
    if ($ext -eq '.apk') {
        $out = Adb install -r -g $File
        return (($out -join ' ') -match 'Success')
    }
    if ($ext -in @('.apks', '.xapk', '.zip')) {
        $tmp = Join-Path $script:WorkDir ('split-' + [IO.Path]::GetFileNameWithoutExtension($File))
        Expand-ZipTo $File $tmp
        $apks = @(Get-ChildItem -Path $tmp -Filter '*.apk' -Recurse | ForEach-Object { $_.FullName })
        if (-not $apks.Count) { Bad 'Không thấy file .apk nào bên trong'; return $false }
        if (Get-ChildItem -Path $tmp -Filter '*.obb' -Recurse -ErrorAction SilentlyContinue) { Warn 'Gói có file OBB: script không tự chép OBB.' }
        $out = Invoke-Native -Exe $script:AdbExe -Arguments (@(Get-AdbBase) + @('install-multiple', '-r', '-g') + $apks) -Display ('adb install-multiple -r -g ' + (($apks | ForEach-Object { Split-Path -Leaf $_ }) -join ' '))
        return (($out -join ' ') -match 'Success')
    }
    Bad "Không hỗ trợ định dạng $ext (.apkm bị mã hoá: dùng APKMirror Installer trên máy ảo)"
    return $false
}

function Find-NewPackage($Before) {
    $after = Get-ThirdPartyApps
    $new = @($after | Where-Object { $Before.Package -notcontains $_.Package })
    if ($new.Count -ge 1) { return $new[0].Package }
    return $null
}

# Menu chọn app: app đã cài / cài từ apps\ / mở Play Store.
function Select-App {
    $appsDir = Join-Path $script:TMM 'apps'
    while ($true) {
        $list = @(Get-ThirdPartyApps)
        Say ''
        Say '     Chọn app để bắt traffic:' 'White'
        for ($i = 0; $i -lt $list.Count; $i++) {
            $p = Get-AppProfile $list[$i].Package
            $tag = ''
            if ($p) { $tag = "  [$($p.Framework)]" }
            Say ("     {0,3}. {1}  (uid {2}){3}" -f ($i + 1), $list[$i].Package, $list[$i].Uid, $tag)
        }
        $n = $list.Count
        Say ("     {0,3}. Cài APK từ thư mục apps\" -f ($n + 1)) 'Cyan'
        Say ("     {0,3}. Mở Google Play trên máy ảo để cài app" -f ($n + 2)) 'Cyan'
        Say ("     {0,3}. Lọc theo tên" -f ($n + 3)) 'Cyan'
        $c = Read-Choice 'Nhập số' ($n + 3)
        if ($c -le $n) { return $list[$c - 1].Package }
        if ($c -eq $n + 1) {
            $files = @(Get-ChildItem -Path $appsDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.apk', '.apks', '.xapk', '.zip') })
            if (-not $files.Count) { Warn "Thư mục $appsDir chưa có file .apk/.apks/.xapk. Chép file vào rồi chọn lại."; continue }
            for ($i = 0; $i -lt $files.Count; $i++) { Say ("     {0}. {1}" -f ($i + 1), $files[$i].Name) }
            $k = Read-Choice 'Chọn file' $files.Count
            $before = $list
            if (Install-ApkFile $files[$k - 1].FullName) {
                Ok 'Cài xong'
                $np = Find-NewPackage $before
                if ($np) { return $np }
            } else { Bad 'Cài thất bại (xem log)'; }
            continue
        }
        if ($c -eq $n + 2) {
            $q = Read-Host '  Nhập package id (vd com.example.app) hoặc từ khoá tìm kiếm'
            if (-not $q) { continue }
            $uri = "market://search?q=$q"
            if ($q -match '^[a-zA-Z][\w]*(\.[\w]+)+$') { $uri = "market://details?id=$q" }
            $before = $list
            Adb shell am start -a android.intent.action.VIEW -d $uri | Out-Null
            Wait-User 'Trên máy ảo: đăng nhập Google (nếu cần) và bấm Install, đợi cài xong'
            $np = Find-NewPackage $before
            if ($np) { Ok "Đã cài: $np"; return $np }
            if ($q -match '\.' -and (Get-AppUid $q)) { return $q }
            Warn 'Chưa thấy app mới. Chọn lại trong danh sách.'
            continue
        }
        $f = Read-Host '  Từ khoá'
        $m = @($list | Where-Object { $_.Package -like "*$f*" })
        if ($m.Count -eq 1) { return $m[0].Package }
        Warn "$($m.Count) app khớp '$f'"
    }
}
