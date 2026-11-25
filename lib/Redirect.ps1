# Redirect.ps1 - ép traffic của 1 app (theo UID) sang Burp bằng iptables DNAT.
# Dùng chain riêng (TMM_OUT / TMM_FLT / TMM_FLT6) nên không đụng rule khác của Android,
# và "clean" chỉ cần xoá các chain này.

function Get-RedirectLines([string]$Uid) {
    $ph = $script:Cfg.ProxyHostFromDevice
    $pp = $script:Cfg.ProxyPort
    $l = @(
        '# NAT: TCP của app -> Burp (trừ loopback để frida/app nội bộ không bị ảnh hưởng)',
        'iptables -w -t nat -N TMM_OUT 2>/dev/null',
        'iptables -w -t nat -F TMM_OUT',
        'iptables -w -t nat -C OUTPUT -j TMM_OUT 2>/dev/null || iptables -w -t nat -A OUTPUT -j TMM_OUT',
        "iptables -w -t nat -A TMM_OUT -m owner --uid-owner $Uid -p tcp -d 127.0.0.0/8 -j RETURN",
        "iptables -w -t nat -A TMM_OUT -m owner --uid-owner $Uid -p tcp -j DNAT --to-destination ${ph}:$pp",
        '# FILTER: chặn UDP (QUIC/HTTP3) và IPv6 để app phải quay về IPv4 TCP',
        'iptables -w -N TMM_FLT 2>/dev/null',
        'iptables -w -F TMM_FLT',
        'iptables -w -C OUTPUT -j TMM_FLT 2>/dev/null || iptables -w -I OUTPUT 1 -j TMM_FLT',
        'ip6tables -w -N TMM_FLT6 2>/dev/null',
        'ip6tables -w -F TMM_FLT6',
        'ip6tables -w -C OUTPUT -j TMM_FLT6 2>/dev/null || ip6tables -w -I OUTPUT 1 -j TMM_FLT6'
    )
    if ($script:Cfg.BlockQuic) {
        $l += "iptables -w -A TMM_FLT -m owner --uid-owner $Uid -p udp ! --dport 53 -j REJECT"
    }
    if ($script:Cfg.BlockIPv6) {
        $l += "ip6tables -w -A TMM_FLT6 -m owner --uid-owner $Uid -p tcp -j REJECT"
        $l += "ip6tables -w -A TMM_FLT6 -m owner --uid-owner $Uid -p udp ! --dport 53 -j REJECT"
    }
    $l += 'echo TMM_REDIRECT_DONE'
    return $l
}

function Set-Redirect([string]$Uid) {
    $out = (Invoke-RootScript 'redirect' (Get-RedirectLines $Uid)) -join "`n"
    return ($out -match 'TMM_REDIRECT_DONE')
}

# Đọc rule hiện tại: UID nào đang được DNAT, tới đâu, đã chuyển bao nhiêu gói.
function Get-RedirectState {
    $nat = (Invoke-Root 'iptables -w -t nat -S TMM_OUT' -Quiet) -join "`n"
    $jump = (Invoke-Root 'iptables -w -t nat -S OUTPUT' -Quiet) -join "`n"
    $flt = (Invoke-Root 'iptables -w -S TMM_FLT' -Quiet) -join "`n"
    $st = [pscustomobject]@{ Uid = ''; Dest = ''; Jump = ($jump -match '-j TMM_OUT'); Udp = ($flt -match 'udp'); Packets = $null }
    foreach ($l in ($nat -split "`n")) {
        if ($l -match 'uid-owner (\d+).*-j DNAT --to-destination (\S+)') { $st.Uid = $Matches[1]; $st.Dest = $Matches[2] }
    }
    $st.Packets = Get-DnatPackets
    return $st
}

function Get-DnatPackets {
    $o = Invoke-Root 'iptables -w -t nat -L TMM_OUT -v -n -x' -Quiet
    foreach ($l in $o) {
        if ($l -match '^\s*(\d+)\s+\d+\s+DNAT') { return [int64]$Matches[1] }
    }
    return $null
}

function Get-SystemProxy {
    return ((AdbQ shell settings get global http_proxy) -join '').Trim()
}

function Test-ProxyHarmless([string]$Value) {
    $ours = "$($script:Cfg.ProxyHostFromDevice):$($script:Cfg.ProxyPort)"
    return ($Value -in @('', 'null', ':0', $ours))
}

function Clear-Redirect {
    $ph = $script:Cfg.ProxyHostFromDevice
    $pp = $script:Cfg.ProxyPort
    $lines = @(
        'iptables -w -t nat -D OUTPUT -j TMM_OUT 2>/dev/null; iptables -w -t nat -F TMM_OUT 2>/dev/null; iptables -w -t nat -X TMM_OUT 2>/dev/null',
        'iptables -w -D OUTPUT -j TMM_FLT 2>/dev/null; iptables -w -F TMM_FLT 2>/dev/null; iptables -w -X TMM_FLT 2>/dev/null',
        'ip6tables -w -D OUTPUT -j TMM_FLT6 2>/dev/null; ip6tables -w -F TMM_FLT6 2>/dev/null; ip6tables -w -X TMM_FLT6 2>/dev/null',
        '# rule cũ tạo bằng tay / script cũ (DNAT thẳng trong OUTPUT, REJECT theo uid)',
        "iptables -w -t nat -S OUTPUT | grep -- '--to-destination ${ph}:$pp' | sed 's/^-A /-D /' | while read r; do iptables -w -t nat `$r; done",
        "iptables -w -S OUTPUT | grep -- '--uid-owner' | grep -- '-j REJECT' | sed 's/^-A /-D /' | while read r; do iptables -w `$r; done",
        "ip6tables -w -S OUTPUT | grep -- '--uid-owner' | grep -- '-j REJECT' | sed 's/^-A /-D /' | while read r; do ip6tables -w `$r; done",
        'echo TMM_CLEAN_DONE'
    )
    return ((Invoke-RootScript 'clean' $lines) -join "`n") -match 'TMM_CLEAN_DONE'
}
