# Baseline 101 → SE 9.98 (177)

Baseline: tag `101`, commit `f36b022`, app 9.97 (176), firmware 1.28.0. A separate ZIP and verified Git bundle are saved in `SE-code-101-2026-10-01` beside this repository.

## Runtime changes

- Do not publish unchanged PRINT, STATUS and fleet fields. Packets still pass through readiness, switching and alarm handling; SNAP/DONE events are not deduplicated.
- Observe camera connection state in the camera card, and video frames in the CALayer viewport. Keep the existing 0.20-second preview interval and 960-pixel decoding cap.
- Retain only the newest pending camera frame during main-thread congestion. A nil frame still clears the view on stop/reconnect.
- Serialize VideoToolbox output and return connection callbacks to the camera transport queue. Disable implicit layer animations for video frame swaps.
- Cache language replacement ordering and up to 512 translated strings. Cache the finish-time formatter.
- Isolate lifetime-hours bookkeeping in its badge. Preserve its existing per-printer storage and accounting behavior; this is not a new lifetime-hours API from Bambu.
- Render static speed-dial ticks in three paths rather than 31 views, separate from needle/gesture updates. Render the progress ring with native shapes, without a redundant offscreen drawing group.
- Do not construct a hidden, full-screen alarm border during normal operation.

## Interface

Keep the existing order, 430-point maximum content width, 16-point side margins, 230-point progress ring and 2.05 camera aspect ratio. Refine rounded cards, thin borders, restrained shadows, temperature grouping and button press feedback. Fix the camera toggle's light-mode contrast. Do not add a display-brightness control to the waiting room.

## Verification

CI compares English/Vietnamese status rendering with tag 101, compiles the unsigned device IPA, and runs waiting-room/control/timelapse screenshots on two available iPhone Simulators. Simulator fixtures are compiled out of the device build and never contact a real printer.

Printer control payloads, nozzle routing, sensor parsing, capture timing, alarm policy and ESP32 firmware are unchanged. Simulator checks cannot establish real-device frame pacing or verify printer hardware; those still need on-device testing.
