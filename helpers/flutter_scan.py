#!/usr/bin/env python3
"""flutter_scan.py - kiem tra pattern ssl_verify_peer_cert tren libflutter.so, va (x86_64) tu tim pattern moi.

Chi dung thu vien chuan cua Python.

  python flutter_scan.py libflutter.so --js disable-flutter-tls.js [--extra extra-patterns.json] [--write]

Ket qua:
  - Liet ke pattern nao trong script match bao nhieu lan (script Frida dung pattern dau tien co match).
  - Neu khong pattern nao match (hoac match nhieu cho) va lib la x86_64: lan theo chuoi
    'ssl/handshake.cc' + ma loi SSL_R_CERTIFICATE_VERIFY_FAILED (0x86) de tim ham ssl_verify_peer_cert,
    sinh pattern moi, kiem tra pattern do chi match 1 lan, va (--write) ghi vao extra-patterns.json.
Exit code: 0 = co pattern dung duoc, 1 = khong.
"""
import argparse
import hashlib
import json
import os
import re
import struct
import sys

EM_NAMES = {62: "x64", 183: "arm64", 3: "x86", 40: "arm"}
SHF_EXECINSTR = 0x4


def parse_elf(data):
    if data[:4] != b"\x7fELF":
        raise ValueError("Khong phai file ELF")
    is64 = data[4] == 2
    end = "<" if data[5] == 1 else ">"
    if is64:
        hdr = struct.unpack_from(end + "HHIQQQIHHHHHH", data, 16)
        sh_fmt = end + "IIQQQQIIQQ"
    else:
        hdr = struct.unpack_from(end + "HHIIIIIHHHHHH", data, 16)
        sh_fmt = end + "IIIIIIIIII"
    e_machine, e_shoff, e_shentsize, e_shnum, e_shstrndx = hdr[1], hdr[5], hdr[10], hdr[11], hdr[12]
    secs = []
    for i in range(e_shnum):
        f = struct.unpack_from(sh_fmt, data, e_shoff + i * e_shentsize)
        secs.append({"name_off": f[0], "type": f[1], "flags": f[2], "addr": f[3], "offset": f[4], "size": f[5]})
    strtab = secs[e_shstrndx]["offset"] if secs else 0
    for s in secs:
        raw = data[strtab + s["name_off"]:]
        s["name"] = raw[:raw.index(b"\0")].decode(errors="replace")
    return EM_NAMES.get(e_machine, str(e_machine)), secs


def pattern_regex(pat):
    out = b""
    for tok in pat.split():
        tok = tok.upper()
        if tok == "??":
            out += b"."
        elif tok[1] == "?":
            hi = int(tok[0], 16)
            out += b"[" + re.escape(bytes([hi << 4])) + b"-" + re.escape(bytes([(hi << 4) | 0xF])) + b"]"
        elif tok[0] == "?":
            lo = int(tok[1], 16)
            out += b"[" + b"".join(re.escape(bytes([(h << 4) | lo])) for h in range(16)) + b"]"
        else:
            out += re.escape(bytes([int(tok, 16)]))
    return re.compile(out, re.DOTALL)


def exec_ranges(data, secs):
    for s in secs:
        if s["flags"] & SHF_EXECINSTR and s["type"] != 8 and s["size"]:
            yield s


def find_pattern(data, secs, pat):
    rx = pattern_regex(pat)
    hits = []
    for s in exec_ranges(data, secs):
        blob = data[s["offset"]:s["offset"] + s["size"]]
        for m in rx.finditer(blob):
            hits.append(s["addr"] + m.start())
    return hits


def load_js_patterns(js_text, arch):
    """Lay cac pattern trong khoi "android" -> arch cua script NVISO."""
    a = js_text.find('"android"')
    if a < 0:
        return []
    m = re.compile(r'"%s"\s*:\s*\[' % re.escape(arch)).search(js_text, a)
    if not m:
        return []
    depth, i = 1, m.end()
    while i < len(js_text) and depth:
        if js_text[i] == "[":
            depth += 1
        elif js_text[i] == "]":
            depth -= 1
        i += 1
    block = js_text[m.end():i - 1]
    res = []
    for pm in re.finditer(r'pattern\s*:\s*"([^"]+)"\s*,\s*retval\s*:\s*(\d+)', block):
        res.append({"pattern": pm.group(1), "retval": int(pm.group(2)), "source": "js"})
    return res


def load_extra(path, arch):
    if not path or not os.path.exists(path):
        return []
    with open(path, encoding="utf-8-sig") as f:
        doc = json.load(f)
    return [dict(p, source="extra") for p in doc.get("android", {}).get(arch, [])]


def vaddr_to_off(secs, va):
    for s in secs:
        if s["type"] != 8 and s["addr"] <= va < s["addr"] + s["size"] and s["addr"]:
            return s["offset"] + (va - s["addr"])
    return None


def eh_frame_funcs(data, secs):
    """Doc bang .eh_frame_hdr -> list (start, size). Chi ho tro encoding pho bien (clang/Android)."""
    hdr = next((s for s in secs if s["name"] == ".eh_frame_hdr"), None)
    if not hdr:
        return []
    o = hdr["offset"]
    ver, ptr_enc, cnt_enc, tbl_enc = data[o:o + 4]
    if ver != 1 or ptr_enc != 0x1B or cnt_enc != 0x03 or tbl_enc != 0x3B:
        return []
    count = struct.unpack_from("<I", data, o + 8)[0]
    funcs = []
    for i in range(count):
        loc_rel, fde_rel = struct.unpack_from("<ii", data, o + 12 + i * 8)
        start = hdr["addr"] + loc_rel
        fde_va = hdr["addr"] + fde_rel
        fo = vaddr_to_off(secs, fde_va)
        size = struct.unpack_from("<i", data, fo + 12)[0] if fo is not None else 0
        funcs.append((start, size))
    funcs.sort()
    return funcs


def owner(funcs, va):
    lo, hi, best = 0, len(funcs) - 1, None
    while lo <= hi:
        mid = (lo + hi) // 2
        if funcs[mid][0] <= va:
            best, lo = funcs[mid], mid + 1
        else:
            hi = mid - 1
    if best and best[0] <= va < best[0] + best[1]:
        return best
    return None


def locate_x64(data, secs):
    """Tim ssl_verify_peer_cert: ham co 'lea reg,[rip+"...ssl/handshake.cc"]' gan 'mov edx,0x86'."""
    targets = set()
    for s in secs:
        if s["flags"] & SHF_EXECINSTR or s["type"] == 8 or not s["addr"]:
            continue
        blob = data[s["offset"]:s["offset"] + s["size"]]
        for m in re.finditer(rb"[\x20-\x7e]*ssl/handshake\.cc\x00", blob):
            targets.add(s["addr"] + m.start())
    if not targets:
        return None, "khong thay chuoi ssl/handshake.cc"
    # OPENSSL_PUT_ERROR(SSL, reason): reason nam o esi (BoringSSL moi) hoac edx (cu).
    # SSL_R_SERVER_CERT_CHANGED (0x111) chi co trong ssl_verify_peer_cert -> diem cao;
    # SSL_R_CERTIFICATE_VERIFY_FAILED (0x86) co ca trong ssl_reverify_peer_cert -> diem thap.
    markers = {b"\xbe\x11\x01\x00\x00": 2, b"\xba\x11\x01\x00\x00": 2,
               b"\xbe\x86\x00\x00\x00": 1, b"\xba\x86\x00\x00\x00": 1}
    lea = re.compile(rb"[\x48\x4c]\x8d[\x05\x0d\x15\x1d\x25\x2d\x35\x3d]", re.DOTALL)
    cands = []
    for s in exec_ranges(data, secs):
        blob = data[s["offset"]:s["offset"] + s["size"]]
        for m in lea.finditer(blob):
            i = m.start()
            rel = struct.unpack_from("<i", blob, i + 3)[0]
            va = s["addr"] + i
            if va + 7 + rel in targets:
                win = blob[max(0, i - 40):i + 40]
                score = max([w for mk, w in markers.items() if mk in win] or [0])
                if score:
                    cands.append((va, score))
    if not cands:
        return None, "khong thay xref handshake.cc + ma loi SERVER_CERT_CHANGED/CERTIFICATE_VERIFY_FAILED"
    funcs = eh_frame_funcs(data, secs)
    if not funcs:
        return None, "khong doc duoc .eh_frame_hdr de xac dinh ranh gioi ham"
    owners = {}
    for c, score in cands:
        f = owner(funcs, c)
        if f:
            owners[f] = max(owners.get(f, 0), score)
    if not owners:
        return None, "khong xac dinh duoc ham chua xref"
    # Uu tien diem cao, roi den ham lon hon (ssl_reverify_peer_cert nho hon nhieu)
    best = max(owners, key=lambda f: (owners[f], f[1]))
    return best, "ung vien: " + ", ".join("%#x(%d B, diem %d)" % (f[0], f[1], owners[f]) for f in sorted(owners))


def make_pattern(data, secs, start):
    off = vaddr_to_off(secs, start)
    for n in (32, 40, 48, 64, 96):
        pat = " ".join("%02X" % b for b in data[off:off + n])
        if len(find_pattern(data, secs, pat)) == 1:
            return pat
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("lib")
    ap.add_argument("--js", help="script disable-flutter-tls.js (NVISO)")
    ap.add_argument("--extra", help="extra-patterns.json")
    ap.add_argument("--write", action="store_true", help="ghi pattern moi vao --extra")
    a = ap.parse_args()

    data = open(a.lib, "rb").read()
    arch, secs = parse_elf(data)
    sha = hashlib.sha256(data).hexdigest()
    print("[i] File: %s" % a.lib)
    print("[i] Kien truc: %s   sha256: %s..." % (arch, sha[:16]))
    ver = re.search(rb"(\d+\.\d+\.\d+) \((stable|beta|dev)\)", data)
    if ver:
        print("[i] Dart: %s" % ver.group(0).decode())

    pats = []
    if a.js and os.path.exists(a.js):
        pats += load_js_patterns(open(a.js, encoding="utf-8", errors="replace").read(), arch)
    pats += [p for p in load_extra(a.extra, arch) if p["pattern"] not in {q["pattern"] for q in pats}]
    print("[i] So pattern %s dang co: %d" % (arch, len(pats)))

    first = None
    for i, p in enumerate(pats, 1):
        hits = find_pattern(data, secs, p["pattern"])
        tag = "OK" if len(hits) == 1 else ("NHIEU" if hits else "--")
        print("  [%s] #%d (%s) match=%d %s" % (tag, i, p["source"], len(hits), " ".join(hex(h) for h in hits[:4])))
        if hits and first is None:
            first = (i, hits)
    if first:
        i, hits = first
        print("[+] Script Frida se dung pattern #%d -> %s" % (i, hex(hits[0])))
        if len(hits) == 1:
            return 0
        print("[!] Pattern #%d match %d cho, co the patch nham ham" % (i, len(hits)))

    if arch != "x64":
        print("[!] Khong tim duoc pattern dung. Tu dong tim ham chi ho tro x86_64 (emulator).")
        print("    Voi %s: mo issue kem file libflutter.so tai github.com/NVISOsecurity/disable-flutter-tls-verification" % arch)
        return 1

    print("[ ] Dang tim ssl_verify_peer_cert bang cach lan theo chuoi handshake.cc ...")
    func, why = locate_x64(data, secs)
    print("    " + why)
    if not func:
        return 1
    start, size = func
    print("[+] ssl_verify_peer_cert ~ %#x (kich thuoc %d bytes)" % (start, size))
    pat = make_pattern(data, secs, start)
    if not pat:
        print("[!] Khong tao duoc pattern duy nhat")
        return 1
    print("[+] Pattern moi (match dung 1 lan):")
    print("    " + pat)
    if a.write and a.extra:
        doc = {"android": {}}
        if os.path.exists(a.extra):
            with open(a.extra, encoding="utf-8-sig") as f:
                doc = json.load(f)
        lst = doc.setdefault("android", {}).setdefault(arch, [])
        if pat not in [p["pattern"] for p in lst]:
            lst.append({"pattern": pat, "retval": 0,
                        "note": "flutter_scan auto, sha256 %s, offset %#x" % (sha[:16], start)})
            with open(a.extra, "w", encoding="utf-8") as f:
                json.dump(doc, f, indent=2)
            print("[+] Da ghi vao %s. Chay lai hook de dung pattern moi." % a.extra)
    return 0


if __name__ == "__main__":
    sys.exit(main())
