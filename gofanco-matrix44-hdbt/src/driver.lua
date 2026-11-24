--[[
  GoFanco Matrix44-HDBT (DriverWorks)
  AV switch driver for the gofanco Matrix44-HDBT (G4-0064B) over RS-232 (9600 8N1)
  or over the network (the matrix's LAN port, raw TCP port 23), using the
  G4-0064B command set (OUTxx:yy., PowerON., STA_VIDEO. ...).
  Standard AV switch connection IDs (serial 1, proxy 5001, inputs 1000-1003, outputs 2000-2003).
  The network connection is created at runtime on binding 6001 from the IP Address property.

  Author: Heatvent (with Claude)
  License: MIT (see LICENSE)
  Unofficial - not made or supported by gofanco or Snap One/Control4.
  The gofanco name and logo are trademarks of gofanco, used only to identify the device.
]]

DRIVER_VERSION   = "3.2.2"
SERIAL_BINDING   = 1
NETWORK_BINDING  = 6001
PROXY_BINDING    = 5001
NUM_PORTS        = 4

SETTLE_MS        = 400    -- reply is complete after this much silence
SLOW_SETTLE_MS   = 2000   -- STA. pauses ~1.2 s after its header line
SLOW_COMMANDS    = { ["STA."] = true, ["/^Version."] = true }
NO_REPLY_MS      = 2000   -- move on if the matrix says nothing
STARTUP_DELAY_MS = 5000
RECONNECT_MS     = 15000  -- retry a dropped network connection this often
MAX_QUEUE        = 40     -- while offline, drop status queries beyond this
RESET_CONFIRM    = "Yes, reset the matrix"

gQueue      = {}          -- pending commands: { cmd=, onReply=fn(raw, text) }
gCurrent    = nil
gRx         = ""
gSettleTimer, gNoReplyTimer, gPollTimer = nil, nil, nil
gRoutes     = {}          -- gRoutes[output] = input
gLastRoute  = { key = "", time = 0 }

gNet = { address = nil, port = nil, online = false, timer = nil }

------------------------------------------------------------------ helpers

local function dbg(msg)
  if Properties["Debug Mode"] == "On" then print("[GoFanco] " .. tostring(msg)) end
end

local function cancel(t) if t ~= nil then t:Cancel() end return nil end

local function clean(raw)
  local s = raw or ""
  s = s:gsub("[\r\n]+", " | ")
  s = s:gsub("%c", "")
  s = s:gsub("^[%s|]+", "")
  s = s:gsub("[%s|]+$", "")
  return s
end

local function setProp(name, value) C4:UpdateProperty(name, tostring(value)) end
local function note(text) setProp("Last Response", text) end
local function two(n) return string.format("%02d", tonumber(n) or 0) end

local function portNum(bindingOrNum)
  local n = tonumber(bindingOrNum)
  if n == nil then return nil end
  if n >= 1000 then n = (n % 1000) + 1 end      -- 1000-1003 / 2000-2003 / 3000+ / 4000+
  if n < 1 or n > NUM_PORTS then return nil end
  return n
end

-- "All" -> 0, "3 (HDBaseT)" -> 3
local function selNum(prop)
  local v = Properties[prop] or "All"
  if v:sub(1, 3) == "All" then return 0 end
  return tonumber(v:match("^(%d+)")) or 0
end

------------------------------------------------------------------ feedback parsing

local function routeLabel(input)
  if input == nil or input == 0 then return "Off" end
  return "Input " .. input
end

local function setRoute(output, input, notify)
  if output == nil or output < 1 or output > NUM_PORTS then return end
  local changed = gRoutes[output] ~= input
  gRoutes[output] = input
  setProp("Output " .. output .. " Source", routeLabel(input))
  if changed and notify ~= false and input ~= nil and input > 0 then
    C4:SendToProxy(PROXY_BINDING, "INPUT_OUTPUT_CHANGED",
      { INPUT = 1000 + input - 1, OUTPUT = 2000 + output - 1 })
    dbg("Proxy notified: input " .. input .. " -> output " .. output)
  end
end

-- Runs on every reply, including unsolicited ones from the front panel / IR remote.
local function parseFeedback(raw)
  -- "Output 01 Switch To In 02!"  (OUT, STA_VIDEO, PresetRecall)
  for output, input in raw:gmatch("Output%s*(%d+)%s*Switch%s*To%s*In%s*(%d+)") do
    setRoute(tonumber(output), tonumber(input))
  end
  for line in raw:gmatch("[^\r\n]+") do
    if line:match("^%s*Power ON") then setProp("Power Status", "On")
    elseif line:match("^%s*Power OFF") then setProp("Power Status", "Off") end
  end
  if raw:find("Front Panel Locked") then setProp("Front Panel", "Locked")
  elseif raw:find("Front Panel UnLock") or raw:find("Front Panel Unlock") then setProp("Front Panel", "Unlocked") end
  if raw:find("IR Follow Video ON") then setProp("IR Follows Video", "On")
  elseif raw:find("IR Follow Video OFF") then setProp("IR Follows Video", "Off") end
  local temp = raw:match("Temperature is%s*(%d+)")
  if temp then setProp("Board Temperature", temp .. " C") end
  local ip = raw:match("GUI_IP:%s*(%d+%.%d+%.%d+%.%d+)") or raw:match("SetGuiIP:%s*(%d+%.%d+%.%d+%.%d+)")
  if ip then setProp("Matrix IP Address", ip) end
end

------------------------------------------------------------------ transport (serial or network)

local SendNext            -- defined with the command queue below

function UsingNetwork()
  return (Properties["Connection Type"] or ""):find("Network") ~= nil
end

-- Serial is always "ready" (Control4 owns the port); network waits for ONLINE.
local function transportReady()
  return not UsingNetwork() or gNet.online
end

local function transmit(data)
  if UsingNetwork() then
    C4:SendToNetwork(NETWORK_BINDING, gNet.port, data)
  else
    C4:SendToSerial(SERIAL_BINDING, data)
  end
end

local function netTarget()
  local ip = (Properties["IP Address"] or ""):match("^%s*(%S+)%s*$")
  local port = tonumber(Properties["Network Port"] or "") or 23
  return ip, port
end

local function netStopTimer() gNet.timer = cancel(gNet.timer) end

local function netDisconnect()
  netStopTimer()
  if gNet.address ~= nil then
    C4:NetDisconnect(NETWORK_BINDING, gNet.port)
    dbg("Network disconnected from " .. gNet.address .. ":" .. gNet.port)
  end
  gNet.address, gNet.port, gNet.online = nil, nil, false
end

local function netRetryLater()
  netStopTimer()
  gNet.timer = C4:SetTimer(RECONNECT_MS, function()
    gNet.timer = nil
    if UsingNetwork() and not gNet.online and gNet.address ~= nil then
      dbg("Network reconnect attempt")
      C4:NetConnect(NETWORK_BINDING, gNet.port)
      netRetryLater()
    end
  end)
end

-- (Re)open the link to match the Connection Type / IP Address / Network Port properties.
function ApplyConnection()
  if not UsingNetwork() then
    netDisconnect()
    setProp("Connection Status", "Serial (bind Serial RS-232 in Composer)")
    SendNext()
    return
  end
  local ip, port = netTarget()
  if ip == nil or ip == "" then
    netDisconnect()
    setProp("Connection Status", "Network: set the IP Address property")
    return
  end
  if gNet.address == ip and gNet.port == port then return end
  netDisconnect()
  gNet.address, gNet.port = ip, port
  setProp("Connection Status", "Connecting to " .. ip .. ":" .. port)
  C4:CreateNetworkConnection(NETWORK_BINDING, ip)
  C4:NetPortOptions(NETWORK_BINDING, port, "TCP", {
    AUTO_CONNECT = true, MONITOR_CONNECTION = true, KEEP_CONNECTION = true,
  })
  C4:NetConnect(NETWORK_BINDING, port)
  netRetryLater()
end

function OnConnectionStatusChanged(idBinding, nPort, strStatus)
  if idBinding ~= NETWORK_BINDING then return end
  dbg("Network " .. tostring(nPort) .. ": " .. tostring(strStatus))
  if strStatus == "ONLINE" then
    local wasOnline = gNet.online
    gNet.online = true
    netStopTimer()
    setProp("Connection Status", "Online (network " .. tostring(gNet.address) .. ")")
    if not wasOnline then
      RefreshStatus()
    end
    SendNext()
  else
    gNet.online = false
    if UsingNetwork() and gNet.address ~= nil then
      setProp("Connection Status", "Offline - retrying " .. gNet.address .. ":" .. tostring(gNet.port))
      netRetryLater()
    end
  end
end

------------------------------------------------------------------ command queue

local function onlineLabel()
  if UsingNetwork() then return "Online (network " .. tostring(gNet.address) .. ")" end
  return "Online"
end

local function finish(raw)
  gNoReplyTimer = cancel(gNoReplyTimer)
  gSettleTimer = cancel(gSettleTimer)
  local item = gCurrent
  gCurrent = nil
  gRx = ""
  if item ~= nil then
    local text = clean(raw)
    if raw == nil then text = "(no reply)" elseif text == "" then text = "(empty reply)" end
    note(text)
    if transportReady() then
      setProp("Connection Status", raw == nil and "No reply from matrix" or onlineLabel())
    end
    dbg(item.cmd .. " -> " .. text)
    if raw ~= nil then parseFeedback(raw) end
    if item.onReply ~= nil then item.onReply(raw or "", text) end
  end
  SendNext()
end

SendNext = function()
  if gCurrent ~= nil or #gQueue == 0 then return end
  if not transportReady() then return end     -- network: wait for ONLINE
  gCurrent = table.remove(gQueue, 1)
  gRx = ""
  setProp("Last Command Sent", gCurrent.cmd)
  dbg("TX: " .. gCurrent.cmd)
  transmit(gCurrent.cmd)
  gNoReplyTimer = C4:SetTimer(NO_REPLY_MS, function()
    gNoReplyTimer = nil
    if gRx == "" then finish(nil) end
  end)
end

-- Priority items (room power and routing) go ahead of polls/queries but keep
-- their order among themselves, so PowerON always reaches the matrix before the route.
function Send(cmd, onReply, priority)
  if cmd == nil or cmd == "" then return end
  if cmd:sub(-1) ~= "." then cmd = cmd .. "." end
  local item = { cmd = cmd, onReply = onReply, pri = priority and true or false }
  if not priority and #gQueue >= MAX_QUEUE then
    dbg("Queue full (matrix offline?), dropped " .. cmd)
    return
  end
  if priority then
    local pos = 1
    while gQueue[pos] ~= nil and gQueue[pos].pri do pos = pos + 1 end
    table.insert(gQueue, pos, item)
  else
    table.insert(gQueue, item)
  end
  SendNext()
end

-- Replies and the matrix's own status lines (front panel, IR remote, and over
-- the network, changes made by other clients such as Home Assistant).
local function onData(strData)
  dbg("RX: " .. strData)
  gRx = gRx .. strData
  gSettleTimer = cancel(gSettleTimer)
  local settle = SETTLE_MS
  if gCurrent ~= nil and SLOW_COMMANDS[gCurrent.cmd] then settle = SLOW_SETTLE_MS end
  gSettleTimer = C4:SetTimer(settle, function()
    gSettleTimer = nil
    if gCurrent ~= nil then
      finish(gRx)
    else
      parseFeedback(gRx)          -- unsolicited (front panel / IR remote)
      note(clean(gRx))
      gRx = ""
    end
  end)
end

function ReceivedFromSerial(idBinding, strData)
  if idBinding ~= SERIAL_BINDING or UsingNetwork() then return end
  onData(strData)
end

function ReceivedFromNetwork(idBinding, nPort, strData)
  if idBinding ~= NETWORK_BINDING or not UsingNetwork() then return end
  onData(strData)
end

------------------------------------------------------------------ routing

function Route(input, output)
  input, output = tonumber(input), tonumber(output)
  if input == nil or output == nil or input < 1 or input > NUM_PORTS or output < 1 or output > NUM_PORTS then
    dbg("Route ignored, bad ports: " .. tostring(input) .. " -> " .. tostring(output))
    return
  end
  -- Rooms often ask twice for the same path; skip a repeat within 1 s.
  local key = input .. ">" .. output
  local now = os.time()
  if gLastRoute.key == key and now - gLastRoute.time <= 1 then return end
  gLastRoute = { key = key, time = now }

  Send("OUT" .. two(output) .. ":" .. two(input) .. ".", nil, true)
  setRoute(output, input)      -- optimistic; confirmed by the reply / next poll
end

function RouteAll(input)
  input = tonumber(input)
  if input == nil or input < 1 or input > NUM_PORTS then return end
  Send("OUT00:" .. two(input) .. ".")
  Send("STA_VIDEO.")
end

function RefreshStatus()
  Send("STA_VIDEO.")
  Send("STA.")
end

local DIAG_STEPS = {
  "STA.", "STA_VIDEO.", "STA_IN.", "STA_OUT.", "STA_POUT.", "STA_HDCP.",
  "STA_IR.", "STA_IRRCM.", "STA_PCAT.", "STA_TEMP.", "GetGuiIP.", "EDIDSTA00.",
}

function RunDiagnostics()
  local results = {}
  setProp("Diagnostics", "(running...)")
  for i, cmd in ipairs(DIAG_STEPS) do
    Send(cmd, function(raw, text)
      table.insert(results, cmd .. " " .. text)
      if i == #DIAG_STEPS then
        setProp("Diagnostics", table.concat(results, "  ||  "))
        print("[GoFanco] Diagnostics:\n  " .. table.concat(results, "\n  "))
      end
    end)
  end
end

------------------------------------------------------------------ action helpers

local function needPort(n, allowed, what)
  for _, a in ipairs(allowed) do if n == a then return true end end
  note("(not sent - " .. what .. ")")
  return false
end

local function hdcp(mode)
  Send("HDCP" .. two(selNum("Output Selection")) .. mode .. ".")
end

local function hdmi5v(on)
  local o = selNum("Output Selection")
  if needPort(o, { 0, 4, 5 }, "HDMI 5V only applies to Output Selection All, 4 or 5") then
    Send((on and "@OUT" or "$OUT") .. two(o) .. ".")
  end
end

local function poc(on)
  local o = selNum("Output Selection")
  if needPort(o, { 0, 1, 2, 3 }, "PoC only applies to Output Selection All, 1, 2 or 3") then
    Send("PCAT" .. two(o) .. (on and ":ON." or ":OFF."))
  end
end

local function irrcm(on)
  Send("IRRCM" .. two(selNum("Receiver Selection")) .. (on and "ON." or "OFF."))
end

local function cecSource(code)
  local i = selNum("Input Selection")
  local aa = (i == 0) and "FF" or two(i)
  local bb = Properties["CEC Source Device Type"] or "04"
  Send("CECI" .. aa .. bb .. "44" .. code .. ".")
end

local function cecDisplayAA()
  local o = selNum("Output Selection")
  if o == 0 then return "FF" end
  if needPort(o, { 4, 5 }, "CEC display control only works on Output Selection All, 4 or 5") then return two(o) end
  return nil
end

local function cecDisplayVolume(code)
  local aa = cecDisplayAA()
  if aa then Send("CECO" .. aa .. (Properties["CEC Display Device Type"] or "40") .. "44" .. code .. ".") end
end

local function cecDisplayPower(code)
  local aa = cecDisplayAA()
  if aa then Send("CECO" .. aa .. (Properties["CEC Display Device Type"] or "40") .. code .. ".") end
end

local function presetNum() return two(Properties["Preset Number"] or "1") end

------------------------------------------------------------------ actions

ACTIONS = {
  REFRESH       = RefreshStatus,
  DIAGNOSTICS   = RunDiagnostics,
  QUERY_IP      = function() Send("GetGuiIP.") end,
  SET_IP        = function()
    local ip = (Properties["New IP Address"] or ""):match("^%s*(%d+%.%d+%.%d+%.%d+)%s*$")
    if ip == nil then note("(not sent - New IP Address is not a valid IPv4 address)") return end
    Send("SetGuiIP:" .. ip .. ".")
  end,
  QUERY_INFO    = function()
    Send("/*Name.")
    Send("/*Type.", function(raw, text) setProp("Model Info", text) end)
    Send("/^Version.", function(raw, text) setProp("Firmware Version", text) end)
  end,
  QUERY_TEMP    = function() Send("STA_TEMP.") end,
  APPLY_ROUTE   = function()
    gLastRoute = { key = "", time = 0 }
    Route(Properties["Route Input"], Properties["Route Output"])
  end,
  ROUTE_ALL     = function() RouteAll(Properties["Route Input"]) end,
  PRESET_SAVE   = function() Send("PresetSave" .. presetNum() .. ".") end,
  PRESET_RECALL = function() Send("PresetRecall" .. presetNum() .. ".") end,
  PRESET_SHOW   = function() Send("PresetSta" .. presetNum() .. ".") end,
  POWER_ON      = function() Send("PowerON.") end,
  POWER_OFF     = function() Send("PowerOFF.") end,
  LOCK          = function() Send("Lock.") end,
  UNLOCK        = function() Send("Unlock.") end,
  HDCP_MAT      = function() hdcp("MAT") end,
  HDCP_BYP      = function() hdcp("BYP") end,
  HDCP_ON       = function() hdcp("ON") end,
  HDCP_OFF      = function() hdcp("OFF") end,
  HDMI5V_ON     = function() hdmi5v(true) end,
  HDMI5V_OFF    = function() hdmi5v(false) end,
  POC_ON        = function() poc(true) end,
  POC_OFF       = function() poc(false) end,
  IRFV_ON       = function() Send("IRFVON.") end,
  IRFV_OFF      = function() Send("IRFVOFF.") end,
  IR_ROUTE      = function()
    local o = selNum("Output Selection")
    if needPort(o, { 1, 2, 3, 4 }, "IR route needs Output Selection 1-4 (the local IR out port)") then
      Send("IR" .. two(o) .. ":" .. two(selNum("Receiver Selection")) .. ".")
    end
  end,
  IRRCM_ON      = function() irrcm(true) end,
  IRRCM_OFF     = function() irrcm(false) end,
  AUDIO_SRC     = function()
    local o = tonumber((Properties["Audio Out Source"] or "Output 1"):match("(%d+)")) or 1
    Send("AUDIO00:" .. two(o) .. ".")
  end,
  EDID_BUILTIN  = function()
    local e = tonumber((Properties["Built-in EDID Number"] or "01"):match("^(%d+)")) or 1
    Send("EDID/" .. two(selNum("Input Selection")) .. "/" .. two(e) .. ".")
  end,
  EDID_COPY     = function()
    local o = selNum("Output Selection")
    if needPort(o, { 1, 2, 3, 4, 5 }, "EDID copy needs Output Selection 1-5 (the display to copy from)") then
      Send("EDIDM" .. two(o) .. "B" .. two(selNum("Input Selection")) .. ".")
    end
  end,
  EDID_READ     = function()
    local o = selNum("Output Selection")
    if needPort(o, { 1, 2, 3, 4, 5 }, "Read EDID needs Output Selection 1-5") then
      Send("EDIDGOUT" .. two(o) .. ".")
    end
  end,
  EDID_DEFAULT  = function() Send("EDIDMInit.") end,
  EDID_STATUS   = function() Send("EDIDSTA" .. two(selNum("Input Selection")) .. ".") end,
  CECI_6D = function() cecSource("6D") end,
  CECI_6C = function() cecSource("6C") end,
  CECI_0A = function() cecSource("0A") end,
  CECI_01 = function() cecSource("01") end,
  CECI_02 = function() cecSource("02") end,
  CECI_03 = function() cecSource("03") end,
  CECI_04 = function() cecSource("04") end,
  CECI_00 = function() cecSource("00") end,
  CECI_09 = function() cecSource("09") end,
  CECI_0D = function() cecSource("0D") end,
  CECO_ON  = function() cecDisplayPower("04") end,
  CECO_OFF = function() cecDisplayPower("36") end,
  CECO_41  = function() cecDisplayVolume("41") end,
  CECO_42  = function() cecDisplayVolume("42") end,
  CECO_43  = function() cecDisplayVolume("43") end,
  SEND_RAW      = function() Send(Properties["Raw Command"]) end,
  FACTORY_RESET = function()
    if Properties["Confirm Factory Reset"] ~= RESET_CONFIRM then
      note("(reset NOT sent - set 'Confirm Factory Reset' to '" .. RESET_CONFIRM .. "' first)")
      return
    end
    setProp("Confirm Factory Reset", "No")
    print("[GoFanco] Sending factory reset (RST.)")
    Send("RST.")
  end,
}

function ExecuteCommand(strCommand, tParams)
  tParams = tParams or {}
  if strCommand == "LUA_ACTION" then
    local fn = ACTIONS[tParams.ACTION]
    if fn then fn() else dbg("Unknown action: " .. tostring(tParams.ACTION)) end
  elseif strCommand == "Route Input To Output" then
    gLastRoute = { key = "", time = 0 }
    Route(tParams["Input"], tParams["Output"])
  elseif strCommand == "Route Input To All Outputs" then
    RouteAll(tParams["Input"])
  elseif strCommand == "Recall Preset" then
    Send("PresetRecall" .. two(tParams["Preset"] or 1) .. ".")
  elseif strCommand == "Power On" then
    ACTIONS.POWER_ON()
  elseif strCommand == "Power Off" then
    ACTIONS.POWER_OFF()
  elseif strCommand == "Refresh Status" then
    RefreshStatus()
  elseif strCommand == "Send Raw Command" then
    Send(tParams["Command"])
  end
end

------------------------------------------------------------------ proxy

function ReceivedFromProxy(idBinding, strCommand, tParams)
  tParams = tParams or {}
  dbg("Proxy: " .. strCommand)
  local roomPower = (Properties["Power Handling"] or ""):find("PowerON") ~= nil
  if strCommand == "SET_INPUT" then
    local input, output = portNum(tParams.INPUT), portNum(tParams.OUTPUT)
    if input ~= nil and output ~= nil then Route(input, output) end
  elseif strCommand == "ON" then
    -- Control4 sends ON when a room starts using the matrix...
    if roomPower then Send("PowerON.", nil, true) end
  elseif strCommand == "OFF" then
    -- ...and OFF only once no room is using it any more (rooms sharing a source stay on).
    if roomPower then Send("PowerOFF.", nil, true) end
  end
  -- CONNECT_OUTPUT / DISCONNECT_OUTPUT are ignored: this matrix has no per-output video mute.
end

------------------------------------------------------------------ polling & lifecycle

local POLL_MS = { ["1 minute"] = 60000, ["5 minutes"] = 300000, ["15 minutes"] = 900000 }

function StartPolling()
  gPollTimer = cancel(gPollTimer)
  local ms = POLL_MS[Properties["Poll Interval"] or ""]
  if ms ~= nil then
    gPollTimer = C4:SetTimer(ms, function() Send("STA_VIDEO.") end, true)
  end
end

local CONNECTION_PROPS = { ["Connection Type"] = true, ["IP Address"] = true, ["Network Port"] = true }

function OnPropertyChanged(strProperty)
  if strProperty == "Poll Interval" then StartPolling()
  elseif CONNECTION_PROPS[strProperty] then
    -- Anything half-sent belongs to the old link; start clean.
    gNoReplyTimer = cancel(gNoReplyTimer)
    gSettleTimer = cancel(gSettleTimer)
    gCurrent, gRx = nil, ""
    ApplyConnection()
    if not UsingNetwork() then RefreshStatus() end   -- network refreshes once ONLINE
  end
end

function OnDriverLateInit()
  setProp("Driver Version", DRIVER_VERSION)
  StartPolling()
  ApplyConnection()
  if not UsingNetwork() then
    C4:SetTimer(STARTUP_DELAY_MS, function() RefreshStatus() end)
  end
end

function OnDriverDestroyed()
  gPollTimer = cancel(gPollTimer)
  gSettleTimer = cancel(gSettleTimer)
  gNoReplyTimer = cancel(gNoReplyTimer)
  netDisconnect()
end
