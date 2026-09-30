@echo off
chcp 65001 >nul
REM ===============================================================
REM  ดับเบิลคลิกเพื่อเริ่มเฝ้าดูว่า Ragnarok Origin หลุดหรือยัง
REM  เตือนเข้ามือถือผ่าน ntfy (เสียงที่เครื่องนี้ปิดไว้)
REM
REM  ต้องทำครั้งเดียวก่อนใช้:
REM    1. ลงแอป "ntfy" จาก Play Store / App Store
REM    2. กด + แล้ว subscribe topic ชื่อตรงตามบรรทัด TOPIC ข้างล่างนี้เป๊ะๆ
REM    3. รัน Test-Alert.cmd เพื่อเช็คว่ามือถือได้รับจริง
REM
REM  ชื่อ topic นี้สุ่มมาให้แล้ว ห้ามบอกใคร - ใครรู้ชื่อ topic ก็อ่านข้อความได้
REM ===============================================================

set "TOPIC=YOUR-TOPIC-HERE"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Watch-RoocOnline.ps1" ^
    -NtfyTopic "%TOPIC%" ^
    -IntervalSec 30 ^
    -GraceChecks 3 ^
    -RepeatAlertMin 3 ^
    -MaxRepeats 20 ^
    -HeartbeatHours 4

pause
