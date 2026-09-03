-- sas.hmi.engine: the OpenOS terminal HMI's protocol/state module --
-- shaped like sas/scada/engine.lua (engine.state, start()/stop()/
-- isRunning()) but foreground/interactive rather than event.timer-driven
-- -- usr/bin/sas-hmi.lua owns the actual event loop (no rc.d/event.timer
-- owner exists for a foreground program) and calls engine.tick() on
-- every poll-interval timeout plus engine.handleEvent() for touch/
-- key_down signals.
--
-- The protocol/state logic below (connect + get-model bootstrap, the
-- poll-tick drain-report/alarm-update/awaitingReplies loop, the
-- select->operate/cancel SBO dialog flow, DPS_COLOR) is ported
-- essentially unchanged in shape from the deleted MineOS app
-- (mineos/SAS-HMI.app/Main.lua) -- only the rendering/input layer
-- (sas/hmi/render.lua, sas/hmi/layout.lua) is new. Reuses
-- sas/proto/mmsclient.lua, sas/proto/messages.lua, sas/config.lua
-- verbatim, same as the deleted app did.
local config = require("sas.config")
local messages = require("sas.proto.messages")
local mmsclient = require("sas.proto.mmsclient")
local keyboard = require("keyboard")

local layout = require("sas.hmi.layout")
local render = require("sas.hmi.render")

local engine = {}

local CFG_PATH = "/etc/sas-hmi.cfg"
local DEFAULTS = {
  -- Must match the SCADA node's own `scadaName` (sas-scada.cfg) --
  -- resolved to a modem address/port at runtime via sas.proto.discovery,
  -- no address to configure. No mimicLayout anymore -- the one-line
  -- diagram is compiled from real SCL topology and served by SCADA
  -- itself (get-model-reply's `diagram` field); see README.md's "SCL /
  -- Substation Configuration Language" section.
  scada = "SCADA",
  operator = "operator1",
  pollIntervalSec = 0.5,
  viewport = { panStepCols = 4, panStepRows = 2 },
}

local ALARM_PANEL_ROWS = 5
local ALARM_HEADER_ROWS = 1
local STATUS_LINE_ROWS = 1

-- Colors matching each DPS state -- unchanged from the deleted MineOS
-- app's own DPS_COLOR.
local DPS_COLOR = {
  closed = 0x00CC00,
  open = 0xCC0000,
  intermediate = 0xCCCC00,
  bad = 0x888888,
}
local UNKNOWN_STATUS_COLOR = 0x444444

local function qualityColor(quality, base)
  if quality == "stale" or quality == "invalid" then return 0x888888 end
  return base
end

local function fmtNum(v)
  if type(v) ~= "number" then return "--" end
  return string.format("%.1f", v)
end

engine.state = {
  running = false,
  cfg = nil,
  ctx = nil,              -- render.open()'s context
  client = nil,           -- sas.proto.mmsclient.Client, once connected
  points = {},            -- [fullRef] = { ln, doName, type, value, quality, t, pairedFullRef }
  alarms = {},            -- array of alarm records (from the last alarm-update/alarm-list-reply)
  awaitingReplies = {},   -- [reqId] = callback(reply)
  diagram = nil,          -- modelReply.diagram, or nil (compiler-less SCADA -- see buildAutoGrid)
  frame = nil,            -- last layout.buildFrame(...) result, for hit-testing
  viewport = nil,         -- { panX, panY, viewW, viewH }
  autoGridTiles = nil,    -- fallback layout when diagram is absent
  autoGridExtent = nil,   -- { width, height } of the fallback layout, for panClamp
  alarmRects = nil,       -- [{ rect=, alarmId= }, ...] from the last alarm panel redraw
  dialog = nil,           -- { tile=, selected=, token=, message=, rects= } while a control/detail dialog is open
  statusText = "starting...",
}

--- Auto-grid fallback (diagram-less SCADA) ------------------------------------------------------------

local AUTO_COLS = 4
local AUTO_COL_W = 18
local AUTO_ROW_H = 2

-- Ported from the deleted MineOS app's layoutFor/buildMimic: when SCADA
-- has no compiled `diagram` (a hand-written sas-scada.cfg never run
-- through tools/scl-compiler), fall back to an auto-arranged grid of
-- point tiles rather than refusing to show anything -- still
-- interactive/live, just not a real one-line diagram.
local function buildAutoGrid()
  local refs = {}
  for fullRef in pairs(engine.state.points) do table.insert(refs, fullRef) end
  table.sort(refs)  -- deterministic redraw order

  local tiles = {}
  local col, row = 0, 0
  local maxX, maxY = 1, 1
  for _, fullRef in ipairs(refs) do
    local p = engine.state.points[fullRef]
    local x, y = 1 + col * AUTO_COL_W, 1 + row * AUTO_ROW_H
    tiles[#tiles + 1] = { fullRef = fullRef, x = x, y = y, ln = p.ln, doName = p.doName, type = p.type }
    maxX = math.max(maxX, x + AUTO_COL_W)
    maxY = math.max(maxY, y + AUTO_ROW_H)
    col = col + 1
    if col % AUTO_COLS == 0 then col = 0; row = row + 1 end
  end
  engine.state.autoGridTiles = tiles
  engine.state.autoGridExtent = { width = maxX, height = maxY }
end

--- Rendering: main screen ------------------------------------------------------------

local function statusColorFor(fullRef)
  local p = fullRef and engine.state.points[fullRef]
  if not p then return UNKNOWN_STATUS_COLOR end
  if p.type == "DPS" then
    return qualityColor(p.quality, DPS_COLOR[p.value] or UNKNOWN_STATUS_COLOR)
  elseif p.type == "SPS" then
    return qualityColor(p.quality, p.value and 0x00CC00 or 0x666666)
  end
  return UNKNOWN_STATUS_COLOR
end

local function findTile(frame, id)
  for _, t in ipairs(frame.tiles) do
    if t.id == id then return t end
  end
  return nil
end

local function drawDiagramFrame(ctx, frame)
  for _, bus in ipairs(frame.buses) do
    render.line(ctx, bus.x1, bus.y1, bus.x2, bus.y2, "double")
    if bus.y1 > 1 then render.text(ctx, math.max(1, bus.x1), bus.y1 - 1, 0xAAAAAA, 0x000000, bus.label) end
  end
  for _, seg in ipairs(frame.segments) do
    render.line(ctx, seg.x1, seg.y1, seg.x2, seg.y2, "single")
  end
  for _, link in ipairs(frame.transformerLinks) do
    render.line(ctx, link.x1, link.y1, link.x2, link.y2, "single")
  end
  for _, t in ipairs(frame.taps) do
    render.tapSymbol(ctx, t.x, t.y, t.tapKind, "down")
  end
  for _, d in ipairs(frame.disconnects) do
    render.tick(ctx, d.x, d.y, d.orientation)
  end
  for _, tile in ipairs(frame.tiles) do
    local rect = render.tile(ctx, tile.x, tile.y, tile.label, statusColorFor(tile.statusFullRef), 0xFFFFFF)
    -- Compact per-phase readout to the RIGHT of the tile (not below --
    -- the row(s) directly beneath a breaker are the diameter's own
    -- vertical conductor/next element, see scl/char_layout.py). First
    -- cut at placement, flagged for in-game tuning in README.md's
    -- testing runbook.
    if tile.measFullRefBase then
      local base = tile.measFullRefBase
      local function v(suffix) local p = engine.state.points[base .. "." .. suffix]; return p and p.value end
      render.measureReadout(ctx, rect.x2 + 2, tile.y,
        v("AmpA"), v("AmpB"), v("AmpC"), v("VolAB"), v("VolBC"), v("VolCA"))
    end
  end
end

local function drawAutoGrid(ctx, viewport)
  for _, t in ipairs(engine.state.autoGridTiles or {}) do
    local sx, sy = t.x - viewport.panX, t.y - viewport.panY
    local label = t.ln .. "." .. t.doName
    if t.type == "DPS" or t.type == "SPS" then
      t.hitRect = render.tile(ctx, sx, sy, label, statusColorFor(t.fullRef), 0xFFFFFF)
    elseif t.type == "MV" then
      t.hitRect = nil
      local p = engine.state.points[t.fullRef]
      render.text(ctx, sx, sy, 0xFFFFFF, 0x000000, label .. ": " .. fmtNum(p and p.value))
    end
  end
end

local function drawAlarmPanel(ctx)
  local y0 = ctx.height - STATUS_LINE_ROWS - ALARM_PANEL_ROWS - ALARM_HEADER_ROWS + 1
  render.text(ctx, 1, y0, 0xFFAA00, 0x000000, "Alarms")
  local rects = {}
  for i, a in ipairs(engine.state.alarms) do
    if i > ALARM_PANEL_ROWS then break end
    local color = (a.severity == "high" or a.severity == "critical") and 0xFF3333
      or (a.severity == "medium" and 0xFFAA00 or 0xFFFF66)
    local label = string.format("[%s] %s%s", a.severity, a.message, a.acked and " (acked)" or "")
    local ackRect = render.alarmRow(ctx, 1, y0 + i, ctx.width, color, label, not a.acked)
    if ackRect then rects[#rects + 1] = { rect = ackRect, alarmId = a.id } end
  end
  engine.state.alarmRects = rects
end

-- Full redraw of the main screen (diagram/auto-grid + alarm panel +
-- status line). Called whenever nothing is modal -- opening a dialog
-- draws over this; closing one calls this again rather than trying to
-- restore whatever was underneath (see render.lua's dialogClose header).
function engine.redrawMain()
  local ctx = engine.state.ctx
  if not ctx then return end
  render.clear(ctx)

  if engine.state.diagram then
    local frame = layout.buildFrame(engine.state.diagram, engine.state.viewport)
    engine.state.frame = frame
    drawDiagramFrame(ctx, frame)
    render.viewportIndicator(ctx, engine.state.viewport.panX, engine.state.viewport.panY,
      engine.state.diagram.width, engine.state.diagram.height,
      engine.state.viewport.viewW, engine.state.viewport.viewH)
  else
    drawAutoGrid(ctx, engine.state.viewport)
  end

  drawAlarmPanel(ctx)
  render.statusLine(ctx, engine.state.statusText, 0xFFFFFF)
end

--- Rendering: control/measurement-detail dialog ------------------------------------------------------------

-- Merges the deleted MineOS app's select/operate/cancel dialog with a
-- per-phase measurement detail view -- one dialog covers both, opened by
-- clicking a breaker tile (diagram mode) or a status tile (auto-grid
-- fallback).
function engine.redrawDialog()
  local d = engine.state.dialog
  if not d then return end
  local ctx = engine.state.ctx
  local dlg = render.dialogOpen(ctx, d.tile.label)
  d.dlg = dlg

  if d.tile.measFullRefBase then
    local base = d.tile.measFullRefBase
    local function v(suffix) local p = engine.state.points[base .. "." .. suffix]; return p and p.value end
    render.dialogText(dlg, 1, string.format("A:  %s / %s / %s A", fmtNum(v("AmpA")), fmtNum(v("AmpB")), fmtNum(v("AmpC"))))
    render.dialogText(dlg, 2, string.format("V:  %s / %s / %s V", fmtNum(v("VolAB")), fmtNum(v("VolBC")), fmtNum(v("VolCA"))))
  else
    render.dialogText(dlg, 1, "(no per-phase measurements available)")
  end

  local statusP = d.tile.statusFullRef and engine.state.points[d.tile.statusFullRef]
  render.dialogText(dlg, 4, "Status: " .. (statusP and tostring(statusP.value) or "unknown"))
  if d.message then render.dialogText(dlg, 5, d.message, 0xFFFF66) end

  d.rects = {}
  d.rects.select = render.dialogButton(dlg, 7, "Select", true)
  d.rects.openBtn = render.dialogButton(dlg, 8, "Operate Open", d.selected)
  d.rects.closeBtn = render.dialogButton(dlg, 9, "Operate Close", d.selected)
  d.rects.cancel = render.dialogButton(dlg, 10, "Cancel", true)
  d.rects.dismiss = render.dialogButton(dlg, 12, "Close (esc)", true)
end

function engine.openDialogFor(tile)
  engine.state.dialog = { tile = tile, selected = false, token = nil, message = nil }
  engine.redrawDialog()
end

function engine.closeDialog()
  local d = engine.state.dialog
  engine.state.dialog = nil
  render.dialogClose(d and d.dlg)
  engine.redrawMain()
end

--- Control actions (select -> operate/cancel) ------------------------------------------------------------

local function sendControl(msgType, ref, extra, onReply)
  if not ref or not engine.state.client then return end
  local req = { type = msgType, ref = ref, clientId = engine.state.cfg.operator }
  if extra then for k, v in pairs(extra) do req[k] = v end end
  local id = engine.state.client:sendRequest(req)
  if id then engine.state.awaitingReplies[id] = onReply end
end

local function onSelect()
  local d = engine.state.dialog
  if not d then return end
  sendControl("select", d.tile.controlFullRef, nil, function(reply)
    local d2 = engine.state.dialog
    if not d2 then return end
    if reply.ok then
      d2.token = reply.token
      d2.selected = true
      d2.message = "Selected -- choose operate open/close, or cancel."
    else
      d2.message = "Select failed: " .. tostring(reply.err)
    end
    engine.redrawDialog()
  end)
end

local function onOperate(value)
  local d = engine.state.dialog
  if not d or not d.token then return end
  sendControl("operate", d.tile.controlFullRef, { token = d.token, value = value }, function(reply)
    local d2 = engine.state.dialog
    if not d2 then return end
    if reply.ok then
      d2.message = "Operate " .. tostring(value) .. " accepted."
      d2.selected = false
      d2.token = nil
    else
      d2.message = "Operate failed: " .. tostring(reply.err)
    end
    engine.redrawDialog()
  end)
end

local function onCancel()
  local d = engine.state.dialog
  if not d or not d.token then return end
  sendControl("cancel", d.tile.controlFullRef, { token = d.token }, function() end)
  d.selected = false
  d.token = nil
  d.message = "Cancelled."
  engine.redrawDialog()
end

--- Input dispatch ------------------------------------------------------------

local function rectHit(rect, sx, sy)
  return rect and rect.enabled ~= false and sx >= rect.x1 and sx <= rect.x2 and sy == rect.y1
end

local function handleDialogTouch(sx, sy)
  local d = engine.state.dialog
  if not d or not d.rects then return end
  if rectHit(d.rects.select, sx, sy) then onSelect()
  elseif rectHit(d.rects.openBtn, sx, sy) then onOperate("open")
  elseif rectHit(d.rects.closeBtn, sx, sy) then onOperate("closed")
  elseif rectHit(d.rects.cancel, sx, sy) then onCancel()
  elseif rectHit(d.rects.dismiss, sx, sy) then engine.closeDialog()
  end
end

local function handleMainTouch(sx, sy)
  for _, entry in ipairs(engine.state.alarmRects or {}) do
    if rectHit(entry.rect, sx, sy) then
      if engine.state.client then
        engine.state.client:sendRequest({ type = "alarm-ack", alarmId = entry.alarmId, operator = engine.state.cfg.operator })
      end
      return
    end
  end

  if engine.state.diagram then
    local kind, id = layout.hitTest(engine.state.frame, sx, sy)
    if kind == "breaker" then
      local tile = findTile(engine.state.frame, id)
      if tile then engine.openDialogFor(tile) end
    end
  else
    for _, t in ipairs(engine.state.autoGridTiles or {}) do
      local r = t.hitRect
      if r and sx >= r.x1 and sx <= r.x2 and sy == r.y1 then
        local p = engine.state.points[t.fullRef]
        engine.openDialogFor({
          label = t.ln .. "." .. t.doName,
          statusFullRef = t.fullRef,
          controlFullRef = (p and p.pairedFullRef) or t.fullRef,
          measFullRefBase = nil,
        })
        return
      end
    end
  end
end

-- `sig` is the raw event.pull signal name, `...` its payload -- called by
-- usr/bin/sas-hmi.lua for every non-timeout signal it receives. Ctrl+C is
-- deliberately NOT handled here: under OpenOS, an interrupt makes
-- event.pull itself raise a Lua error (message "interrupted") rather
-- than ever returning a normal ("interrupted", ...) signal tuple -- see
-- usr/bin/sas-hmi.lua's own pcall around its event.pull call, which is
-- where that's actually caught.
function engine.handleEvent(sig, _addr, arg1, arg2, arg3)
  if sig == "touch" then
    local sx, sy = arg1, arg2
    if engine.state.dialog then handleDialogTouch(sx, sy) else handleMainTouch(sx, sy) end
    return
  end
  if sig == "key_down" then
    local code = arg2
    if engine.state.dialog then
      if code == keyboard.keys.escape then engine.closeDialog() end
      return
    end
    if code == keyboard.keys.q then
      engine.state.running = false
      return
    end
    local step = engine.state.cfg.viewport or {}
    local dx, dy = 0, 0
    if code == keyboard.keys.left then dx = -(step.panStepCols or 4)
    elseif code == keyboard.keys.right then dx = (step.panStepCols or 4)
    elseif code == keyboard.keys.up then dy = -(step.panStepRows or 2)
    elseif code == keyboard.keys.down then dy = (step.panStepRows or 2)
    else return end
    local vp = engine.state.viewport
    vp.panX, vp.panY = vp.panX + dx, vp.panY + dy
    local extent = engine.state.diagram or engine.state.autoGridExtent
      or { width = vp.viewW, height = vp.viewH }
    engine.state.viewport = layout.panClamp(vp, extent)
    engine.redrawMain()
  end
end

--- Poll tick ------------------------------------------------------------

local function applyReport(values)
  local changed = false
  for fullRef, v in pairs(values) do
    local p = engine.state.points[fullRef]
    if p then
      p.value, p.quality, p.t = v.value, v.quality, v.t
      changed = true
    end
  end
  return changed
end

-- Called by usr/bin/sas-hmi.lua on every event.pull timeout (i.e. once
-- per pollIntervalSec with no user input in between) -- the same
-- non-blocking client:poll()/drainInbox() sweep the deleted MineOS app's
-- pollTick did.
function engine.tick()
  if not engine.state.client then return end
  local ok, err = engine.state.client:poll()
  if not ok then
    engine.state.statusText = "disconnected: " .. tostring(err)
    engine.redrawMain()
    return
  end

  local changed = false
  for _, push in ipairs(engine.state.client:drainInbox()) do
    if push.type == "report" then
      if applyReport(push.values) then changed = true end
    elseif push.type == "alarm-update" then
      engine.state.alarms = push.alarms
      changed = true
    end
  end

  for id, cb in pairs(engine.state.awaitingReplies) do
    local reply = engine.state.client:popReply(id)
    if reply then
      engine.state.awaitingReplies[id] = nil
      cb(reply)
    end
  end

  if changed then
    if engine.state.dialog then engine.redrawDialog() end
    engine.redrawMain()
  end
end

--- Startup / shutdown ------------------------------------------------------------

local function connectAndLoadModel()
  local client, err = mmsclient.connect(engine.state.cfg.scada, 10)
  if not client then
    engine.state.statusText = "connect failed: " .. tostring(err)
    return
  end
  engine.state.client = client
  engine.state.statusText = "connected to " .. engine.state.cfg.scada

  local modelReply, merr = client:request({ type = "get-model" }, 10)
  if not modelReply then
    engine.state.statusText = "get-model failed: " .. tostring(merr)
    return
  end

  local points = {}
  for _, p in ipairs(modelReply.points) do
    points[p.fullRef] = {
      ln = p.ln, doName = p.doName, type = p.type, value = nil, quality = "invalid",
      pairedFullRef = p.pairedFullRef,
    }
  end
  engine.state.points = points
  engine.state.diagram = modelReply.diagram
  if not engine.state.diagram then buildAutoGrid() end

  local subReply, serr = client:request({ type = "subscribe", refs = "*" }, 10)
  if not subReply then
    engine.state.statusText = "subscribe failed: " .. tostring(serr)
  end

  local alarmReply = client:request({ type = "alarm-list" }, 10)
  if alarmReply then
    engine.state.alarms = alarmReply.alarms
  end
end

-- Idempotent, mirroring the ied/scada engines' own start() convention.
function engine.start()
  if engine.state.running then return true end

  local cfg, cfgErr = config.load(CFG_PATH, DEFAULTS)
  engine.state.cfg = cfg
  if cfgErr then
    engine.state.statusText = cfgErr .. " (using built-in defaults)"
  end

  local ctx, rerr = render.open()
  if not ctx then
    return nil, rerr
  end
  engine.state.ctx = ctx
  engine.state.viewport = {
    panX = 0, panY = 0,
    viewW = ctx.width,
    viewH = ctx.height - STATUS_LINE_ROWS - ALARM_HEADER_ROWS - ALARM_PANEL_ROWS,
  }

  connectAndLoadModel()
  engine.state.running = true
  engine.redrawMain()
  return true
end

function engine.stop()
  if not engine.state.running then return true end
  if engine.state.client then
    pcall(function() engine.state.client:close() end)
    engine.state.client = nil
  end
  if engine.state.ctx then
    render.close(engine.state.ctx)
    engine.state.ctx = nil
  end
  engine.state.running = false
  return true
end

function engine.isRunning()
  return engine.state.running
end

return engine
