# asus-presence

Adaptive Lock and Adaptive Dimming on Linux for laptops whose webcam has a
built-in human-presence sensor, such as the ASUS "AI camera" (USB `3277:0059`).

- **Lock on leave:** locks the session after you have been away for a while (default 60 s).
- **Adaptive dimming:** dims the built-in screen when you look away (default 10 s) and
  restores it when you look back.
- **Keep the screen on while you look at it:** no idle dimming, blanking, locking or
  sleep while you are reading without touching anything. A separate option blocks
  sleep only.
- **Wake on return** (optional) while the session is locked.

It reads the webcam's own presence engine, not the camera feed: no image reaches
Linux and the camera LED stays off.

## Requirements

- A webcam whose HID presence sensor shows up as an iio `prox` device with an
  attention channel. Check with:

  ```sh
  grep -l prox /sys/bus/iio/devices/iio:device*/name | while read f; do
    d=$(dirname "$f"); ls "$d/scan_elements" | grep -q attention && echo "found: $d"; done
  ```

- Linux 6.13 or newer (`hid_sensor_prox` with the attention channel).
- Python 3.8+ with `python3-dbus`, and `gdbus` (GLib).
- KDE Plasma 6 for the lock/dim agent. The sensor service itself works on any desktop.

Tested on: ASUS ProArt PX13 (HN7306WU), Linux 7.0, Plasma 6.6.

## Install

```sh
git clone https://github.com/madhan001/asus-presence.git
cd asus-presence
./install.sh
```

Then log out and back in once: the installer adds you to the `asus-presence`
group, which may read the sensor state. Open **Presence Sensor** from the
launcher to watch it live and change settings.

Remove with `./uninstall.sh` (add `--purge` to delete your settings too).

## How it works

```
webcam presence engine --USB HID--> hid_sensor_prox (iio)
  --> asus-presence-sensord   (system service, root without capabilities)
        /run/asus-presence/state.json     (root:asus-presence 0640)
  --> asus-presence-agent     (your session: lock, dim, inhibit, wake)
        ~/.config/asus-presence/presence.conf
```

- `asus-presence-sensord` streams the sensor through the iio buffer at 2 Hz. The
  sensor only reports while streamed; a one-shot sysfs read powers it off again
  before it has a result. Some webcams expose two presence sensors of which only
  one reports, so each candidate is probed for up to 15 s and the working one kept.
  Presence and attention must hold for two samples (1 s) before they change.
- `asus-presence-agent` locks through `org.freedesktop.ScreenSaver`, dims through
  Plasma's `org.kde.ScreenBrightness`, and keeps the screen on with screen-saver
  and power-management inhibitions (shown as "ASUS Presence" in the battery
  applet). While the session is locked it puts the sensor in standby so the
  webcam's USB link can suspend.

Both are event-driven: no polling, and the state file is rewritten only when
something changes.

**Power:** about 0.3 W or less while streaming (measured on the PX13), nothing
while locked.

## Settings

`~/.config/asus-presence/presence.conf` (applied live; see
`presence.conf.example`), or the Presence Sensor window, or:

```sh
asus-presence-ctl set lock_after 120
asus-presence-ctl get        # sensor + agent state as JSON
```

| Key | Default | Meaning |
| --- | --- | --- |
| `enabled` | `true` | Master switch for the agent |
| `lock`, `lock_after` | `true`, `60` | Lock after this many seconds away (10 to 3600) |
| `dim`, `dim_after`, `dim_level` | `true`, `10`, `30` | Dim to `dim_level` % after looking away this many seconds |
| `keep_screen_on` | `true` | No idle dim, blank, lock or sleep while you look at the screen |
| `prevent_sleep` | `true` | No idle sleep while you look at the screen |
| `wake_on_return` | `false` | Keep the sensor on while locked and wake the screen when you return |

## Troubleshooting

- `journalctl -u asus-presence` shows which sensor is streamed and its USB ID.
- `journalctl --user -u asus-presence-agent` shows each action (lock, dim, ...).
- "cannot read /run/asus-presence": log out and back in after installing.
- To force a specific sensor: `sudo systemctl edit asus-presence` and add
  `Environment=ASUS_PRESENCE_IIO=iio:device1` under `[Service]`.

## Known limitations

- The agent targets KDE Plasma 6; GNOME and others need their own backends.
- One desktop user at a time controls the sensor's standby mode.
- "Attention" is decided by the sensor firmware (most likely head orientation);
  its threshold cannot be tuned.

## Development

```sh
python3 -m unittest discover -s tests -v
```
