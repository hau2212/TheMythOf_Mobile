# Lỗi thường gặp

Chạy `.\mobile.ps1 check` để xem giai đoạn nào đang FAIL. Chi tiết lệnh và output nằm trong `logs\session-*.log`.

## Xác định traffic đang tắc ở mức nào

| Mức | Xem ở đâu | Đạt khi |
|---|---|---|
| 1. Bị ép sang Burp | `iptables -t nat -L TMM_OUT -v -n -x` (script in "đã chuyển N gói") | pkts của dòng DNAT tăng khi dùng app |
| 2. Tới được Burp | Burp > Dashboard > Event log | có kết nối tới host của app, không có lỗi TLS |
| 3. Giải mã được | Burp > Proxy > HTTP history | đọc được request/response |

## Bảng lỗi

| Hiện tượng | Nguyên nhân | Cách sửa |
|---|---|---|
| DNAT pkts = 0 | UID đổi do cài lại app, máy ảo reboot, hoặc app giữ kết nối cũ | `resume`, rồi `hook` (script tự force-stop app) |
| Burp Event log: `violates HTTP protocol` | chưa bật invisible proxying | Burp > listener > Request handling > Support invisible proxying |
| Burp Event log: `certificate_unknown` / `Remote host terminated the handshake` | app từ chối CA: hook chưa patch, hoặc CA chưa vào system store | xem log frida; với Flutter chạy `flutter-scan` |
| Frida: `ssl_verify_peer_cert could not be located` | pattern không khớp bản libflutter.so | menu 7 (`flutter-scan`) |
| Frida: `Flutter library not found` | app chưa nạp Flutter, không phải Flutter, hoặc chạy qua lớp dịch ARM | kiểm tra framework/ABI ở giai đoạn 6 |
| App báo lỗi ngay lúc mở (vd `-6 Lỗi kiểm tra phân quyền`) | request đầu tiên chạy trước khi hook xong | **không tắt app**, đăng xuất rồi đăng nhập lại |
| `frida-ps` lỗi / `unable to connect` | frida-server chết hoặc lệch version | `resume` (giai đoạn 7 tự thay đúng bản) |
| Chrome trên máy ảo: `ERR_PROXY_CONNECTION_FAILED` | proxy hệ thống cũ trỏ vào Burp đang tắt | `adb shell settings put global http_proxy :0` (script tự gỡ ở giai đoạn 8) |
| `su: not found` / không có popup Grant | Magisk chưa xong Additional Setup | mở app Magisk, bấm OK, chờ reboot |
| `adbd cannot run as root in production builds` | image Google Play | để script root bằng rootAVD, hoặc dùng image Google APIs |
| rootAVD báo lỗi trên Windows | chạy trong PowerShell, hoặc AVD chưa bật | script đã gọi qua `cmd.exe`; bật AVD trước rồi chạy lại |
| `Unauthorized` trong `adb devices` | chưa chấp nhận RSA key | bấm Allow trên máy |
| Script không chạy: `running scripts is disabled` | Execution Policy | dùng `Start.cmd` (đã có `-ExecutionPolicy Bypass`) |
| Chữ tiếng Việt bị lỗi font | console cũ | dùng Windows Terminal; `Start.cmd` đã đặt `chcp 65001` |
| App Flutter chỉ có thư viện arm64 | emulator x86_64 chạy app qua lớp dịch ARM | tìm bản APK có x86_64, hoặc dùng máy thật / emulator ARM64 |

## Sau khi tắt/mở máy ảo

- **Quick boot** khôi phục cả RAM, nên frida-server, iptables và CA tạm thường vẫn còn.
- **Cold boot** thì mất 3 thứ đó. Script so `boot_id` để báo cho bạn, sau đó chạy `resume`.
- **Cài lại app** thì UID đổi: `resume` phát hiện ra *"đang DNAT UID cũ"* và tạo lại rule.
