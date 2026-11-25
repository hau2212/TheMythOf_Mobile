# Frida.ps1 - Python/venv frida trên host, frida-server trên máy ảo, script hook, chạy + theo dõi hook.

$script:VenvDir = Join-Path $script:ToolsDir 'venv'
$script:FridaVersion = $null

# ---------------------------------------------------------------- Python + venv
function Find-Python {
    if ($env:TMM_PYTHON) { return @($env:TMM_PYTHON) }
    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        $v = Invoke-Native -Exe $py.Source -Arguments @('-3', '--version') -Quiet
        if (($v -join ' ') -match 'Python 3') { return @($py.Source, '-3') }
    }
    foreach ($n in @('python', 'python3')) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c -and $c.Source -notmatch 'WindowsApps') {
            $v = Invoke-Native -Exe $c.Source -Arguments @('--version') -Quiet
            if (($v -join ' ') -match 'Python 3') { return @($c.Source) }
        }
    }
    return $null
}

function Get-VenvBin([string]$Name) {
    if ($script:IsWin) { return (Join-Path (Join-Path $script:VenvDir 'Scripts') "$Name.exe") }
    return (Join-Path (Join-Path $script:VenvDir 'bin') $Name)
}

function Get-FridaClientVersion {
    $f = Get-VenvBin 'frida'
    if (-not (Test-Path $f)) { return $null }
    $v = Invoke-Native -Exe $f -Arguments @('--version') -Quiet
    $last = ($v | Where-Object { $_ -match '^\d+\.\d+\.\d+' } | Select-Object -Last 1)
    if ($last) { return $last.Trim() }
    return $null
}

function Update-PathFromRegistry {
    if (-not $script:IsWin) { return }
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$m;$u"
}

function Install-Python {
    $w = Get-Command winget -ErrorAction SilentlyContinue
    if ($w -and (Confirm-Yes "Cài Python bằng winget ($($script:Cfg.PythonWingetId))?")) {
        Invoke-Native -Exe $w.Source -Arguments @('install', '-e', '--id', $script:Cfg.PythonWingetId, '--accept-source-agreements', '--accept-package-agreements') | Out-Null
        Update-PathFromRegistry
        if (Find-Python) { return }
    }
    Wait-User 'Cài Python 3 từ https://www.python.org/downloads/ (tick "Add python.exe to PATH"), rồi mở lại Start.cmd nếu vẫn không thấy'
    Update-PathFromRegistry
}

function Install-FridaVenv {
    $py = Find-Python
    if (-not $py) { return $false }
    $pyExe = $py[0]
    $pyArgs = @()
    if ($py.Count -gt 1) { $pyArgs = @($py[1..($py.Count - 1)]) }
    if (-not (Test-Path (Get-VenvBin 'python'))) {
        Info 'Tạo môi trường Python riêng cho toolkit (tools\venv) để không đụng Python hệ thống'
        Invoke-Native -Exe $pyExe -Arguments ($pyArgs + @('-m', 'venv', $script:VenvDir)) -Display "py -m venv tools\venv" | Out-Null
    }
    $vpy = Get-VenvBin 'python'
    if (-not (Test-Path $vpy)) { Bad 'Tạo venv thất bại'; return $false }
    Invoke-Native -Exe $vpy -Arguments @('-m', 'pip', 'install', '--upgrade', 'pip') -Display 'tools\venv\Scripts\python -m pip install --upgrade pip' | Out-Null
    $spec = 'frida'
    if ($script:Cfg.FridaVersion) { $spec = "frida==$($script:Cfg.FridaVersion)" }
    $out = Invoke-Native -Exe $vpy -Arguments @('-m', 'pip', 'install', '--upgrade', $spec, 'frida-tools') -Display "tools\venv\Scripts\python -m pip install --upgrade $spec frida-tools"
    $out | Select-Object -Last 3 | ForEach-Object { Say "       $_" 'DarkGray' }
    return [bool](Get-FridaClientVersion)
}

# ---------------------------------------------------------------- frida-server
function Get-FridaArch([string]$Abi) {
    switch ($Abi) {
        'arm64-v8a' { return 'arm64' }
        'armeabi-v7a' { return 'arm' }
        'x86_64' { return 'x86_64' }
        'x86' { return 'x86' }
    }
    return $null
}

# Tải frida-server đúng version + kiến trúc, giải nén .xz bằng Python (lzma).
function Get-FridaServerFile([string]$Version, [string]$Arch) {
    $dir = Join-Path $script:ToolsDir 'frida'
    $bin = Join-Path $dir "frida-server-$Version-android-$Arch"
    if (Test-Path $bin) { return $bin }
    $xz = "$bin.xz"
    $url = "$($script:Cfg.Urls.FridaRelease)/$Version/frida-server-$Version-android-$Arch.xz"
    if (-not (Get-Download $url $xz)) { return $null }
    $vpy = Get-VenvBin 'python'
    Invoke-Native -Exe $vpy -Arguments @('-c', 'import lzma,shutil,sys; shutil.copyfileobj(lzma.open(sys.argv[1]), open(sys.argv[2],''wb''))', $xz, $bin) -Display "python -c (giải nén .xz bằng lzma) $(Split-Path -Leaf $xz)" | Out-Null
    if (Test-Path $bin) { Remove-Item -Force $xz; return $bin }
    return $null
}

function Get-FridaServerState {
    $ver = ((AdbQ shell /data/local/tmp/frida-server --version) -join ' ').Trim()
    if ($ver -notmatch '^\d+\.\d+\.\d+') { $ver = '' }
    $fpid = ((Invoke-Root 'pidof frida-server' -Quiet) -join ' ').Trim()
    return [pscustomobject]@{ Version = $ver; Running = ($fpid -match '^\d+') }
}

function Start-FridaServer {
    if ($script:RootMode -eq 'magisk') {
        $a = @(Get-AdbBase) + @('shell', 'su -c "/data/local/tmp/frida-server -D"')
        Show-Cmd 'adb shell su -c "/data/local/tmp/frida-server -D"   (chạy nền)'
    } else {
        $a = @(Get-AdbBase) + @('shell', '/data/local/tmp/frida-server -D')
        Show-Cmd 'adb shell /data/local/tmp/frida-server -D   (chạy nền)'
    }
    if ($script:IsWin) { Start-Process -FilePath $script:AdbExe -ArgumentList $a -WindowStyle Hidden | Out-Null }
    else { Start-Process -FilePath $script:AdbExe -ArgumentList $a | Out-Null }
    Start-Sleep -Seconds 3
}

function Test-FridaPs {
    $fp = Get-VenvBin 'frida-ps'
    $out = Invoke-Native -Exe $fp -Arguments @('-D', $script:Serial) -Display "frida-ps -D $($script:Serial)"
    return (($out -join "`n") -match 'PID\s+Name')
}

# ---------------------------------------------------------------- script hook
function Get-HooksDir { $d = Join-Path $script:ToolsDir 'hooks'; if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }; return $d }

$script:HttpToolkitFiles = @('config.js', 'native-tls-hook.js', 'android/android-system-certificate-injection.js',
    'android/android-certificate-unpinning.js', 'android/android-certificate-unpinning-fallback.js')

function Update-HookSources([switch]$Force) {
    $d = Get-HooksDir
    $ok = $true
    $nv = Join-Path $d 'nviso-disable-flutter-tls.js'
    if ($Force -or -not (Test-Path $nv)) { $ok = (Get-Download $script:Cfg.Urls.NvisoFlutter $nv) -and $ok }
    $ht = Join-Path $d 'httptoolkit'
    foreach ($f in $script:HttpToolkitFiles) {
        $local = Join-Path $ht ($f.Replace('/', [IO.Path]::DirectorySeparatorChar))
        if ($Force -or -not (Test-Path $local)) { $ok = (Get-Download ($script:Cfg.Urls.HttpToolkitBase + $f) $local) -and $ok }
    }
    return $ok
}

# Chèn pattern trong hooks\flutter\extra-patterns.json vào cuối mảng tương ứng của script NVISO.
function Merge-FlutterPatterns([string]$Js, $Extra) {
    $added = 0
    $start = $Js.IndexOf('"android"')
    if ($start -lt 0 -or -not $Extra -or -not $Extra.android) { return @($Js, 0) }
    foreach ($archProp in $Extra.android.PSObject.Properties) {
        $rx = New-Object Text.RegularExpressions.Regex ('"' + [regex]::Escape($archProp.Name) + '"\s*:\s*\[')
        $m = $rx.Match($Js, $start)
        if (-not $m.Success) { Warn "Không thấy mảng '$($archProp.Name)' trong script NVISO"; continue }
        $i = $m.Index + $m.Length; $depth = 1
        while ($i -lt $Js.Length -and $depth -gt 0) {
            if ($Js[$i] -eq '[') { $depth++ } elseif ($Js[$i] -eq ']') { $depth-- }
            $i++
        }
        $close = $i - 1
        $ins = ''
        foreach ($p in $archProp.Value) {
            if ($Js.Contains('"' + $p.pattern + '"')) { continue }
            $note = "$($p.note)" -replace '[\r\n]', ' '
            $ins += "`n                { pattern: `"$($p.pattern)`", retval: $([int]$p.retval) }, // TheMythOf_Mobile: $note"
            $added++
        }
        if (-not $ins) { continue }
        $before = $Js.Substring(0, $close).TrimEnd()
        if (-not ($before.EndsWith(',') -or $before.EndsWith('['))) { $ins = ',' + $ins }
        $Js = $before + $ins + "`n            " + $Js.Substring($close)
    }
    return @($Js, $added)
}

function Get-ExtraPatternsFile { return (Join-Path (Join-Path (Join-Path $script:TMM 'hooks') 'flutter') 'extra-patterns.json') }

function Get-FlutterHook {
    $d = Get-HooksDir
    $nv = Join-Path $d 'nviso-disable-flutter-tls.js'
    if (-not (Test-Path $nv)) { [void](Update-HookSources) }
    if (-not (Test-Path $nv)) { return $null }
    $extraFile = Get-ExtraPatternsFile
    $extra = $null
    if (Test-Path $extraFile) { $extra = Get-Content -Raw $extraFile | ConvertFrom-Json }
    $r = Merge-FlutterPatterns (Get-Content -Raw $nv) $extra
    $js = "console.log('[+] TheMythOf_Mobile: them $($r[1]) pattern tu hooks/flutter/extra-patterns.json');`n" + $r[0]
    $out = Join-Path $d 'flutter-tls.patched.js'
    Write-TextLF $out $js
    return $out
}

function Get-AndroidHooks($Cert) {
    $d = Join-Path (Get-HooksDir) 'httptoolkit'
    if (-not (Test-Path (Join-Path $d 'config.js'))) { [void](Update-HookSources) }
    $cfgSrc = Join-Path $d 'config.js'
    if (-not (Test-Path $cfgSrc)) { return @() }
    $txt = Get-Content -Raw $cfgSrc
    $a = $txt.IndexOf('const CERT_PEM = `')
    if ($a -ge 0) {
        $b = $txt.IndexOf('`;', $a + 18)
        $txt = $txt.Substring(0, $a) + 'const CERT_PEM = `' + $Cert.PemText.Trim() + '`;' + $txt.Substring($b + 2)
    } else { Warn 'config.js của HTTP Toolkit đã đổi định dạng: không chèn được CERT_PEM' }
    $txt = [regex]::Replace($txt, "const PROXY_HOST = '[^']*';", "const PROXY_HOST = '$($script:Cfg.ProxyHostFromDevice)';")
    $txt = [regex]::Replace($txt, 'const PROXY_PORT = \d+;', "const PROXY_PORT = $($script:Cfg.ProxyPort);")
    $gen = Join-Path $d 'config.generated.js'
    Write-TextLF $gen $txt
    $list = @($gen)
    foreach ($f in $script:HttpToolkitFiles) {
        if ($f -eq 'config.js') { continue }
        $p = Join-Path $d ($f.Replace('/', [IO.Path]::DirectorySeparatorChar))
        if (Test-Path $p) { $list += $p }
    }
    return $list
}

# Danh sách script sẽ nạp vào app: theo framework + hooks\custom\*.js + hooks\custom\<package>\*.js
function Get-HookScripts($Prof, $Cert) {
    $list = @()
    if ($Prof.Hook -eq 'flutter') {
        $f = Get-FlutterHook
        if ($f) { $list += $f }
        if ($script:Cfg.FlutterAlsoJavaHooks) { $list += Get-AndroidHooks $Cert }
    } else {
        $list += Get-AndroidHooks $Cert
    }
    $custom = Join-Path (Join-Path $script:TMM 'hooks') 'custom'
    $list += @(Get-ChildItem -Path $custom -Filter '*.js' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    $list += @(Get-ChildItem -Path (Join-Path $custom $Prof.Package) -Filter '*.js' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    return $list
}

# Mở cửa sổ riêng chạy frida (spawn app + nạp script), output ghi ra logs\frida-*.log.
# Lệnh cũng được lưu thành logs\hook-<package>.ps1 để bạn tự chạy lại.
function Start-Hook($Prof, [string[]]$Scripts) {
    $frida = Get-VenvBin 'frida'
    $log = Join-Path $script:LogDir ("frida-{0}-{1}.log" -f $Prof.Package, (Get-Date -Format 'HHmmss'))
    $parts = @("& '$frida'", '-D', $script:Serial, '-f', $Prof.Package)
    foreach ($s in $Scripts) { $parts += @('-l', "'$s'") }
    $parts += @('-o', "'$log'")
    $cmd = $parts -join ' '
    $runner = Join-Path $script:LogDir "hook-$($Prof.Package).ps1"
    $body = "# Chạy lại hook bằng tay: powershell -ExecutionPolicy Bypass -File `"$runner`"`r`n" +
        "`$Host.UI.RawUI.WindowTitle = 'Frida - $($Prof.Package)'`r`n" + $cmd + "`r`n"
    [IO.File]::WriteAllText($runner, $body, (New-Object System.Text.UTF8Encoding $true))
    Show-Cmd ("frida -D {0} -f {1} {2} -o logs\{3}" -f $script:Serial, $Prof.Package, (($Scripts | ForEach-Object { '-l ' + (Split-Path -Leaf $_) }) -join ' '), (Split-Path -Leaf $log))
    Info "Lệnh đầy đủ lưu ở: $runner"
    Adb shell am force-stop $Prof.Package | Out-Null
    if ($script:IsWin) {
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$runner`"") | Out-Null
    } else {
        Warn "Không phải Windows: tự chạy $runner"
    }
    return $log
}

function Read-LogText([string]$Path) {
    if (-not (Test-Path $Path)) { return '' }
    try {
        $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $sr = New-Object IO.StreamReader($fs)
        try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
    } catch { return '' }
}

# Đọc log frida để biết hook có thành công không.
function Watch-HookLog([string]$Log, [string]$Kind) {
    $end = (Get-Date).AddSeconds([int]$script:Cfg.HookWaitSec)
    Info "Đang đọc log frida ($([int]$script:Cfg.HookWaitSec)s): $Log"
    $warned = $false
    while ((Get-Date) -lt $end) {
        $t = Read-LogText $Log
        if ($t -match 'Failed to spawn|unable to (find|connect)|need Gadget|server terminated|Process crashed|Process terminated') {
            Bad 'Frida báo lỗi khi spawn/attach (xem cửa sổ frida)'
            return 'error'
        }
        if ($Kind -eq 'flutter') {
            if ($t -match 'ssl_verify_peer_cert has been patched') { Ok 'Flutter: ssl_verify_peer_cert has been patched'; return 'patched' }
            if ($t -match 'could not be located') { Bad 'Flutter: libflutter.so có, nhưng không pattern nào khớp ssl_verify_peer_cert'; return 'nopattern' }
            if (-not $warned -and $t -match 'Flutter library not found') { Warn 'Chưa thấy libflutter.so (app chưa nạp Flutter, hoặc không phải Flutter)'; $warned = $true }
        } else {
            if ($t -match 'Certificate unpinning completed') { Ok 'Android: unpinning đã nạp xong'; return 'patched' }
        }
        Start-Sleep -Seconds 2
    }
    Warn 'Hết thời gian chờ mà log chưa có kết quả. Xem trực tiếp cửa sổ frida.'
    return 'timeout'
}
