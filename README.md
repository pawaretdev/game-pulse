<p align="center"><img src="assets/icon-256.png" width="128" alt="GamePulse icon"></p>

<h1 align="center">GamePulse</h1>

<p align="center"><b>English</b> · <a href="README.th.md">ภาษาไทย</a></p>

A small Windows tray app that watches your game clients and alerts your phone the moment one disconnects, so you can leave characters logged in overnight and still sleep.

- Supported game: **Ragnarok Origin Classic** (`rooc.exe`). The main screen is a game library; watch several games at once
- Checks every 30 seconds that each game client still holds its game-server connection
- Alerts through the **ntfy** app, a **Discord** webhook or a **Telegram** bot, and repeats until the client is back
- Never reads game memory, clicks anything or touches your account
- Keeps watching from the system tray when you close the window

Sound on the PC is off by default, since you are usually asleep in another room. The app refuses to start watching until at least one phone channel is set up, so you can't leave it running all night with nobody to alert.

<p align="center">
  <img src="docs/library.png" width="49%" alt="GamePulse game library with alerts on and both clients online">
  <img src="docs/game.png" width="49%" alt="Game page showing each client's connection and session time">
</p>

## Getting started

1. Download `gamepulse-vX.Y.Z-windows-x64.zip` from [Releases](https://github.com/pawaretdev/game-pulse/releases/latest) and unzip it into a folder you will keep (for example `C:\Tools\GamePulse`). There is no installer.
2. Double-click **`gamepulse.exe`**. No console window appears.
   The first time, Windows may show "Windows protected your PC" because the file is not code-signed. Click **More info › Run anyway**.
3. A **4-step setup** opens on first launch. It walks you through choosing an alert channel, sending a test alert to your phone, making your phone actually wake you up (Android and iPhone), and whether to open at Windows sign-in and start watching automatically.
4. Before you sleep, run a drill at least once: **Settings › Test your setup › Run drill**. It proves the alerts **wake you up**, which is a different thing from them arriving.
5. Leave it running. Closing the window hides it to the tray and it keeps watching.

The **Guide** button on the main screen explains every status, when you get alerted, each setting, phone setup and troubleshooting. It also has **Run setup again**.

Using ntfy: install the **ntfy** app from the Play Store or App Store, tap **+** and subscribe to the same topic you entered in the app. The setup screen has **Generate** (a hard-to-guess name) and **Copy** buttons.
Keep the topic private. ntfy.sh is a public server and anyone who knows the topic can read your alerts. Alerts contain only a PID and times, no account data. To keep them fully private, self-host ntfy and enter it as `ntfy server`.

## The main screen

- The **library** shows one card per supported game with its live status on the cover (`2/2 ONLINE`, `1 DISCONNECTED`, `NOT RUNNING`). A card with a disconnect you are watching gets a red border.
- The **Alerts on / off** switch on each card picks which games alert you. Turn on several to watch several games at once. The filter chips show All, only games with alerts on, or only running games.
- Click a card to open that game: a header with the cover, status and alert switch, then one card per client. **Library** goes back.
- The header shows the overall status (ALL ONLINE / 1 DISCONNECTED / GAME NOT RUNNING / PAUSED), internet status and the Start/Pause button.
- Below it: when the last check ran and when the next one is due.
- One card per client: ONLINE or disconnected, PID, server address, and how long the session has lasted or how long it has been down.
  While a connection is missing but the grace checks haven't finished, the card shows `CONFIRMING 1/3` in amber.
- **Events** lists drops and alert deliveries. A check result only appears when it changes; the log file records every check.
- The footer shows your alert channels and when the next heartbeat is due.
- Closing the window hides it to the tray. Left-click the tray icon to reopen it; right-click › **Exit** to quit.
- Launching the exe again while it's running brings the existing window back. Only one copy runs at a time.

### Settings

| Section | What's in it |
|---|---|
| Appearance | Theme: Midnight (default), Night Watch, Poring, Frost, Mocha, Daylight. Previews live; Cancel reverts. |
| Notifications | ntfy topic/server, Discord webhook, Telegram bot, `@here`, alarm sound on this PC |
| Test your setup | **Test alert**, **Run drill**, **Test heartbeat**, **Capture desktop**. They use the values on screen, even before you press Save. |
| Detection | Check interval, grace checks |
| Wake-up alerts | Repeat interval, maximum repeats, notifications per alert, gap between them |
| Heartbeat | Interval, optional desktop screenshot to Discord |
| App | Open at Windows sign-in, start watching when the app opens |

- **Test alert** sends one alert burst to every channel. It proves delivery works.
- **Run drill** sends the same alerts as a real drop, 5 rounds spaced by `Repeat every`, marked `DRILL`. It proves the alerts wake you up. A drill keeps running after you close Settings and can be stopped from **Stop drill** on the main screen.
- **Test heartbeat** sends a heartbeat now. With the screenshot option on, you can confirm the image reaches Discord.
- **Capture desktop** saves a BMP to the `screenshots` folder and sends nothing.

**Game covers** are not bundled (the art belongs to the publishers). Every game gets a blank placeholder cover. To add your own, right-click a game card (or click the picture icon that appears on the cover) › **Choose cover image** and pick a PNG, JPG or WebP; portrait 3:4 looks best. The app keeps a copy in the `covers` folder next to it. **Remove cover** goes back to the placeholder.

Settings are stored in `config.json` next to the exe, and the log is `gamepulse.log` in the same folder.
`config.json` contains your webhook and tokens. Never share it or attach it when asking for help.
(When you build from this repository, the app uses `config.json` at the repository root instead. That file is gitignored.)

## How it detects a disconnect

While you're in game, `rooc.exe` keeps a TCP connection open to the gate server:

```
43.153.252.23:10011   <- client 1
43.153.252.23:10012   <- client 2
```

When you drop, that socket disappears immediately. Other connections (443 to the CDN, localhost between game threads) stay, the process keeps running and the window title doesn't change.
So **whether that socket exists is the most reliable online signal**, and reading it needs no access to game memory and nothing that could bother anti-cheat.

The app counts sockets that are Established, not localhost and not on port 80/443/8080. No IP or port is hard-coded, so it keeps working if the game moves servers. Each client is identified by PID plus process start time, so a reused PID is never mistaken for the same client.

## When you get alerted

| Event | Meaning | Wakes you? |
|---|---|---|
| No game socket for N checks in a row | Dropped and not back | Yes, repeated every 3 min |
| No `rooc.exe` process | Game closed or crashed | Yes, repeated |
| One client disappears | That client was closed | Yes |
| No internet from this PC | Internet down (remaining sockets can't be trusted) | Yes, repeated |
| Game socket has a new creation time | Dropped and reconnected on its own | No, just shows when you wake up |
| Back online / internet back | All good | No |

**Grace checks** delay the alert so map changes and character switches don't trigger false alarms. The default is 3 checks × 30 seconds, so a real drop must last about 90 seconds before you're woken.

**Repeat** (`Repeat every`) is what actually wakes you: alerts keep firing until the client is back or `Maximum repeats` is reached. That works better than relying on any one app's vibration pattern.

**Heartbeat** (every 4 hours by default) sends "Still watching", so a silent night means everything was fine and not that the monitor died at 2 a.m.
With **Attach a desktop screenshot** on, each heartbeat to Discord includes a WebP image of all monitors. It shows everything on screen, so it's off by default.

Monitoring runs on a background thread separate from the window, so it keeps checking and alerting while hidden in the tray.

## Open automatically at Windows sign-in

Settings › App › tick **Open GamePulse when I sign in to Windows**, then Save.
This writes to `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, so it needs no admin rights and no Task Scheduler.
Upgrading from ROOC Monitor: if you had the old sign-in launch on, GamePulse moves it to itself the first time it opens.
Also tick **Start watching when the app opens**, or the app will open but not watch.
If you move the exe or update into a different folder, untick and tick it again to save the new path.

More important than the app: set Windows **Power & sleep** to **Never**. Otherwise the PC sleeps and the game and monitor stop together, which may be why you were dropping overnight in the first place.

## Updating

1. Right-click the tray icon › **Exit**. Clicking X only hides the window and the exe stays locked.
2. Unzip the new version over the old `.exe` files in the same folder. `config.json` is left alone, so your settings stay.

## Uninstalling

There is no uninstaller. The app only writes to its own folder and one sign-in value in the registry.

1. If **Open GamePulse when I sign in to Windows** is ticked, untick it and Save first. Otherwise Windows keeps trying to open a missing file at every sign-in.
2. Right-click the tray icon › **Exit**.
3. Delete the folder. That removes the exe, `config.json` (your webhook and tokens), `gamepulse.log` and any `screenshots`.

## Why does my phone only buzz once?

A phone vibrates once per notification. How long it vibrates is decided by the OS notification channel, and the sender can't change it, not even with `Priority: urgent`.

The fix is to **send several in a row**, set in Settings › Wake-up alerts:

| Setting | Meaning |
|---|---|
| Notifications per alert (`BurstCount`) | 1 = one buzz, 4 = four buzzes. Default 4. |
| Gap between them (`BurstGapSec`) | Default 4. Under 3 seconds, Android may merge the later ones. |

So each drop sends `BurstCount` notifications, and the whole burst repeats every `Repeat every` minutes until the client is back or `Maximum repeats` is reached.

**With `BurstCount` set to 1 this doesn't work at all.** Settings shows an amber warning when it's 1.

## Which channels support urgent alerts

| Channel | Priority support |
|---|---|
| ntfy | Sends `Priority: urgent` (level 5). **Only has an effect on Android.** |
| Discord webhook | No priority, but real drops include `@here` |
| Telegram bot | Sound on/off only, no urgency level |

Discord only adds `@here` to urgent alerts. Recoveries and heartbeats don't ping.
Turn it off in Settings › Notifications (`"DiscordHere": false` in `config.json`).

### What Discord messages look like

Alerts are embeds, and the color bar tells you the event type at a glance:

| Color | Event |
|---|---|
| 🔴 Red | Disconnected / game closed / internet down |
| 🟢 Green | Back online / internet back |
| 🟡 Yellow | Reconnected on its own / drill |
| 🔵 Blue | Heartbeat and test messages |

Fields show the PID, how long it has been down and which repeat this is. The footer shows the notification's place in the burst (for example `alert 2 of 4`), so you can tell whether the burst finished.

## iPhone setup

iOS has **no notification channels** like Android, so the Android importance advice doesn't apply, and ntfy's `Priority: urgent` has almost no effect on iOS.

iOS vibrates once per notification; you can't lengthen or repeat it within one notification. **`BurstCount` is the only control you have**: raise it for more buzzes.

On the phone:

1. Settings › Notifications › **ntfy**: turn on Allow Notifications and Sounds, set Banner Style to **Persistent**.
2. Settings › Focus › **Sleep** (or whichever Focus runs at night) › Apps: allow **ntfy** and **Discord**.
   This matters most. Without it, Focus silences everything.
3. If ntfy offers **Time Sensitive Notifications**, turn it on.
4. Make sure the Silent switch is off, and turn off Low Power Mode at night.

If it still doesn't wake you, the only guaranteed option on iOS is a **phone call**. ntfy.sh offers calls on a paid plan; decide whether that's worth the monthly cost.

## Android setup

1. ntfy › tap your topic › **Notification settings** › turn on **Dedicated channel**.
2. Open that channel: Importance = **Urgent**, vibration on, pick a loud sound.
3. Settings › Sound & vibration › Do Not Disturb › **Apps**: allow ntfy through DND.
4. Settings › Apps › ntfy › Battery › **Unrestricted**, or Android delays notifications at night.

Steps 3 and 4 matter most. Without them you won't wake up.

## Command line

`gamepulse-cli.exe` (in the same zip) is separate from the GUI. It checks once or tests screen capture; it never watches or sends alerts:

```powershell
.\gamepulse-cli.exe --once      # JSON snapshot; exit 0 all online, 1 some dropped, 2 no supported game running, 3 incomplete read
.\gamepulse-cli.exe --capture   # capture the desktop and report metadata without writing a file
.\gamepulse-cli.exe --help
```

Building from source, tests, exit codes and how to publish a release are in [DEVELOPMENT.md](DEVELOPMENT.md).

## Limitations

It can only tell whether **the socket still exists**, not whether your character is still moving.
It can't tell "kicked out" from "stuck at the login screen"; both show as disconnected, which for this purpose is the same thing.

Comparing the API results against `Get-NetTCPConnection` on a real machine, and checking capture in every situation (multiple monitors, lock screen, sleep), isn't finished yet. The open items are listed in [DEVELOPMENT.md](DEVELOPMENT.md#open-gates).

## License

[MIT](LICENSE) © 2026 pawaretdev.

Bundled fonts are licensed under the [SIL Open Font License 1.1](https://openfontlicense.org): [Inter](https://github.com/rsms/inter) ([license](assets/fonts/Inter-OFL.txt)), [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) ([license](assets/fonts/JetBrainsMono-OFL.txt)) and [Fredoka](https://github.com/hafontia/Fredoka-One) ([license](assets/fonts/Fredoka-OFL.txt)). The release zip includes these license files in `fonts/`.

Ragnarok Origin is a trademark of its respective owners; this project is not affiliated with or endorsed by them.
