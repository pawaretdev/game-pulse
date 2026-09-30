# ตั้งมือถือให้ปลุกติด

[English](phone-setup.md) · **ภาษาไทย** · [กลับไปที่ README](../README.th.md)

แจ้งเตือนที่มาถึงแบบเงียบๆ ปลุกใครไม่ได้ ตั้งมือถือเสร็จแล้วให้กด **Settings > Test your setup > Run drill** สักครั้งก่อนนอน

## Android

1. ntfy > กด topic > **Notification settings** > เปิด **Dedicated channel**
2. เข้า channel นั้น ตั้ง Importance = **Urgent**, เปิด Vibration, เลือกเสียงที่ดัง
3. Settings > Sound & vibration > Do Not Disturb > **Apps** > อนุญาต ntfy ให้ผ่าน DND
4. Settings > Apps > ntfy > Battery > **Unrestricted** (ไม่งั้น Android จะหน่วง notification ตอนดึก)

ข้อ 3 กับ 4 สำคัญมาก ถ้าไม่ทำ ยังไงก็ไม่ตื่น

## iPhone

iOS **ไม่มี notification channel** เหมือน Android เพราะงั้นคำแนะนำแนวตั้ง importance ของ channel
ใช้ไม่ได้ทั้งหมด และ `Priority: urgent` ที่ ntfy ส่งไปแทบไม่มีผลบน iOS

iOS สั่นหนึ่งครั้งต่อ notification หนึ่งใบ จบ ยืดไม่ได้ ทำซ้ำในใบเดียวไม่ได้
เพราะงั้น **`BurstCount` คือกลไกเดียวที่ควบคุมได้** อยากสั่นรัวขึ้นก็เพิ่มจำนวนใบ (ดู [ทำไมมือถือสั่นแค่ทีเดียว](how-it-works.th.md#ทำไมมือถือสั่นแค่ทีเดียว))

สิ่งที่ควรตั้งบนเครื่อง:

1. Settings > Notifications > **ntfy** — เปิด Allow Notifications, Sounds, และตั้ง Banner Style เป็น **Persistent**
2. Settings > Focus > **Sleep** (หรือ Focus ที่เปิดตอนนอน) > Apps > อนุญาต **ntfy** และ **Discord**
   ข้อนี้สำคัญที่สุด ถ้าไม่ทำ Focus จะกลืนทุกอย่างเงียบสนิท
3. ถ้าในหน้า Notifications ของ ntfy มีตัวเลือก **Time Sensitive Notifications** ให้เปิดด้วย
4. เช็คว่าไม่ได้เปิด Silent switch ค้างไว้ และปิด Low Power Mode ตอนกลางคืน

ถ้าทำครบแล้วยังไม่ตื่น เหลือทางเดียวที่การันตีได้จริงบน iOS คือให้มัน**โทรเข้า**
ntfy.sh มีฟีเจอร์โทรในแพ็กเกจเสียเงิน ต้องชั่งน้ำหนักเอาว่าคุ้มกับค่ารายเดือนไหม
