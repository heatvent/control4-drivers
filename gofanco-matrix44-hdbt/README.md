<img src="icon.png" width="96" align="right" alt="Driver icon">

# GoFanco Matrix44-HDBT — Control4 DriverWorks driver

A full-control Control4 driver for the **gofanco Matrix44-HDBT** 4x4 HDMI 2.0 HDBaseT matrix kit (part G4-0064B), over RS-232.

It works as a normal Control4 AV switch, so rooms route sources through the matrix automatically. It also exposes every command in the matrix's RS-232 table as Composer actions: status, presets, EDID, HDCP, PoC, IR, CEC and more.

> **Unofficial.** gofanco and Snap One/Control4 did not make this driver and don't support it. Use at your own risk.

**[Download gofanco_matrix44_hdbt.c4z](gofanco_matrix44_hdbt.c4z)**

## Tested on

| | |
|---|---|
| Matrix | gofanco Matrix44-HDBT, firmware V1.0.1, CPLD V1.0.0 |
| Control | RS-232 at 9600 8N1, from a Control4 EA-series controller serial port |
| Control4 OS / Composer Pro | 3.4.3 |
| Not tested | The matrix's TCP/IP (network) port |

**Check your model's command set.** This driver uses the G4-0064B command set, where routing commands look like `OUT03:01.` and status uses `STA.`. Some other gofanco matrices use a different set (`1V3.`, `Status.`, `%9964.`), and this driver won't work with them. If sending `/*Type.` over serial returns `HDMI 2.0 4x4 Matrix Switcher`, you have the right model.

## Features

- **AV switch proxy** with 4 HDMI inputs and 4 outputs. It sets up like any other Control4 matrix.
- **Routing feedback.** The driver reads the matrix's actual routing (`STA_VIDEO.`) at startup and on a poll timer (1, 5 or 15 minutes, or off). Changes made with the front panel or IR remote reach Control4 too.
- **Room power.** The matrix powers on when any room starts using it. It powers off only after the last room turns off, so rooms that share a source stay on. You can also set it to stay on all the time.
- **Command queue.** Power and routing go ahead of status queries, so `PowerON.` always reaches the matrix before a route.
- **Status properties:** output sources, power, front-panel lock, IR follows video, board temperature, IP address, model and firmware, plus a one-click full diagnostics run.
- **Actions** for the whole RS-232 table:
  - Routing: single route, or one input to all outputs
  - Presets 1–9: save, recall and show contents
  - Power on/off, front-panel lock/unlock
  - HDCP per output: follow display, bypass, force 1.4, off
  - HDMI 5V (outputs 4 and 5) and power to the HDBaseT receivers (outputs 1–3)
  - IR: follows video, IR routing, whether a receiver's IR controls the matrix
  - De-embedded audio output source
  - EDID: built-in 01–09, copy from a display, read a display's EDID, restore default, status
  - CEC: source power, menu and navigation; display power, volume and mute
  - Query or set the matrix IP address
  - Raw command
  - Factory reset (`RST.`), which only runs after you confirm it in a property
- **Programming commands:** Route Input To Output, Route Input To All Outputs, Recall Preset, Power On, Power Off, Refresh Status, Send Raw Command.

Some commands deliberately have no button: `Baudrate` (changing it cuts off the controller), `EDIDUpgrade` (it needs a .bin file upload) and `/+` pass-through. Send them with **Send Raw Command** if you need them.

## Installation

1. Connect the matrix's RS-232 port (3-pin Phoenix connector) to a controller serial port with the included Phoenix-to-DB9 cable.
2. In Composer Pro: **Driver → Add or Update Driver**, then choose `gofanco_matrix44_hdbt.c4z`.
3. Add **GoFanco Matrix44-HDBT (DriverWorks)** to a room, such as your equipment rack.
4. **Connections → Control/AV:**
   - Bind **Serial RS-232** to the controller serial port.
   - Bind **Input 1–4** to your sources' HDMI outputs.
   - Bind **Output 1–4** to your displays or receivers.
5. Refresh Navigators. About 5 seconds after the driver loads, **Connection Status** should show **Online** and **Output 1–4 Source** should fill in.

### Port notes

- Outputs 1–3 are HDBaseT (CAT) outputs with receivers. Output 4 is the local HDMI output.
- Some commands refer to **output 5**, which is the HDMI loop-out of output 3.

### Replacing a Composer Driver Builder (.c4i) driver

This driver uses the standard AV switch connection IDs (serial 1, proxy 5001, inputs 1000–1003, outputs 2000–2003) and the same `OUTxx:yy.` routing command. To replace a Driver Builder driver for this matrix:

1. Back up your project.
2. Add this driver.
3. Move each serial and HDMI binding from the old driver to this one.
4. Test each room, then delete the old driver.

## Properties used by actions

| Property | Used by |
|---|---|
| Route Input / Route Output | Apply Route, Route Input To All Outputs |
| Preset Number | Save / Recall / Show Preset |
| Output Selection | HDCP, HDMI 5V, PoC, EDID copy source, Read Display EDID, CEC display, IR route (local IR out) |
| Input Selection | EDID built-in / copy target / status, CEC source |
| Receiver Selection | IR route (receiver IR in), Receiver IR Controls Matrix |
| Built-in EDID Number | EDID: Set Built-in |
| Audio Out Source | Set Audio Out Source |
| New IP Address | Set Matrix IP Address |
| CEC Source / Display Device Type | CEC actions (defaults 04 and 40; TVs may use 40, 20 or 80) |
| Raw Command | Send Raw Command (a trailing `.` is added if missing) |
| Confirm Factory Reset | Factory Reset runs only when this is set to "Yes, reset the matrix" |

## Backing up settings before a factory reset

The matrix has no settings export. Before running `RST.`:

1. Run **Run Diagnostics**. With **Debug Mode** on, the full output also appears in the Lua tab.
2. Save that output, and run **Show Preset Contents** for each preset you use.

A reset puts the EDID (built-in 06), receiver power (all on), routing and presets back to factory settings. Restore them afterward with the matching actions. For example:

- `EDIDMxxByy.` copies output xx's EDID to input yy. The display on that output must be on.
- `PCATxx:OFF.` turns off power to receiver xx.

If an input used an EDID file you uploaded yourself, you'll need the original .bin file.

## Troubleshooting

- **Connection Status shows "No reply from matrix":** check the serial binding and cable, and that the matrix is at 9600 baud. Turn on **Debug Mode** to see every command and reply in the Lua tab.
- **The network port doesn't answer:** the driver doesn't need it. **Set Matrix IP Address** only sets the IP; the subnet mask, gateway and DHCP setting can only be changed in the matrix's web page.

## Files

| File | |
|---|---|
| `gofanco_matrix44_hdbt.c4z` | The driver. Install this one. |
| `src/` | Driver source (`driver.xml`, `driver.lua`, icons). |
| `CHANGELOG.md` | Version history. |

## License

MIT. See [LICENSE](../LICENSE). Written by **Heatvent (with Claude)**.
