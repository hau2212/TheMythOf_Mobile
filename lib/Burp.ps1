# Burp.ps1 - kiểm tra Burp listener / invisible proxying, lấy CA, đưa CA vào system store.

$script:Cert = $null

function Test-TcpPort([string]$HostName, [int]$Port, [int]$TimeoutMs = 1500) {
    $c = New-Object Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect($HostName, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $c.EndConnect($ar)
        return $c.Connected
    } catch { return $false } finally { $c.Close() }
}

# Gửi thẳng TLS ClientHello (không CONNECT) vào cổng Burp - giống hệt traffic bị DNAT từ máy ảo.
# Burp chỉ bắt tay TLS được khi "Support invisible proxying" đang bật.
function Test-BurpInvisible {
    $h = $script:Cfg.BurpHost
    $p = [int]$script:Cfg.ProxyPort
    $c = New-Object Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect($h, $p, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(2000)) { return [pscustomobject]@{ Ok = $false; Issuer = ''; Error = 'không kết nối được' } }
        $c.EndConnect($ar)
        $ns = $c.GetStream()
        $ns.ReadTimeout = 6000
        $ns.WriteTimeout = 6000
        $cb = [System.Net.Security.RemoteCertificateValidationCallback] { $true }
        $ssl = New-Object System.Net.Security.SslStream($ns, $false, $cb)
        $ssl.AuthenticateAsClient('example.com', $null, [System.Security.Authentication.SslProtocols]::Tls12, $false)
        $issuer = "$($ssl.RemoteCertificate.Issuer)"
        $ssl.Dispose()
        return [pscustomobject]@{ Ok = $true; Issuer = $issuer; Error = '' }
    } catch {
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        return [pscustomobject]@{ Ok = $false; Issuer = ''; Error = $e.Message }
    } finally { $c.Close() }
}

# subject_hash_old của OpenSSL = 4 byte đầu MD5(DER của Subject), đọc little-endian.
function Get-SubjectHashOld($Cert) {
    $md5 = [Security.Cryptography.MD5]::Create()
    $d = $md5.ComputeHash($Cert.SubjectName.RawData)
    $v = [uint32]$d[0] -bor ([uint32]$d[1] -shl 8) -bor ([uint32]$d[2] -shl 16) -bor ([uint32]$d[3] -shl 24)
    return $v.ToString('x8')
}

function ConvertTo-Pem([byte[]]$Der) {
    $b64 = [Convert]::ToBase64String($Der)
    $lines = for ($i = 0; $i -lt $b64.Length; $i += 64) { $b64.Substring($i, [Math]::Min(64, $b64.Length - $i)) }
    return "-----BEGIN CERTIFICATE-----`n" + ($lines -join "`n") + "`n-----END CERTIFICATE-----`n"
}

# Tải CA của Burp (http://127.0.0.1:8080/cert), tính hash, lưu DER + PEM (<hash>.0) vào tools\burp\.
function Get-BurpCa([switch]$Quiet) {
    $h = $script:Cfg.BurpHost
    $p = [int]$script:Cfg.ProxyPort
    $dir = Join-Path $script:ToolsDir 'burp'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $bytes = $null
    if (-not $Quiet) { Show-Cmd "Invoke-WebRequest http://${h}:$p/cert -OutFile tools\burp\burp-ca.der" }
    try {
        $wc = New-Object Net.WebClient
        $wc.Proxy = $null
        $bytes = $wc.DownloadData("http://${h}:$p/cert")
    } catch {
        try {
            $wc = New-Object Net.WebClient
            $wc.Proxy = New-Object Net.WebProxy("http://${h}:$p")
            $bytes = $wc.DownloadData('http://burpsuite/cert')
        } catch { $bytes = $null }
    }
    if (-not $bytes -or $bytes.Length -lt 100) { return $null }
    try {
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (, $bytes)
    } catch { return $null }
    $hash = Get-SubjectHashOld $cert
    $der = Join-Path $dir 'burp-ca.der'
    $pemText = ConvertTo-Pem $bytes
    $pem = Join-Path $dir "$hash.0"
    [IO.File]::WriteAllBytes($der, $bytes)
    Write-TextLF $pem $pemText
    $script:Cert = [pscustomobject]@{
        Hash = $hash; Der = $der; Pem = $pem; PemText = $pemText
        Subject = $cert.Subject; Issuer = $cert.Issuer; NotAfter = $cert.NotAfter
    }
    Set-StateValue 'CertHash' $hash
    return $script:Cert
}

# Dùng lại CA đã lưu nếu Burp đang tắt (để resume/kiểm tra vẫn chạy được).
function Get-CertCached {
    if ($script:Cert) { return $script:Cert }
    $c = Get-BurpCa -Quiet
    if ($c) { return $c }
    $hash = Get-StateValue 'CertHash'
    if ($hash) {
        $pem = Join-Path (Join-Path $script:ToolsDir 'burp') "$hash.0"
        if (Test-Path $pem) {
            $script:Cert = [pscustomobject]@{ Hash = $hash; Pem = $pem; PemText = (Get-Content -Raw $pem); Der = $null; Subject = ''; Issuer = ''; NotAfter = $null }
            return $script:Cert
        }
    }
    return $null
}

function Show-BurpManual {
    $p = $script:Cfg.ProxyPort
    Say '     Trong Burp Suite:' 'White'
    Say "       1. Proxy > Proxy settings > Proxy listeners: có listener cổng $p (127.0.0.1 hoặc All interfaces), tick Running"
    Say '       2. Chọn listener > Edit > tab Request handling > tick "Support invisible proxying" > OK'
    Say '       3. Proxy > Intercept: để Intercept is off (nếu không app sẽ bị treo chờ bạn Forward)'
    Say '     Vì sao cần invisible proxying: traffic bị DNAT từ máy ảo đến thẳng Burp dưới dạng TLS, không có'
    Say '     lệnh CONNECT như khi app tự dùng proxy. Burp phải đọc SNI để biết host đích.'
}

# ---------------------------------------------------------------- CA trong system store của Android
# Kiểm tra CA có trong store mà app thật sự đọc:
#   Android <= 13: /system/etc/security/cacerts
#   Android >= 14: /apex/com.android.conscrypt/cacerts, nhìn từ mount namespace của zygote
function Test-SystemCert([string]$Hash) {
    $lines = @(
        "H=$Hash",
        'if [ -d /apex/com.android.conscrypt/cacerts ]; then P=/apex/com.android.conscrypt/cacerts; else P=/system/etc/security/cacerts; fi',
        'Z=$(pidof zygote64 2>/dev/null); [ -z "$Z" ] && Z=$(pidof zygote 2>/dev/null); Z=${Z%% *}',
        'if [ -n "$Z" ] && [ "$P" = /apex/com.android.conscrypt/cacerts ] && command -v nsenter >/dev/null 2>&1; then',
        '  nsenter --mount=/proc/$Z/ns/mnt -- ls $P/$H.0 >/dev/null 2>&1 && echo TMM_CERT_OK || echo TMM_CERT_MISSING',
        'else',
        '  ls $P/$H.0 >/dev/null 2>&1 && echo TMM_CERT_OK || echo TMM_CERT_MISSING',
        'fi',
        'echo TMM_PATH=$P'
    )
    $out = (Invoke-RootScript 'certcheck' $lines -Quiet) -join "`n"
    $path = ''
    if ($out -match 'TMM_PATH=(\S+)') { $path = $Matches[1] }
    return [pscustomobject]@{ Ok = ($out -match 'TMM_CERT_OK'); Path = $path; Raw = $out }
}

# Inject tạm (mất sau reboot) theo cách của HTTP Toolkit: tmpfs đè lên cacerts, Android 14+ thì
# bind-mount vào /apex/com.android.conscrypt/cacerts trong namespace của zygote và các app.
function Get-CertInjectLines([string]$Hash) {
    return @(
        "H=$Hash",
        'T=/data/local/tmp/tmm-ca-copy',
        'rm -rf $T; mkdir -p -m 700 $T',
        'if [ -d /apex/com.android.conscrypt/cacerts ]; then cp /apex/com.android.conscrypt/cacerts/* $T/; else cp /system/etc/security/cacerts/* $T/; fi',
        'mount -t tmpfs tmpfs /system/etc/security/cacerts',
        'mv $T/* /system/etc/security/cacerts/',
        'cp /data/local/tmp/$H.0 /system/etc/security/cacerts/',
        'chown root:root /system/etc/security/cacerts/*',
        'chmod 644 /system/etc/security/cacerts/*',
        'chcon u:object_r:system_file:s0 /system/etc/security/cacerts/*',
        'if [ -d /apex/com.android.conscrypt/cacerts ]; then',
        '  ZP="$(pidof zygote) $(pidof zygote64)"',
        '  for Z in $ZP; do nsenter --mount=/proc/$Z/ns/mnt -- /bin/mount --bind /system/etc/security/cacerts /apex/com.android.conscrypt/cacerts; done',
        '  for Z in $ZP; do for P in $(ps -o PID -P $Z | grep -v PID); do nsenter --mount=/proc/$P/ns/mnt -- /bin/mount --bind /system/etc/security/cacerts /apex/com.android.conscrypt/cacerts & done; done',
        '  wait',
        'fi',
        'rm -rf $T',
        'echo TMM_CERT_INJECTED'
    )
}

function Install-SystemCertTemp($Cert) {
    $remote = "/data/local/tmp/$($Cert.Hash).0"
    Adb push $Cert.Pem $remote | Out-Null
    $lines = Get-CertInjectLines $Cert.Hash
    $out = (Invoke-RootScript 'certinject' $lines) -join "`n"
    return ($out -match 'TMM_CERT_INJECTED')
}
