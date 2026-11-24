# Changelog

## 3.2.1 — 2026-11-23
- `STA.` and `/^Version.` now wait up to 2 s of silence before their reply is treated as complete. `STA.` pauses about 1.2 s after its header line, so its reply was being split across the next commands (seen in Run Diagnostics as an empty `STA.` reply and shifted results).

## 3.2.0 — 2026-11-23
- Network control: new **Connection Type** property (Serial (RS-232) / Network (TCP/IP)) with **IP Address** and **Network Port** (default 23). One driver covers both. On the network, the driver opens the connection itself, holds commands while offline, reconnects every 15 s, and reads status once it's online.
- Routing changes pushed by the matrix (including ones made by other network clients) update Control4.
- Connection Status shows which link is in use and whether it is online.
- Serial behaviour is unchanged.

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
