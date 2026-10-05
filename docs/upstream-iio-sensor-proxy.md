# Proposal: human-presence (HPD) support in iio-sensor-proxy

*Intended as a comment on hadess/iio-sensor-proxy#425.*

Following up on #425 with data from a second device and a concrete proposal.
I have this working on real hardware outside iio-sensor-proxy and would like to
upstream it properly, so I'd value your view on the API and driver shape below
before writing a merge request.

## Hardware

- ASUS ProArt PX13 (HN7306WU), webcam USB `3277:0059` ("ASUS FHD webcam").
- The webcam's HID sensor hub (USB interface 4) declares two Human Presence
  sensors, `HID-SENSOR-200011.2` and `HID-SENSOR-200011.4`. `hid_sensor_prox`
  exposes both as iio `prox` devices with the channels from the 6.13 kernel series
  ([patch](https://patchwork.kernel.org/project/linux-iio/patch/20241101-hpd-v3-1-e9c80b7c7164@chromium.org/)):

  | Channel | Meaning | Type / scale |
  | --- | --- | --- |
  | `in_proximity0` | human present | `le:s16/32`, 0 or 1 |
  | `in_proximity1` | distance | `le:s16/32`, scale 0.001 (metres) |
  | `in_attention` | facing the screen | `le:s16/32`, 0 or 100 |

- Kernel 7.0, iio-sensor-proxy 3.8 (current main is 3.9 with the same proximity code).

## What happens today

The `in_proximity0_raw` rule tags both devices `iio-poll-proximity`, which then
gives up:

```
Found proximity sensor but no PROXIMITY_NEAR_LEVEL udev property
See https://gitlab.freedesktop.org/hadess/iio-sensor-proxy/blob/master/README.md
```

Setting `PROXIMITY_NEAR_LEVEL` would not help, for two reasons:

1. **These sensors only report while streamed.** A synchronous sysfs read powers
   the sensor on and off again before it has a result; it needs about 6.5 s
   from power-on to its first sample. The same was noted for virtual HID sensors
   in !363. Polling `in_proximity0_raw` every 700 ms therefore never sees data.
   Enabling the buffer and reading `/dev/iio:deviceN` works reliably; the
   device's own trigger (`prox-devN`) is already the `current_trigger`.
2. **The semantics differ from `ProximityNear`.** Phone-style proximity means
   "something is covering the sensor", and clients use it to blank the screen
   during calls. Mapping "a person is sitting in front of the laptop" onto
   `ProximityNear` would make such clients blank laptop screens whenever someone
   sits down. !405's approach (near when `in_proximity1` is below a level) has the
   same problem, and also still polls.

## Proposed D-Bus API

New properties and methods on `net.hadess.SensorProxy`, following the existing
Claim/Release pattern:

| Name | Type | Meaning |
| --- | --- | --- |
| `HasHumanPresence` | b | A human-presence sensor is available |
| `HumanPresent` | b | Someone is in front of the device |
| `HumanDistance` | d | Distance to that person in metres; -1 when unknown or nobody present |
| `HasHumanAttention` | b | The sensor reports attention (not all HPD sensors do) |
| `HumanAttention` | b | The person is facing the screen |
| `ClaimHumanPresence()` / `ReleaseHumanPresence()` | | Start/stop streaming for this client |

Streaming only while at least one client holds a claim matters for power: when the
buffer is disabled the webcam's USB link runtime-suspends. A desktop would release
the claim while the session is locked (unless it wants wake-on-approach). Measured
on the PX13 at 2 Hz: about 0.3 W or less while streaming, nothing when released.

## Proposed driver

A buffered driver, `iio-buffer-human-presence`, built on the iio-buffer-utils
helpers (much like !363, but for the HPD channels):

- **Matching:** HID Human Presence sensors by their parent
  (`KERNELS=="HID-SENSOR-200011.*"`) with `scan_elements/in_proximity0_en`, taking
  precedence over `iio-poll-proximity` for those devices.
- **Streaming:** enable `in_proximity0`, plus `in_proximity1` and `in_attention`
  when present; set a low report rate (the `*_sampling_frequency` attributes are
  shared; 2 Hz is plenty); read the buffer while claimed.
- **No policy in the proxy:** report values as they come. The raw attention value
  does flicker for single samples; my prototype requires two consecutive samples
  before acting, but that seems like a client decision.

## Open questions

1. **Two sensors, one silent.** On this webcam only `HID-SENSOR-200011.4` ever
   reports; `.2` stays silent while streamed. Would you rather the driver open
   every candidate and keep the first that delivers samples, or mark the silent
   one with a hwdb/udev property (keyed on the USB ID) so it is never opened? My
   prototype probes each candidate for 15 s, highest instance first.
2. **API naming.** Are separate `HumanPresence` properties acceptable, or would you
   prefer a new interface or object path (like `Compass`)?
3. **Distance unit.** Metres as a double (from the channel scale), or millimetres?
4. **Start-up delay.** If I read !382 right, a claim returns after the first measurement; here
   that is about 6.5 s. Is that acceptable, or should the claim return at once
   with `HumanPresent=false` until data arrives?

## Offer

I have a working prototype on this laptop: a small streaming service plus a KDE
Plasma agent that implements lock-on-leave, adaptive dimming and "keep the screen on
while looking". I'm happy to write the merge request (driver, D-Bus API,
`monitor-sensor` support and a test with recorded scan data) once the direction is
agreed, and to test on this hardware.
