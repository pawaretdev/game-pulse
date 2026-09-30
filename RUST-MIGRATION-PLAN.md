# ROOC Monitor: แผนย้ายเป็น Rust

สถานะ: เริ่มระยะ 1 แล้ว มี process/TCP และ WGC fresh-frame probe พร้อม optional BMP preview ใน `rust/`
ยังไม่ผ่าน gate ระยะ 1: ยังไม่ได้เทียบ API บน Windows/เกมจริง และยังไม่ได้ตรวจภาพ preview/ข้อจำกัด capture จริง
ดูคำสั่งและ acceptance checklist ใน [rust/README.md](rust/README.md) ตัว PowerShell ยังเป็นตัวใช้งานหลัก

## เป้าหมายและขอบเขต

- แอป Windows x64 ที่อยู่ใน system tray เปิดทิ้งข้ามคืนได้ ใช้ Rust และ native Windows UI ผ่าน `windows` crate ไม่ต้องรัน PowerShell หรือ WebView
- ใช้ WPF เป็นฐานพฤติกรรมหลัก ตรวจเทียบ WinForms/CLI ก่อนย้าย เพราะ feature และ defaults ต่างกัน
- คงสคริปต์เดิมไว้ใช้งานระหว่างย้าย สร้าง Rust app แยกใน `rust/`
- เพิ่ม option แนบ screenshot เฉพาะ Discord heartbeat ปิดไว้เป็นค่าเริ่มต้น
- เป้าหมายเบื้องต้น Windows 11 x64; หากต้องรองรับ Windows 10 ต้องกำหนดรุ่นขั้นต่ำและทดสอบ capture เพิ่ม
- ไม่เพิ่มการควบคุมเกม การล็อกอิน หรืออ่าน memory เกม

## ขอบเขต screenshot ที่เลือกแล้ว

จับเฉพาะหน้าต่างเกมทุก client ที่เฝ้าอยู่ ตามคำตอบผู้ใช้ ไม่จับ desktop หรือโปรแกรมอื่น
ผูกหน้าต่างกับ PID และ process start time แล้วตรวจ identity ซ้ำก่อน capture เพื่อป้องกัน window handle ถูกนำกลับมาใช้
แนบหนึ่งภาพต่อ client พร้อม PID และเวลาจับจริง; client ที่ไม่มีหน้าต่างหรือจับไม่ได้ให้ระบุใน heartbeat โดยยังส่งภาพของตัวอื่นได้
ตรวจรับเมื่อมีหลาย client, client เปิดใหม่/ปิดระหว่าง capture และบางหน้าต่างจับไม่ได้ โดยภาพต้องไม่สลับ client

## โครงสร้างที่เสนอ

- `core`: state machine ที่รับ snapshot และเวลา ไม่ผูก Windows API เพื่อทดสอบด้วยข้อมูลจำลอง
- `platform/windows`: process identity, TCP IPv4/IPv6, session timestamp, window/display enumeration และ capture
- `notify`: ntfy, Discord, Telegram แยกผลลัพธ์และ timeout ต่อช่องทาง
- `scheduler`: รอบตรวจ, internet probe, repeat, burst, heartbeat และ cancellation ใช้ monotonic time สำหรับระยะเวลา
- `ui`: native controls, tray, status, Settings และ event history ภาษาอังกฤษ อัปเดตเมื่อข้อมูลเปลี่ยน; หยุด refresh ภาพเมื่อซ่อน
- `config/logging`: config มี version/defaults, atomic save, log rotation และปิดบัง credentials ใน error
- worker สำหรับ network/capture แยกจาก UI และวงจรตรวจ คิวมีขีดจำกัด; งานภาพห้ามกั้น alert เร่งด่วน

## ลำดับพัฒนาและเงื่อนไขผ่าน

### 1. พิสูจน์ Windows API และ capture ก่อน

- ทำ prototype อ่าน process/TCP โดยตรงและตรวจข้อมูลเทียบ PowerShell บนเครื่อง Windows
- ตรวจ API ที่ให้ ownership และ creation timestamp รวม IPv6; ห้ามเสีย session detection เมื่อเปลี่ยน API
- ทดลอง Windows Graphics Capture กับเกมจริงตาม target ที่เลือก: ปกติ, ถูกบัง, minimize, fullscreen, หลายจอ/DPI และ lock screen
- หากไม่ได้ frame ใหม่ภายใน timeout ให้รายงาน capture unavailable; ไม่ใช้ภาพเก่าแทนภาพปัจจุบัน
- ไม่ restore/โฟกัสหน้าต่างเกม และไม่เปลี่ยนไปจับทั้ง desktop อัตโนมัติ
- ผ่านเมื่ออ่านสถานะเทียบกันได้ และรู้ข้อจำกัด capture จริงก่อนทำ UI เต็มรูปแบบ

### 2. ย้าย monitor core พร้อม regression tests

- คง Established TCP filtering, ignored ports, grace 30 วินาที/3 รอบ และ internet probe แยก
- แยก client ด้วย PID และ process start time เพื่อไม่ปะปนเมื่อ PID ถูกนำกลับมาใช้
- ตรวจ process หาย, client เปิดใหม่, session เปลี่ยน, recovery และสถานะอินเทอร์เน็ตไม่แน่นอน
- คง first alert, repeat limit, reset หลัง recovery, burst และยกเลิก drill
- ใช้ fake clock/snapshots ทดสอบโดยไม่รอจริงหรือปิดเกม/เน็ตผู้ใช้
- ผ่านเมื่อหลาย client ไม่ล้างสถานะกัน และลำดับ alert/recovery ถูกต้องทุกกรณีหลัก

### 3. ย้ายช่องทางแจ้งเตือนและเพิ่มภาพ heartbeat

- คงช่องทางเดิม; heartbeat ส่งข้อความไปทุกช่องทางที่เปิด ส่วนภาพส่งเฉพาะ Discord
- GUI heartbeat default 4 ชั่วโมง; CLI default ปิด คง semantics `--once` exit 0/1/2 โดยไม่อ้างว่ายืนยัน internet/การส่งข้อความ
- เพิ่ม `Attach screenshot to Discord heartbeat` และ `Preview screenshot` ซึ่ง preview ไม่ส่งข้อความ
- capture เฉพาะเมื่อ heartbeat ถึงรอบ แล้ว resize/encode ในหน่วยความจำพร้อมคืน GPU/ภาพ buffer หลังจบ ไม่มีการอัดต่อเนื่องหรือเก็บภาพลง disk โดยค่าเริ่มต้น
- แนบภาพผ่าน multipart webhook พร้อมเวลาจับภาพและ target; หลาย client ประมวลผลทีละตัวและแบ่งตามข้อจำกัด Discord
- heartbeat ไม่ ping และรายงานจำนวน client/สถานะอินเทอร์เน็ตจริง ไม่ใช้ข้อความรับรองว่าไม่มีปัญหาแบบตายตัว
- capture ล้มเหลว: ส่งข้อความ heartbeat พร้อมเหตุผลว่าไม่มีภาพ
- ไฟล์ใหญ่เกิน: ลดขนาดตามเพดานที่กำหนด; หากส่งภาพไม่ได้แบบทราบแน่ชัดให้ fallback เป็นข้อความ
- HTTP timeout หลัง upload อาจส่งสำเร็จแล้ว: บันทึกผลไม่แน่นอนและจำกัด retry ไม่ส่งซ้ำอย่างไร้ขอบเขต
- ใช้ Discord `wait=true` ตรวจ response และ message ID; เคารพ rate limit แต่ไม่ถือว่า API success ยืนยันมือถือได้รับ
- ป้องกัน heartbeat ซ้อน คิวภาพสะสม และไม่ส่งภาพเก่าค้างหลังเน็ตกลับมา
- ผ่าน mock HTTP tests: success, timeout, 429, 5xx, attachment rejected และช่องทางหนึ่งล้มเหลวไม่ขวางช่องทางอื่น

### 4. แอปใช้งานจริงและ migration

- หน้าหลักแสดงสถานะต่อ client, เวลาเช็ก, internet state และผลส่งล่าสุด พร้อม Settings/tray
- ปิดหน้าต่างขณะเฝ้าแล้วลง tray; เปิดกลับและออกจริงได้; กันเปิดแอปซ้ำ
- อ่าน config เดิมแบบ import ไป config ของ Rust โดยไม่เขียนทับต้นฉบับ; keys ใหม่มี defaults และ validation
- คงการตรวจช่องทางเตือนก่อนเริ่ม รวม explicit log-only/sound mode หากใช้ CLI
- ส่งเป็น release executable ไม่มี console พร้อม README และตัวอย่างเริ่มอัตโนมัติ/CLI ที่ตรงกับเวอร์ชันใหม่
- ผ่านเมื่อเปิด/ปิด Settings, tray, exit และ cancellation ทำงานระหว่าง upload ได้

### 5. ทดสอบบน Windows และเทียบทรัพยากร

- วัด PowerShell เดิมกับ Rust บนเครื่องเดียวกันและจำนวน client เท่ากัน: CPU เฉลี่ย/ช่วงตรวจ, private bytes/working set, handles, GPU และ peak ระหว่าง capture
- ทดสอบเปิด UI กับซ่อน tray รวมรันข้ามคืน ตรวจหน่วยความจำ/handles ไม่สะสมและ log มีขีดจำกัด
- ตรวจเกมย่อ/ถูกบัง, ปิดจอ, lock screen, sleep/resume, target หาย และ capture unavailable แยกจากสถานะเกม
- ทดสอบ Discord ภาพจริงกับช่องทางทดสอบที่ผู้ใช้ระบุและอนุญาต แล้วตรวจบนมือถือก่อนสรุปว่าส่งถึง
- ถือว่าพร้อมแทนตัวเดิมเมื่อ feature สำคัญครบและผลวัดผ่าน; ยังไม่ตั้งคำรับรอง RAM/CPU ก่อนมี baseline

## แหล่งอ้างอิง

- Windows API จาก Rust: https://learn.microsoft.com/en-us/windows/dev-environment/rust/rust-for-windows
- TCP ownership/session timestamp: https://learn.microsoft.com/en-us/windows/win32/api/tcpmib/ns-tcpmib-mib_tcprow_owner_module
- Window/display capture: https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/screen-capture
- Discord multipart attachments และ wait: https://docs.discord.com/developers/resources/webhook#execute-webhook

แผนนี้อ้างอิง README, AGENTS.md และเส้นทางตรวจจับ/heartbeat ในสคริปต์เดิม ไม่ใช่ผลทดสอบ runtime; Windows/game capture และผลรับบนมือถือยังต้องทดสอบจริง
