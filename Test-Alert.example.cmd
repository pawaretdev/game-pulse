@echo off
chcp 65001 >nul
REM ยิงข้อความทดสอบไปมือถือ - รันอันนี้ก่อนนอนทุกครั้งที่เปลี่ยนอะไร
REM ถ้ามือถือไม่เด้ง แปลว่ายังไม่พร้อม อย่าเพิ่งไว้ใจ

set "TOPIC=YOUR-TOPIC-HERE"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Watch-RoocOnline.ps1" ^
    -NtfyTopic "%TOPIC%" -TestAlert

pause
