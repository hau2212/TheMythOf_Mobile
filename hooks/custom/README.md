# Script Frida tự viết

- `hooks/custom/*.js`: nạp vào **mọi** app khi chạy hook.
- `hooks/custom/<package>/*.js`: chỉ nạp cho app đó. Ví dụ `hooks/custom/com.example.app/bypass-root.js`.

Script được nạp sau script hook chính (Flutter hoặc HTTP Toolkit), theo thứ tự tên file.
