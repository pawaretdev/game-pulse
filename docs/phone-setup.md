# Make your phone wake you up

**English** · [ภาษาไทย](phone-setup.th.md) · [Back to README](../README.md)

An alert that arrives silently won't wake you. After setting up your phone, run **Settings › Test your setup › Run drill** once before you sleep.

## Android

1. ntfy › tap your topic › **Notification settings** › turn on **Dedicated channel**.
2. Open that channel: Importance = **Urgent**, vibration on, pick a loud sound.
3. Settings › Sound & vibration › Do Not Disturb › **Apps**: allow ntfy through DND.
4. Settings › Apps › ntfy › Battery › **Unrestricted**, or Android delays notifications at night.

Steps 3 and 4 matter most. Without them you won't wake up.

## iPhone

iOS has **no notification channels** like Android, so the Android importance advice doesn't apply, and ntfy's `Priority: urgent` has almost no effect on iOS.

iOS vibrates once per notification; you can't lengthen or repeat it within one notification. **`BurstCount` is the only control you have**: raise it for more buzzes (see [Why does my phone only buzz once?](how-it-works.md#why-does-my-phone-only-buzz-once)).

On the phone:

1. Settings › Notifications › **ntfy**: turn on Allow Notifications and Sounds, set Banner Style to **Persistent**.
2. Settings › Focus › **Sleep** (or whichever Focus runs at night) › Apps: allow **ntfy** and **Discord**.
   This matters most. Without it, Focus silences everything.
3. If ntfy offers **Time Sensitive Notifications**, turn it on.
4. Make sure the Silent switch is off, and turn off Low Power Mode at night.

If it still doesn't wake you, the only guaranteed option on iOS is a **phone call**. ntfy.sh offers calls on a paid plan; decide whether that's worth the monthly cost.
