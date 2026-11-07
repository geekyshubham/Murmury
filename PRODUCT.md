# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

Native macOS app (SwiftUI, macOS 14+, built with SwiftPM and the Command Line Tools). Not one of the
web/ios/android/adaptive values: it follows macOS conventions (sidebar window, toolbar, menu-bar extra,
keyboard shortcuts, system permissions).

## Users

Accessibility first, power users second. The primary user needs, or prefers, to use a Mac without a
mouse or keyboard (motor impairments, RSI, hands busy). The secondary user is a tech-savvy person who
wants to teach the Mac their own head gestures and murmured words. Both wear Samsung Galaxy Buds3 Pro.

## Product Purpose

Murmury is a new way to interact with a computer without a mouse or keyboard: head movement from the
earbuds' motion sensors moves the pointer and scrolls, and murmured commands ("click", "right click",
"scroll down") act. Users can also train their own gestures and words on-device. Success: a person
can use their Mac hands-free within minutes of first launch, and it keeps working reliably.

## Positioning

Uses earbuds the user already wears as the input device: no camera watching them, no extra hardware.
The webcam is used once, only to calibrate how the buds sit on this user's head; after that, only the
buds are used. Everything (speech recognition, the motion model) runs on the Mac; nothing leaves it.

## Operating Context

- The user sits at their Mac wearing Galaxy Buds3 Pro, paired in System Settings, usually also
  listening to audio through them.
- The head mouse runs while other apps are in front; it's controlled by voice ("mouse off/on",
  "scroll mode") and a menu-bar item.
- First run requires macOS permissions: Bluetooth, Microphone, Speech Recognition, Accessibility
  (to click and scroll), Camera (one-time calibration).
- Power users record labelled takes, check whether the signal is learnable, train a model, and use
  live detection.

## Capabilities and Constraints

- Buds3 Pro stream head orientation plus raw gyro and accelerometer at ~50 Hz over Samsung's SPP
  protocol (verified on hardware). The bud batches samples unless told not to (`C3 08`), and it
  sends ~1 sample/s when the head is still.
- No head-gesture or "user is speaking" events exist in the bud; gestures come from the user's model.
- Open-vocabulary speech from head motion is not realistic; full speech uses on-device speech
  recognition through a microphone.
- Planned: Samsung Galaxy Watch 6 Classic as a second input device for gesture and pointer control.
  Keep input sources device-agnostic: the pointer, avatar and models consume motion samples, not "buds".
- Undecided: distribution channel (website, GitHub, App Store), pricing, licence, and support for
  other earbuds.

## Brand Commitments

- Name: Murmury.
- The user made CleanMyMac 5 the binding quality and feel reference: rich, polished, animated,
  production-ready, with real icons, and an animated head that mirrors the user's movement live.

## Evidence on Hand

- Real Buds3 Pro SPP trace: `Tests/MurmuryTests/Fixtures/buds3pro-stream.txt`.
- Protocol research: `research/FINDINGS_*.md`.
- No users, testimonials, benchmarks, or accuracy claims exist yet; do not invent them.

## Product Principles

1. Hands-free first: every core action is reachable by head and voice; nothing requires a mouse.
2. Calm and trustworthy: the pointer never surprises; the user always sees what Murmury is doing and
   can stop it instantly.
3. Show, don't tell: live visual feedback (the head, the pointer, what was heard) explains state.
4. Private by design: on-device only, with the camera used once for calibration.
5. Progressive depth: the head mouse works out of the box; training and tuning are there for those
   who want them.

## Accessibility & Inclusion

Primary users may have motor impairments: large targets, full keyboard and VoiceOver support, no
time-pressured interactions, Reduce Motion respected, colour never the only signal.
