# Làm bằng tay từ đầu (không dùng script)

Đây đúng là những gì `mobile.ps1 auto` làm. Muốn được dẫn từng bước kèm kiểm tra tự động thì chạy `.\mobile.ps1 learn`.

Ký hiệu:
- `<SERIAL>`: serial máy ảo, ví dụ `emulator-5554`.
- `<PKG>`: package id của app.
- `<UID>`: UID của app.
- `<HASH>`: hash cert của Burp, ví dụ `9a5ba575`.
- `<V>`: version frida.

Máy dùng Magisk thì chạy lệnh root theo dạng `adb shell su -c "..."`. Image Google APIs đã `adb root` thì bỏ `su -c`.

## 1. Host

```powershell
adb version                                   # %LOCALAPPDATA%\Android\Sdk\platform-tools
py --version                                  # Python 3
py -m venv tools\venv
tools\venv\Scripts\python -m pip install frida frida-tools
tools\venv\Scripts\frida --version            # = <V>
Set-Alias frida "$PWD\tools\venv\Scripts\frida.exe"
Set-Alias frida-ps "$PWD\tools\venv\Scripts\frida-ps.exe"
```

## 2. Máy ảo

Tạo trong Android Studio: Device Manager > Create Virtual Device > Pixel > image **x86_64**.

| Image | Root | Play Store |
|---|---|---|
| Google APIs | `adb root` có sẵn | không |
| Google Play | phải dùng rootAVD + Magisk | có |

```powershell
emulator -list-avds
emulator -avd <TEN_AVD>                      # thêm -no-snapshot-load để cold boot
adb devices
adb shell getprop sys.boot_completed          # 1
adb shell getprop ro.build.version.sdk        # 34 = Android 14
adb shell getprop ro.product.cpu.abi          # x86_64
```

## 3. Root

```powershell
adb root                                      # Google APIs
adb shell id                                  # uid=0(root)
```

Với image Google Play:

```powershell
# tải https://gitlab.com/newbit/rootAVD (Download zip), giải nén, AVD đang chạy
cd rootAVD-master
.\rootAVD.bat ListAllAVDs
.\rootAVD.bat system-images\android-34\google_apis_playstore\x86_64\ramdisk.img
# AVD tự tắt -> Cold Boot Now -> mở app Magisk (Additional Setup -> OK)
adb shell su -c id                            # bấm GRANT trên máy ảo
```

Gỡ root: `.\rootAVD.bat <ramdisk.img> restore`.

## 4. Burp

- Proxy > Proxy settings > listener cổng `8080`, Running.
- Edit > Request handling > tick **Support invisible proxying**.
- Intercept: off.

```powershell
Invoke-WebRequest http://127.0.0.1:8080/cert -OutFile burp-ca.der
openssl x509 -inform DER -in burp-ca.der -subject_hash_old -noout     # <HASH>
openssl x509 -inform DER -in burp-ca.der -out <HASH>.0                # PEM
```

## 5. CA vào system store (tạm, mất sau reboot)

```powershell
adb push <HASH>.0 /data/local/tmp/
adb shell
su
```

```sh
H=<HASH>
T=/data/local/tmp/tmm-ca-copy
rm -rf $T; mkdir -p -m 700 $T
if [ -d /apex/com.android.conscrypt/cacerts ]; then cp /apex/com.android.conscrypt/cacerts/* $T/; else cp /system/etc/security/cacerts/* $T/; fi
mount -t tmpfs tmpfs /system/etc/security/cacerts
mv $T/* /system/etc/security/cacerts/
cp /data/local/tmp/$H.0 /system/etc/security/cacerts/
chown root:root /system/etc/security/cacerts/*
chmod 644 /system/etc/security/cacerts/*
chcon u:object_r:system_file:s0 /system/etc/security/cacerts/*
# Android 14+: bind vào APEX trong namespace của zygote và các app
if [ -d /apex/com.android.conscrypt/cacerts ]; then
  ZP="$(pidof zygote) $(pidof zygote64)"
  for Z in $ZP; do nsenter --mount=/proc/$Z/ns/mnt -- /bin/mount --bind /system/etc/security/cacerts /apex/com.android.conscrypt/cacerts; done
  for Z in $ZP; do for P in $(ps -o PID -P $Z | grep -v PID); do nsenter --mount=/proc/$P/ns/mnt -- /bin/mount --bind /system/etc/security/cacerts /apex/com.android.conscrypt/cacerts & done; done
  wait
fi
```

Muốn CA tồn tại qua reboot: cài CA vào User store (Settings > Security > Install certificate), rồi cài module Magisk
**AlwaysTrustUserCerts** (Android ≤ 13) hoặc **ConscryptTrustUserCerts** (Android 14+).

## 6. App

```powershell
adb shell pm list packages -3 -U              # package + uid
adb install -r app.apk
adb install-multiple -r base.apk split_config.x86_64.apk
adb shell pm path <PKG>
adb pull /data/app/.../base.apk .
adb shell dumpsys package <PKG> | findstr "userId primaryCpuAbi"
```

Mở APK bằng 7-Zip để nhận diện framework:

| File trong APK | Framework |
|---|---|
| `lib/*/libflutter.so` | Flutter |
| `libreactnativejni.so` / `libhermes.so` | React Native |
| `libmonodroid.so` | Xamarin |
| `libil2cpp.so` / `libunity.so` | Unity |
| không có các file trên | Java/Kotlin |

App Flutter chỉ có `arm64-v8a` mà chạy trên emulator x86_64 thì đang chạy qua lớp dịch ARM, khi đó Frida không patch được `libflutter.so`.

## 7. frida-server

```powershell
# https://github.com/frida/frida/releases/download/<V>/frida-server-<V>-android-x86_64.xz  (giải nén bằng 7-Zip)
adb push frida-server-<V>-android-x86_64 /data/local/tmp/frida-server
adb shell su -c "chmod 755 /data/local/tmp/frida-server"
adb shell su -c "/data/local/tmp/frida-server -D"
frida-ps -U
```

## 8. iptables theo UID

```sh
UID_APP=<UID>
iptables -w -t nat -N TMM_OUT 2>/dev/null; iptables -w -t nat -F TMM_OUT
iptables -w -t nat -C OUTPUT -j TMM_OUT 2>/dev/null || iptables -w -t nat -A OUTPUT -j TMM_OUT
iptables -w -t nat -A TMM_OUT -m owner --uid-owner $UID_APP -p tcp -d 127.0.0.0/8 -j RETURN
iptables -w -t nat -A TMM_OUT -m owner --uid-owner $UID_APP -p tcp -j DNAT --to-destination 10.0.2.2:8080
iptables -w -N TMM_FLT 2>/dev/null; iptables -w -F TMM_FLT
iptables -w -C OUTPUT -j TMM_FLT 2>/dev/null || iptables -w -I OUTPUT 1 -j TMM_FLT
iptables -w -A TMM_FLT -m owner --uid-owner $UID_APP -p udp ! --dport 53 -j REJECT
ip6tables -w -N TMM_FLT6 2>/dev/null; ip6tables -w -F TMM_FLT6
ip6tables -w -C OUTPUT -j TMM_FLT6 2>/dev/null || ip6tables -w -I OUTPUT 1 -j TMM_FLT6
ip6tables -w -A TMM_FLT6 -m owner --uid-owner $UID_APP -p tcp -j REJECT
iptables -w -t nat -L TMM_OUT -v -n -x        # cột pkts của dòng DNAT
```

```powershell
adb shell settings get global http_proxy      # null hoặc :0
adb shell settings put global http_proxy :0   # gỡ proxy cũ
```

## 9. Hook

```powershell
adb shell am force-stop <PKG>
# Flutter: script NVISO (+ pattern trong hooks\flutter\extra-patterns.json)
frida -U -f <PKG> -l disable-flutter-tls.js          # đợi: ssl_verify_peer_cert has been patched
# Java/Kotlin: HTTP Toolkit (sửa CERT_PEM trong config.js)
frida -U -f <PKG> -l config.js -l native-tls-hook.js -l android/android-system-certificate-injection.js -l android/android-certificate-unpinning.js -l android/android-certificate-unpinning-fallback.js
```

Không đóng app sau khi hook. Nếu app báo lỗi ngay lúc mở thì đăng xuất rồi đăng nhập lại.
Cuối cùng kiểm tra **Burp > Proxy > HTTP history**.

## Gỡ

```sh
iptables -w -t nat -D OUTPUT -j TMM_OUT; iptables -w -t nat -F TMM_OUT; iptables -w -t nat -X TMM_OUT
iptables -w -D OUTPUT -j TMM_FLT; iptables -w -F TMM_FLT; iptables -w -X TMM_FLT
ip6tables -w -D OUTPUT -j TMM_FLT6; ip6tables -w -F TMM_FLT6; ip6tables -w -X TMM_FLT6
pkill -f frida-server
```
