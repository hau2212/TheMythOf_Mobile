# Thư mục cài app

Chép file `.apk`, `.apks` hoặc `.xapk` vào đây, rồi chọn **5. App > Cài APK từ thư mục apps\\** trong menu.

- `.apk`: cài bằng `adb install -r -g`.
- `.apks` / `.xapk`: giải nén rồi cài bằng `adb install-multiple` (split APK). File OBB không được chép tự động.
- `.apkm` (APKMirror) bị mã hoá: cài bằng app APKMirror Installer trên máy ảo.

Lưu ý: nên lấy bản có thư viện **x86_64** (hoặc universal) cho emulator x86_64. App Flutter chỉ có `arm64-v8a`
sẽ chạy qua lớp dịch ARM, khi đó Frida không patch được `libflutter.so`.
