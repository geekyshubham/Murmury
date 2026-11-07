# Galaxy Buds3 Pro (SM-R630): sensor data paths over SPP

Source: jadx output of `com.samsung.accessory.paranmgr` 8.5 (8.5.26070351), root `research/decompiled/paranmgr/sources/`.
GalaxyBudsClient = "GBC". **[OBS]** read in code · **[INF]** inference · **[UNK]** must be measured on hardware.
Signed bytes: `-62` = `0xC2`.

## 0. Transport (verified)
| Item | Value | Evidence |
|---|---|---|
| RFCOMM UUID | `2e73a4ad-332d-41fc-90e2-16bef06523f2` | `p043d8/H.java:48-49` |
| Frame | `FD lenLo lenHi|flags id payload crcLo crcHi DD`, len = (payload+3) & 0x3FF | encoder `p064f8/C0558a.java:772-800`, rx `p043d8/G.java:43,89` |
| Flags | 0x20 = hdr bit13 (fragment), 0x10 = hdr bit12 (response style) | `C0558a.java:781-786` |
| CRC | CRC-16/XMODEM over id+payload, LE | `p189q7/d.java:30,95-101` |
| Unknown ids | `createMsg()` returns null → dropped | `C0558a.java:728-738` |

0xC2/0xC3 are consumed only by `Fa.g.i` (Samsung "ShtCoreImpl", head-tracking core v2.2.04) via `SpatialSensorManagerImpl` (`p043d8/C.java:73-97`).

## 1. 0xC2 SPATIAL_AUDIO_DATA sub-events (`Fa/g.java:262-489`)
| Sub | Name | Layout (d = payload[1..]) | Evidence |
|---|---|---|---|
| 0x20 | GRV | **3 formats by len(d)** — see 1a | `Fa/g.java:290-360` |
| 0x21 | WearOn | `[x]` ignored | `:361-368` |
| 0x22 | WearOff | `[x]` | `:369-378` |
| 0x23 | Gyro bias | 3×int16 xyz, u8, int16, [len≥10: side] | `:379-410` |
| 0x24 | Sensor stuck | u8 | `:411-413` |
| 0x25 | Sensor supported | `[1]` = supported | `:414-422` |
| 0x26-0x29 | manual gyro-cal | dormant on SM-R630 (model flag false, `La/e.java:7`) | `:423-484` |

### 1a. GRV formats
- **(A) len 9**: 4×int16/10000 quaternion + u8 flag (`:350-358`). Only format GBC implements.
- **(B) len 37 (NEW)**: quaternion (8) · vecA 3×int32/2^26 · vecB 3×int32/2^25 · int32 "audio throughput" · u8 flag (`:294-332`).
  vecB feeds `Pedometer.DetectStep` (`La/o.java:73-79,150-172`) → **accelerometer** [INF, strong]; vecA unused in plugin → probably gyroscope [INF].
- **(C) batched (NEW)**: `N`, then N×(4×int16), then flag (`:333-349`).
- **Order is w,x,y,z (scalar first)** [OBS-derived]: phone GRV is reordered to (w,x,y,z) before the same native update (`La/i.java:27-31`), quat→matrix uses [0] as w (`nd/l.java:3240-3246`). GBC's x,y,z,w looks wrong.
- **Flag = which bud produced the sample** (role switch → different head→bud mounting quaternion, `RelativeQuat.java:121-128`). Buds3 Pro mounting quats: `{0.785,-0.12,-0.463,-0.393}`, `{0.64,0.355,0.116,-0.671}` (`La/e.java:7`).
- No timestamp/sequence field; plugin stamps on arrival and logs counts every 5 s (`i3/f.java:349-366`). Rate [UNK], ≥50 Hz bursty hinted [INF].
- Which conditions produce (B)/(C) [UNK]; hypothesis: SPATIAL_BUF_ON/OFF (`C3 07/08`).

### 1b. Where pose data goes
`libRelativeQuat.so` combines bud quaternion with the phone's own GRV; relative yaw/pitch/roll (×128) is pushed every 10 ms via `AudioManager.setParameters("g_effect_headtracking_fx;position=…")` (`A8/i.java:916-967`). No HAL, AIDL or broadcast.

## 2. Attach / detach (`ha/a.java:127-275`, `Fa/g.java`, `Fa/d.java`)
| ctrl | Name | Sender |
|---|---|---|
| 0x00 | ADD (attach) | start HT `Fa/g.java:569` |
| 0x01 | REMOVE | stop HT `Fa/g.java:498` |
| 0x04 | ALIVE | every 2000 ms `Fa/d.java:34-50` |
| 0x05 | REQUEST_WEAR | every 4000 ms until wear known `Fa/d.java:22-31` |
| 0x06 | QUERY_SENSOR_SUPPORTED | on SPP connect `A8/l.java:172-180` |
| 0x07/0x08 | SPATIAL_BUF_ON/OFF | step-context (walking) `i3/f.java:378-404` |
| 0x0D | RESET_GYRO_IN_USE_BIAS | `Fa/g.java:229-233` |
| 0x42 | DEBUG_PRINT_TIMESTAMP | latency test |
Replies: `C3 [02]` add ack, `C3 [03]` remove ack.
Refresh: no GRV for >2000 ms → REMOVE then ADD (`Fa/d.java:39-49`).
Phone-side run conditions: spatial on, SPP connected, media playing, bud worn, A2DP routed to buds, HT switch on (`Fa/g.java:537-634`) — whether the **bud** needs A2DP is [UNK].
`0x7C SET_SPATIAL_AUDIO` = `[spatial, headTracking]` (2 bytes on Buds3 Pro, `p042d7/b.java:544-562`), sent only on user toggle — not part of attach.

Recommended macOS sequence [INF]: `7C [01 01]` (optional) → `C3 06` (expect `C2 25 01`) → `C3 05` (expect `C2 21/22`) → `C3 00` (expect `C3 02`, then `C2 20…`) → `C3 04` every 2 s, refresh after 2 s silence → `C3 01` on stop.

## 3. Neck posture (0xC6-0xC9)
- `0xC9 [enable]` feature on/off; `0xC7` control: `[00]` disable, `[01 f32 r,p,y (deg×100)]` enable+calibration, `[04 01]/[04 00]` **start/stop raw accel stream**, `[05 f32]` result, `[09]/[0A]` acks, `[0B]` on connect (`Fc/d.java:98-176`).
- `0xC6` bud→phone: records `[L, type, subtype, seq, int16…]`, nRecords = len/L (`i3/e.java:283-396`).
  type 12/sub 14 = **accelerometer xyz int16/1000**, 900 samples per 18 s calibration ⇒ ≈50 Hz [INF]. type 10 = posture context event (ack `[09]`/`[0A]`).

## 4. Head gestures
Not in this plugin (no feature flag, message, or code). Classify from GRV on the Mac.

## 5. Raw / debug paths
| Path | Msg | Notes |
|---|---|---|
| Extended GRV | C2 sub 0x20 len 37 | quat + vecA + vecB(accel) — production |
| DEBUG_GET_ALL_DATA | 0x26 (empty req; sent on every connect) | one-shot snapshot: Acc L @35-39 R @41-45, Prox, Therm, **Gyro L @101-105 R @107-111, VPU L @113-117 R @119-123** (int16 LE) `p064f8/C0566i.java:37-144` — only place raw gyro/VPU appear; max poll rate [UNK] |
| Neck-cal accel | C6 type12/sub14 via `C7 [04 01]` | ≈50 Hz [INF] |
| Noise monitor | tx 0x49, rx 0x4D (wearState, ncMode, dB int32) | `C0558a.java:378-408` |
| Self-diagnostics | 0xEA, subId 13 = pinch sensor | `p064f8/T.java` |
| ACC_SENSOR_LOGGING 0x2A, hidden AT cmds | not in plugin (GBC only) | — |
| HRM | dead code; no evidence of an HRM on Buds3 Pro | `VerificationHealthActivity.java` |

## 6. Sensor/wear/touch/voice message ids
0x26 debug snapshot · 0x4D noise monitor · 0x60 status (placement hi=L lo=R) · 0x61 extended status · 0x77 noise-controls update (Voice Detect's only visible effect) · 0x7A detect conversations · 0x7C spatial audio · 0x91 touch lock · 0x93 touch-and-hold side · 0x9A voice wake-up event · 0x9E fit test · 0xC2/0xC3 spatial · 0xC6-0xC9 neck posture · 0xDE siren detect · 0xEA self-diagnostics.
**No "user is speaking" event exists**; Voice Detect runs on-bud and only shows up as a 0x77 mode change.

## 7. watchmanager
Host/launcher only (device→plugin map `b7/l.java:105`, UUID list). No protocol code.

## 8. Unknowns for hardware
GRV rate per format; what triggers formats B/C; units/identity of vecA/vecB; whether GRV needs A2DP; `C7 [04 01]` outside calibration; 0x26 poll rate + gyro/VPU units; 0x49 payload; 0x2A / `990A` on R630 firmware.
