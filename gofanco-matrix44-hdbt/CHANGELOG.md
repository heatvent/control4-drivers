# Changelog

## 3.1.0 — 2026-11-22
- First public release.
- Added a driver icon.
- Rewrote the documentation for general use and added tested-on details.

## 3.0.1
- HDMI inputs and outputs are now attached to the AV switch proxy (`proxybindingid="5001"`), so they show in Composer Connections.

## 3.0.0
- Rebuilt on the G4-0064B command set (`OUTxx:yy.`, `PowerON.`, `STA_VIDEO.` …).
- Added actions for the full RS-232 table: presets, HDCP, HDMI 5V, PoC, IR, audio, EDID, CEC, IP, and a guarded factory reset.
- Room on/off powers the matrix on and off, with power commands queued ahead of routing.
- Routing feedback from `STA_VIDEO.` at startup, on a poll timer, and from front-panel changes.
