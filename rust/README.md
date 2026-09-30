# Rust API probe — ระยะที่ 1

เริ่ม implementation ตาม [แผนย้าย](../RUST-MIGRATION-PLAN.md) แล้ว แต่ยัง **ไม่พร้อมแทน PowerShell**
ตัวนี้เป็น console diagnostic สำหรับ Windows 11 x64 ไม่ใช่ monitor ที่เฝ้าต่อเนื่อง
ไม่มีการอ่าน config เดิม ส่ง notification หรือเชื่อมต่อบริการภายนอก

## สิ่งที่ทำแล้ว

- Enumerate `rooc.exe` ผ่าน Tool Help และตรวจชื่อ executable ซ้ำผ่าน process handle
- Identity ใช้ PID + process creation FILETIME ตรวจซ้ำหลังอ่าน TCP เพื่อจับ PID reuse/process หายระหว่าง scan
- `GetExtendedTcpTable` แบบ `OWNER_MODULE_ALL` ทั้ง IPv4/IPv6 เก็บทุก game connection พร้อม creation timestamp ไม่เลือก socket แรกเป็น session โดยพลการ
- กรอง Established, loopback, unspecified address และพอร์ต 80/443/8080; เพิ่มการกรอง IPv4-mapped loopback และ `::` ซึ่ง regex เดิมไม่ได้ครอบคลุม
- รายงานหน้าต่าง top-level ที่ visible (รวมหน้าต่าง minimized) ของแต่ละ PID โดยไม่อ่าน title หรือจับ desktop
- ทดลอง WGC แยกต่อหน้าต่าง ใช้ frame pool ใหม่ รอ frame timestamp หลังเริ่ม session สูงสุด 5 วินาที ตรวจ identity ซ้ำก่อนและหลังรับ frame แล้วคืน session/pool/frame
- จับไม่ได้หรือไม่มีหน้าต่าง: รายงาน unavailable ราย client และทำตัวอื่นต่อ ไม่ restore/focus หน้าต่าง

`--capture` รายงานเฉพาะ metadata ของ frame ส่วน `--capture-preview DIR` จะอ่านภาพจาก GPU แล้วบันทึก BMP ลง directory ที่ระบุอย่างชัดเจน ไม่มี upload
หาก client มีหลายหน้าต่าง probe จะลองทุกหน้าต่าง เพื่อเก็บหลักฐานก่อนเลือกว่าอันไหนเป็นหน้าต่างเกมหลัก
จึงยังไม่ใช่พฤติกรรมหนึ่งภาพต่อ client ของ heartbeat ในแผน
Timestamp ใหม่พิสูจน์แค่ว่าได้รับ frame ใหม่ ไม่ได้พิสูจน์ว่าภาพเกมไม่ดำ/ค้างหรือเกมเล่นได้
ต้องเปิดไฟล์ preview และตรวจภาพจริงก่อนผ่าน capture gate (ยังไม่มีหน้าต่าง preview ในแอป)

## Build และตรวจ

ใช้ Rust stable และ MSVC C++ build tools + Windows SDK บน Windows 11 x64:

```powershell
cd rust
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
cargo build --locked --release
.\target\release\rooc-monitor-probe.exe --once
$LASTEXITCODE
.\target\release\rooc-monitor-probe.exe --capture
$LASTEXITCODE
# เลือกบันทึกภาพเพื่อเปิดตรวจเอง: ตั้งใจเก็บเฉพาะใน directory ที่ระบุ
.\target\release\rooc-monitor-probe.exe --capture-preview .\evidence\normal
$LASTEXITCODE
```

`--once` exit code: `0` ทุก client มี socket, `1` มี client ขาด socket, `2` ไม่พบ client,
`3` อ่านข้อมูลไม่ครบ/ผิดพลาด ห้ามแปล code 3 ว่าออนไลน์หรือเกมปิด
ไม่ได้ตรวจ internet หรือยืนยันการแจ้งเตือน เช่นเดียวกับ legacy CLI `-Once`
JSON เก็บ FILETIME เป็น integer 100 ns ตั้งแต่ 1601 UTC (ระวัง JavaScript Number สูญเสีย precision)
ถ้า TCP timestamp เป็นศูนย์/ติดลบ จะรายงาน error และไม่ถือว่า snapshot สมบูรณ์

`--capture` exit code: `0` ได้ fresh frame ครบทุกหน้าต่าง, `1` มี unavailable,
`2` ไม่มี client, `3` snapshot/runtime initialization ผิดพลาด
Frame wait จำกัด 5 วินาทีต่อหน้าต่าง; Windows API/device initialization ไม่ได้มี hard timeout ครอบทั้ง process
`received_unix_ms` คือเวลารับ frame ส่วน `frame_system_relative_100ns` คือ QPC timestamp ของ frame
`--capture` ไม่เก็บภาพลง disk; `--capture-preview` บันทึก BMP พร้อม PID/start time/HWND/เวลารับ frame ในชื่อไฟล์
ไม่เขียนทับไฟล์เดิม จำกัด pixel buffer 64 MiB และ GPU readback ใช้ deadline เดียวกับ frame wait
ไฟล์ภาพอาจมีข้อมูลในหน้าต่างเกม ให้เก็บเฉพาะเพื่อการทดสอบและลบทิ้งเมื่อใช้เสร็จ ไม่มีการส่งภาพหรือ cache ข้าม session

บน macOS/Linux รัน unit/CLI tests ได้และคำสั่ง observe/capture จะจบด้วย code 3:

```sh
cargo test --locked
rustup target add x86_64-pc-windows-msvc
cargo check --locked --target x86_64-pc-windows-msvc --all-targets
```

Cross-target check ไม่ได้ link executable และไม่ใช่การทดสอบ Windows runtime
Workflow `rust-probe.yml` เตรียม build/tests บน Windows แต่ไม่มีเกม/GPU target ให้ยืนยัน capture

ผลตรวจบน macOS วันที่ 2026-09-30: tests 7 รายการผ่าน, Windows x64 cross-target check/Clippy ผ่าน,
format และ whitespace ผ่าน ยังไม่ได้รัน Windows-specific table decoder test, Windows build/link หรือ workflow บน GitHub

## เทียบกับ PowerShell บนเครื่องเกม

ใช้ session ปกติก่อน ถ้า API อ่านไม่ได้ให้เก็บ error แล้วลอง elevated โดยไม่สรุปว่าเกมปิด
รัน probe และคำสั่งต่อไปนี้ใกล้กันขณะเกมคงที่ (แต่ละ scan ไม่ใช่ atomic snapshot):

```powershell
Get-Process -Name rooc -ErrorAction SilentlyContinue | ForEach-Object {
    $client = $_
    [pscustomobject]@{
        Pid = $client.Id
        StartedFiletime = $client.StartTime.ToUniversalTime().ToFileTimeUtc()
    }
    Get-NetTCPConnection -OwningProcess $client.Id -State Established -ErrorAction Stop |
        Where-Object {
            $_.RemoteAddress -notmatch '^(127\.|::1$|0\.0\.0\.0)' -and
            $_.RemotePort -notin @(80,443,8080)
        } |
        Select-Object OwningProcess, LocalAddress, LocalPort, RemoteAddress, RemotePort,
            @{Name='CreatedFiletime'; Expression={$_.CreationTime.ToUniversalTime().ToFileTimeUtc()}}
}
```

เทียบ PID/start time, endpoint ทั้งสองด้าน และ TCP creation timestamp แบบครบชุด ไม่เทียบลำดับแถว
จดผลต่างจาก IPv6 filtering ข้างต้นแยกจาก API mismatch และตรวจว่ามี IPv6 connection จริงก่อนสรุปว่าผ่าน IPv6
ทดสอบ client เดียว/หลายตัว, client เปิดใหม่/ปิดเอง และ session เปลี่ยนโดยผู้ใช้ควบคุม
ห้ามปิดเกมหรือเน็ตเพื่อทดสอบโดยไม่ได้ตกลงกัน

เก็บผลท้องถิ่นใน `rust/evidence/` (ถูก ignore) พร้อม OS build, GPU/driver, เวลา, จำนวน client,
โหมดหน้าต่างและ error code ห้ามแนบ config/credentials ใช้ตารางนี้เป็น acceptance record:

| กรณี | TCP เทียบ PowerShell | WGC fresh frame | ภาพจริง/target ถูกต้อง |
|---|---|---|---|
| ปกติ / ถูกบัง | ยังไม่ทดสอบ | ยังไม่ทดสอบ | ยังไม่ทดสอบ |
| Minimized / fullscreen | ยังไม่ทดสอบ | ยังไม่ทดสอบ | ยังไม่ทดสอบ |
| หลายจอ / ต่าง DPI | ยังไม่ทดสอบ | ยังไม่ทดสอบ | ยังไม่ทดสอบ |
| หลาย client / เปิดใหม่ / ปิดระหว่าง capture | ยังไม่ทดสอบ | ยังไม่ทดสอบ | ยังไม่ทดสอบ |
| Lock screen / ปิดจอ / sleep-resume | ยังไม่ทดสอบ | ยังไม่ทดสอบ | ยังไม่ทดสอบ |

## Gate ที่ยังเปิดอยู่

ระยะ 1 ยังไม่ผ่าน: ต้องตรวจ API/session timestamp กับเครื่องจริง เปิดภาพ preview และตรวจข้อจำกัด capture
จากนั้นจึงย้าย state machine, scheduler, notification, config และ UI ตามระยะ 2–4
ตรรกะ grace/repeat/burst/internet และการแจ้งเตือนของสคริปต์ทั้งสามยังใช้ implementation เดิม

แหล่ง API: [GetExtendedTcpTable](https://learn.microsoft.com/en-us/windows/win32/api/iphlpapi/nf-iphlpapi-getextendedtcptable),
[IPv6 ownership/timestamp](https://learn.microsoft.com/en-us/windows/win32/api/tcpmib/ns-tcpmib-mib_tcp6row_owner_module),
[Windows Graphics Capture](https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/screen-capture)
