-- SAS HMI -- MineOS application entry point. IEC 61850-style substation
-- automation HMI: mimic diagram, select-before-operate control, alarm
-- panel, talking to an OC-IEC61850-SAS SCADA node over MMS-lite.
--
-- The GUI/window-manager/event-loop calls below are cross-checked against
-- MineOS's actual documentation (github.com/IgorTimofeev/MineOS.wiki),
-- specifically System-API.md ("How to develop MineOS applications?" and
-- system.addWindow's example), Event-API.md (event.addHandler), and
-- GUI-API.md (object/container/button/text/window/addBackgroundContainer
-- sections) -- not guessed. Two things remain genuinely unverified since
-- they aren't in the wiki: Icon.pic's exact pixel format/dimensions (see
-- ICON_NOTE.txt), and whether the built-in `component.modem`/
-- `event.listen("modem_message", ...)` transport (sas/proto/netmsg.lua)
-- behaves the same under MineOS as under OpenOS (a transport-layer
-- question, unrelated to the GUI calls here -- see the MineOS risk note
-- in README.md).
--
-- Everything below that ISN'T a GUI/event-loop call (the SCADA protocol
-- client, the SBO flow, the data model) reuses sas/proto/*, sas/model.lua
-- and sas/sbo.lua unchanged from the OpenOS-side SCADA/IED code.
local GUI = require("GUI")
local system = require("System")
local event = require("event")

local config = require("sas.config")
local model = require("sas.model")
local mmsclient = require("sas.proto.mmsclient")

local CFG_PATH = "/etc/sas-hmi.cfg"
local DEFAULTS = {
  -- Must match the SCADA node's own `scadaName` (sas-scada.cfg) --
  -- resolved to a modem address/port at runtime via sas.proto.discovery,
  -- no static address needed.
  scada = "SCADA",
  operator = "operator1",
  pollIntervalSec = 0.5,
  mimicLayout = {},
}

local cfg = config.load(CFG_PATH, DEFAULTS)

--- Application state ------------------------------------------------------------

local app = {
  client = nil,           -- sas.proto.mmsclient.Client, once connected
  points = {},            -- [fullRef] = { ln, doName, type, value, quality, t, widget=, layoutX=, layoutY= }
  alarms = {},            -- array of alarm records (from the last alarm-update/alarm-list-reply)
  pending = {},            -- [fullRef] = { token= } -- our own outstanding SBO selections
  dialog = nil,
}

--- GUI construction ------------------------------------------------------------

-- Per System-API.md's own MineOS-integration example, an application adds
-- a window to the OS's existing shared workspace (system.addWindow) --
-- it does NOT create its own top-level GUI.workspace(). system.getWorkspace()
-- first just to read screen dimensions before the window can be sized.
local sizingWorkspace = system.getWorkspace()
local WIN_WIDTH = math.min(100, sizingWorkspace.width - 4)
local WIN_HEIGHT = math.min(35, sizingWorkspace.height - 4)
-- Approximate MineOS titled-window header height (title bar + separator);
-- the wiki doesn't give an exact figure -- verify/adjust against a real
-- MineOS install.
local TITLE_HEIGHT = 3

local workspace, window = system.addWindow(GUI.titledWindow(1, 1, WIN_WIDTH, WIN_HEIGHT, "SAS HMI", true))

local contentX, contentWidth = 2, WIN_WIDTH - 2
local statusY = TITLE_HEIGHT + 1
local mimicY = statusY + 2
local mimicHeight = WIN_HEIGHT - mimicY - 9

local statusText = window:addChild(GUI.text(contentX, statusY, 0xFFFFFF,
  "SAS HMI -- connecting to " .. cfg.scada .. " ..."))

local mimicPanel = window:addChild(GUI.container(contentX, mimicY, contentWidth, mimicHeight))

local alarmY = mimicY + mimicHeight + 1
local alarmPanel = window:addChild(GUI.container(contentX, alarmY, contentWidth, 7))
alarmPanel:addChild(GUI.text(1, 1, 0xFFAA00, "Alarms"))
local alarmRowsContainer = alarmPanel:addChild(GUI.container(1, 2, contentWidth, 5))

-- Colors matching each DPS state, per the plan's mimic-diagram spec.
local DPS_COLOR = {
  closed = 0x00CC00,
  open = 0xCC0000,
  intermediate = 0xCCCC00,
  bad = 0x888888,
}

local function qualityColor(quality, base)
  if quality == "stale" or quality == "invalid" then return 0x888888 end
  return base
end

--- Control dialog (select -> operate/cancel) ------------------------------------------------------------

local function closeDialogIfAny()
  if app.dialog then
    -- object:remove() is the documented way to remove a single widget
    -- from its parent container (GUI-API.md) -- there is no
    -- container:removeChild(x) method.
    app.dialog:remove()
    app.dialog = nil
  end
end

local function sendControl(msgType, ref, extra, onReply)
  local req = { type = msgType, ref = ref, clientId = cfg.operator }
  if extra then for k, v in pairs(extra) do req[k] = v end end
  local id = app.client:sendRequest(req)
  app.awaitingReplies = app.awaitingReplies or {}
  if id then app.awaitingReplies[id] = onReply end
end

local function openControlDialog(fullRef, pointType)
  closeDialogIfAny()

  -- GUI.addBackgroundContainer (GUI-API.md) is the documented modal-
  -- dialog helper: it adds a semi-transparent background panel (with a
  -- built-in click-outside-to-close handler) plus an auto-arranging
  -- layout, both already parented into `window`. Note: clicking outside
  -- the dialog closes it via that built-in handler WITHOUT sending an
  -- explicit `cancel` -- an outstanding `select` reservation is simply
  -- abandoned client-side; the IED's own sbo.timeoutSec still releases
  -- it server-side, so this is a minor UX gap, not a correctness one.
  local dialog = GUI.addBackgroundContainer(window, true, true, "Control: " .. fullRef)

  local status = dialog.layout:addChild(GUI.text(1, 1, 0xCCCCCC, "Not selected."))
  local selectBtn = dialog.layout:addChild(GUI.button(1, 1, 24, 1, 0x333333, 0xFFFFFF, 0x666666, 0xFFFFFF, "Select"))
  local openBtn = dialog.layout:addChild(GUI.button(1, 1, 24, 1, 0x006600, 0xFFFFFF, 0x00AA00, 0xFFFFFF, "Operate Open"))
  local closeBtn = dialog.layout:addChild(GUI.button(1, 1, 24, 1, 0x660000, 0xFFFFFF, 0xAA0000, 0xFFFFFF, "Operate Close"))
  local cancelBtn = dialog.layout:addChild(GUI.button(1, 1, 24, 1, 0x333333, 0xFFFFFF, 0x666666, 0xFFFFFF, "Cancel"))
  openBtn.disabled, closeBtn.disabled = true, true

  selectBtn.onTouch = function()
    sendControl("select", fullRef, nil, function(reply)
      if reply.ok then
        app.pending[fullRef] = { token = reply.token }
        status.text = "Selected. Choose operate open/close, or cancel."
        openBtn.disabled, closeBtn.disabled = false, false
      else
        status.text = "Select failed: " .. tostring(reply.err)
      end
      workspace:draw()
    end)
  end

  local function operate(value)
    local sel = app.pending[fullRef]
    if not sel then return end
    sendControl("operate", fullRef, { token = sel.token, value = value }, function(reply)
      if reply.ok then
        status.text = "Operate " .. value .. " accepted."
        app.pending[fullRef] = nil
      else
        status.text = "Operate failed: " .. tostring(reply.err)
      end
      workspace:draw()
    end)
  end
  openBtn.onTouch = function() operate("open") end
  closeBtn.onTouch = function() operate("closed") end

  cancelBtn.onTouch = function()
    local sel = app.pending[fullRef]
    if sel then
      sendControl("cancel", fullRef, { token = sel.token }, function() end)
      app.pending[fullRef] = nil
    end
    closeDialogIfAny()
    workspace:draw()
  end

  app.dialog = dialog
  workspace:draw()
end

--- Mimic diagram ------------------------------------------------------------

local nextAutoX, nextAutoY = 0, 0
local AUTO_COLS = 4

local function layoutFor(fullRef)
  local manual = cfg.mimicLayout[fullRef]
  if manual then return manual.x, manual.y end
  local col = (nextAutoX % AUTO_COLS)
  local x, y = 1 + col * 18, 1 + nextAutoY * 2
  nextAutoX = nextAutoX + 1
  if nextAutoX % AUTO_COLS == 0 then nextAutoY = nextAutoY + 1 end
  return x, y
end

-- Rebuilds every mimic widget from scratch, called once after get-model.
local function buildMimic()
  mimicPanel:removeChildren()
  nextAutoX, nextAutoY = 0, 0
  for fullRef, p in pairs(app.points) do
    local x, y = layoutFor(fullRef)
    p.layoutX, p.layoutY = x, y
    local label = p.ln .. "." .. p.doName
    if p.type == "DPS" or p.type == "SPS" then
      local widget = mimicPanel:addChild(GUI.button(x, y, 16, 1, 0x444444, 0xFFFFFF, 0x666666, 0xFFFFFF, label))
      p.widget = widget
      -- A status point's control counterpart (if any -- see
      -- model.computePointPairing) has a DIFFERENT ref, not this same
      -- one -- status and control are separate DOI entries sharing an LN
      -- but never a doName (see etc/sas-ied.cfg.example's XCBR1.Pos
      -- status / XCBR1.PosCtl control). A status-only point (no
      -- pairedFullRef) just does nothing useful server-side if clicked --
      -- select on a non-control ref is rejected by the IED with a clear
      -- error.
      widget.onTouch = function() openControlDialog(p.pairedFullRef or fullRef, p.type) end
    elseif p.type == "MV" then
      local widget = mimicPanel:addChild(GUI.text(x, y, 0xFFFFFF, label .. ": --"))
      p.widget = widget
    end
    -- DPC/SPC control points themselves have no separate tile; they're
    -- reached via their paired status point's tile (same LN, distinct
    -- doName -- see etc/sas-ied.cfg.example).
  end
end

local function refreshMimicWidget(fullRef)
  local p = app.points[fullRef]
  if not p or not p.widget then return end
  local label = p.ln .. "." .. p.doName
  if p.type == "DPS" or p.type == "SPS" then
    local bg
    if p.type == "DPS" then
      bg = qualityColor(p.quality, DPS_COLOR[p.value] or 0x888888)
    else
      bg = qualityColor(p.quality, p.value and 0x00CC00 or 0x666666)
    end
    -- A widget's background color has no documented mutable property
    -- (GUI-API.md's button properties table has no color entry, and
    -- nothing like the constructor's buttonColor is ever shown being
    -- reassigned) -- recreate the widget in place instead of mutating an
    -- undocumented field, at the position buildMimic() recorded.
    p.widget:remove()
    local widget = mimicPanel:addChild(GUI.button(p.layoutX, p.layoutY, 16, 1, bg, 0xFFFFFF, 0x666666, 0xFFFFFF,
      label .. ": " .. tostring(p.value)))
    widget.onTouch = function() openControlDialog(p.pairedFullRef or fullRef, p.type) end
    p.widget = widget
  elseif p.type == "MV" then
    -- .text reassignment IS documented ("When you change the text, its
    -- width is automatically calculated" -- GUI-API.md's GUI.text
    -- section), so this stays a direct mutation, no recreation needed.
    p.widget.text = label .. ": " .. tostring(p.value) .. (p.quality ~= "good" and (" [" .. p.quality .. "]") or "")
  end
end

--- Alarm panel ------------------------------------------------------------

local function refreshAlarmPanel()
  alarmRowsContainer:removeChildren()
  for i, a in ipairs(app.alarms) do
    if i > 5 then break end -- panel only shows the 5 most recent; full list belongs in a dedicated view
    local y = i
    local color = a.severity == "high" and 0xFF3333 or (a.severity == "medium" and 0xFFAA00 or 0xFFFF66)
    local label = string.format("[%s] %s%s", a.severity, a.message, a.acked and " (acked)" or "")
    alarmRowsContainer:addChild(GUI.text(1, y, color, label))
    if not a.acked then
      local ackBtn = alarmRowsContainer:addChild(
        GUI.button(contentWidth - 12, y, 10, 1, 0x333333, 0xFFFFFF, 0x666666, 0xFFFFFF, "Ack"))
      ackBtn.onTouch = function()
        app.client:sendRequest({ type = "alarm-ack", alarmId = a.id, operator = cfg.operator })
      end
    end
  end
end

--- Network poll tick ------------------------------------------------------------

local function applyReport(values)
  for fullRef, v in pairs(values) do
    local p = app.points[fullRef]
    if p then
      p.value, p.quality, p.t = v.value, v.quality, v.t
      refreshMimicWidget(fullRef)
    end
  end
end

local function pollTick()
  if not app.client then return end
  local ok, err = app.client:poll()
  if not ok then
    statusText.text = "SAS HMI -- disconnected: " .. tostring(err)
    workspace:draw()
    return
  end

  for _, push in ipairs(app.client:drainInbox()) do
    if push.type == "report" then
      applyReport(push.values)
    elseif push.type == "alarm-update" then
      app.alarms = push.alarms
      refreshAlarmPanel()
    end
  end

  if app.awaitingReplies then
    for id, cb in pairs(app.awaitingReplies) do
      local reply = app.client:popReply(id)
      if reply then
        app.awaitingReplies[id] = nil
        cb(reply)
      end
    end
  end

  workspace:draw()
end

--- Startup ------------------------------------------------------------

local function connectAndLoadModel()
  local client, err = mmsclient.connect(cfg.scada, 10)
  if not client then
    statusText.text = "SAS HMI -- connect failed: " .. tostring(err)
    return
  end
  app.client = client
  statusText.text = "SAS HMI -- connected to " .. cfg.scada

  local modelReply, merr = client:request({ type = "get-model" }, 10)
  if not modelReply then
    statusText.text = "SAS HMI -- get-model failed: " .. tostring(merr)
    return
  end

  app.points = {}
  for _, p in ipairs(modelReply.points) do
    app.points[p.fullRef] = {
      ln = p.ln, doName = p.doName, type = p.type, value = nil, quality = "invalid",
      pairedFullRef = p.pairedFullRef,
    }
  end
  buildMimic()

  local subReply, serr = client:request({ type = "subscribe", refs = "*" }, 10)
  if not subReply then
    statusText.text = "SAS HMI -- subscribe failed: " .. tostring(serr)
  end

  local alarmReply = client:request({ type = "alarm-list" }, 10)
  if alarmReply then
    app.alarms = alarmReply.alarms
    refreshAlarmPanel()
  end
end

connectAndLoadModel()
workspace:draw()

-- Periodic poll via MineOS's own event.addHandler (Event-API.md) --
-- handlers registered this way run during MineOS's own already-running
-- event.pull() loop, which is why this script does NOT (and must not)
-- call workspace:start() itself: that would start a second, competing
-- event loop instead of cooperating with the one MineOS's desktop core
-- already owns (see this file's header and README.md's architecture
-- section for the full reasoning).
event.addHandler(pollTick, cfg.pollIntervalSec)
