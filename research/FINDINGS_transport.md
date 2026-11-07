# Galaxy Buds3 Pro — transport & head-tracking spec (from GalaxyBudsClient @754b6fd)

[verified] = checked by computation; [inference] = reasoning, not stated in source.

| Item | Value |
|---|---|
| RFCOMM UUID | `2e73a4ad-332d-41fc-90e2-16bef06523f2` (Uuids.SppNew; Buds3ProDeviceSpec.cs:54) |
| Channel | runtime: performSDPQuery (no UUIDs — UUID-filtered query silently fails since Ventura) → getServiceRecordForUUID → getRFCOMMChannelID (Platform.OSX/Native/src/Bluetooth.mm:44-151) |
| macOS quirk | openRFCOMMChannelSync returns kIOReturnError even on success → poll isOpen ≤1.5 s; serialize writes, chunk to getMTU |
| Frame | `FD | hdr u16 LE | id | payload | crc u16 LE | DD`; `len = hdr & 0x3FF = 1 + n + 2`; frame = len + 4; 0x1000 type bit, 0x2000 fragment bit (send 0) |
| CRC | CRC-16/XMODEM (poly 0x1021, init 0, no reflect/xorout) over `id‖payload`, little-endian. Verified on Buds2Pro ESU test frame (0x37B6) [verified] |
| Handshake | none required; buds push EXTENDED_STATUS_UPDATED 0x61, client replies MANAGER_INFO 0x88 `[01 01 22]` |
| Start | `7C[01]` (SET_SPATIAL_AUDIO on), `C3[00]` (attach) → expect `C3[02]` AttachSuccess; `C3[04]` keepalive every 2 s |
| Stop | `C3[01]`, `7C[previous]` |
| Data | `C2 [0x20, 4×int16 LE /10000, flag]` — GRV quaternion; repo assumes order x,y,z,w (identity frame has 10000 last) [validate on device] |
| Rate | not documented; no timestamp/sequence in GRV packets — measure |

## Precomputed frames
```
7C[01] FD 04 00 7C 01 15 5D DD      C3[00] FD 04 00 C3 00 07 43 DD
C3[04] FD 04 00 C3 04 83 03 DD      C3[01] FD 04 00 C3 01 26 53 DD
7C[00] FD 04 00 7C 00 34 4D DD      C3[06] FD 04 00 C3 06 C1 23 DD
88[01 01 22] FD 06 00 88 01 01 22 DA 58 DD
26[]   FD 03 00 26 A4 44 DD
rx AttachSuccess FD 04 00 C3 02 45 63 DD
rx GRV identity  FD 0D 00 C2 20 00 00 00 00 00 00 10 27 00 D3 88 DD
```

## Spatial enums (Model/Constants.cs:111-145)
Control: Attach 0, Detach 1, AttachSuccess 2, DetachSuccess 3, KeepAlive 4, WearOnOff 5, QuerySensorSupported 6, SpatialBufOn 7, SpatialBufOff 8, QueryGyroBiasExistence 9, ManualGyrocalStart 10, Cancel 11, QueryReady 12, ResetGyroInUseBias 13, debug 64-66.
Data: BudGrv 32, WearOn 33, WearOff 34, BudGyrocal 35 (3×int16 [+u8+u16]), BudSensorStuck 36, SensorSupported 37, GyroBiasExistence 38, ManualGyrocalReady 39, NotReady 40, GyrocalFail 41.

## Other signals
- STATUS_UPDATED 0x60: [1] battL [2] battR [5] placement (hi nibble L, lo R: 0 disc, 1 wearing, 2 idle, 3 case, 4 closed case) [6] case batt.
- NOISE_CONTROLS_UPDATE 0x77: [0] mode 0 off/1 ANC/2 ambient/3 adaptive.
- Voice wake-up event 0x9A [result, confidence]. Detect-conversations setting 0x7A/0x7B — no "detected" event exposed (proxy: auto switch to ambient) [inference].
- DEBUG_GET_ALL_DATA 0x26 (poll, empty request): accel L XYZ int16 @35-40, R @41-46 (Buds3+ offsets, untested on Buds3 Pro) — one-shot snapshot, not a stream.
- Hidden AT cmds: 0x12 [mode] then 0x13 ASCII-hex id (e.g. "F012"); factory sensor cmds incl. VPU 0xB4-0xBA, SL_200Hz_DATA_ON 0x990A — unverified, debug only, exiting hidden mode forces reconnect.
- ACC_SENSOR_LOGGING 0x2A: enum only, format unknown.
