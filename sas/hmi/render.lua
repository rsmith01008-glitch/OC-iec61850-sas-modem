-- sas.hmi.render: the ONLY module in this HMI that touches
-- component.gpu -- every drawing primitive this HMI's 4 screens (main
-- diagram, modal control/detail dialog, alarm panel, status line)
-- actually need, sized to exactly that, not a general-purpose widget
-- toolkit (see README.md's "GUI library" note on why a third-party
-- library was rejected in favor of this). Callers pass already-clamped
-- SCREEN-space coordinates (1-based, matching gpu.set/fill's own
-- convention) -- see sas/hmi/layout.lua for diagram-space -> screen-space
-- translation and viewport clipping; every primitive here still
-- defensively clips against the real screen resolution per character,
-- since layout.lua only clips whole elements' bounding boxes, not each
-- individual cell of a wide label/line straddling the viewport edge.
local component = require("component")

local render = {}

-- UI palette. Status colors (breaker tile bg -- green=closed/red=open/
-- yellow=intermediate/gray=stale-or-bad) are a domain concern, not a
-- rendering one -- sas/hmi/engine.lua owns that mapping (ported from the
-- deleted MineOS app's own DPS_COLOR) and passes the resulting color
-- into render.tile/alarmRow as a plain argument.
local COLOR_BG = 0x000000
local COLOR_FG = 0xCCCCCC
local COLOR_DISCONNECT = 0x888888
local COLOR_TAP = 0xCCCCCC
local COLOR_TAP_UNKNOWN = 0x666666
local COLOR_MEAS = 0x66CCFF
local COLOR_STATUS_BG = 0x222222
local COLOR_STATUS_FG = 0xFFFFFF
local COLOR_DIALOG_BG = 0x222222
local COLOR_DIALOG_FG = 0xFFFFFF
local COLOR_BTN_BG = 0x333333
local COLOR_BTN_FG = 0xFFFFFF
local COLOR_BTN_DISABLED_BG = 0x111111
local COLOR_BTN_DISABLED_FG = 0x666666

local LINE_CHAR = { single = "\xe2\x94\x80", double = "\xe2\x95\x90" }        -- "─" / "═"
local LINE_CHAR_V = { single = "\xe2\x94\x82", double = "\xe2\x95\x91" }      -- "│" / "║"
local TAP_GLYPH = {
  line = { up = "\xe2\x96\xb2", down = "\xe2\x96\xbc", left = "\xe2\x97\x84", right = "\xe2\x96\xba" },   -- ▲▼◄►
  feeder = { up = "\xe2\x96\xb3", down = "\xe2\x96\xbd", left = "\xe2\x97\x81", right = "\xe2\x96\xb7" }, -- △▽◁▷
}

-- H=15 leaves interior rows 1..13 usable via dialogText/dialogButton's
-- `row` parameter (row R draws at screen y = dlg.y + 1 + R, and the
-- bottom border sits at dlg.y + DIALOG_H - 1) -- sas/hmi/engine.lua's
-- merged measurement+control dialog uses up to row 12.
local DIALOG_W, DIALOG_H = 44, 15

--- Lifecycle ------------------------------------------------------------

-- Opens the primary GPU context. Returns ctx, or nil, err if this
-- machine has no gpu component (mirrors sas/proto/netmsg.lua's own
-- "fails loudly, no retry loop" rule for a missing modem).
function render.open()
  if not component.isAvailable("gpu") then
    return nil, "no gpu component available on this machine"
  end
  local gpu = component.gpu
  local w, h = gpu.getResolution()
  return {
    gpu = gpu, width = w, height = h,
    defaultBg = gpu.getBackground(), defaultFg = gpu.getForeground(),
  }
end

-- Restores the terminal's original colors and clears the screen -- the
-- entry point (usr/bin/sas-hmi.lua) calls this on every exit path
-- (normal quit, Ctrl+C, or a caught error) so a crash never leaves the
-- terminal colored/garbled.
function render.close(ctx)
  ctx.gpu.setBackground(ctx.defaultBg)
  ctx.gpu.setForeground(ctx.defaultFg)
  ctx.gpu.fill(1, 1, ctx.width, ctx.height, " ")
end

function render.clear(ctx)
  ctx.gpu.setBackground(COLOR_BG)
  ctx.gpu.setForeground(COLOR_FG)
  ctx.gpu.fill(1, 1, ctx.width, ctx.height, " ")
end

--- Primitives ------------------------------------------------------------

-- Writes `str` at (x,y), clipped to the real screen bounds (a string
-- straddling the left/right edge is trimmed, not wrapped or erred on).
function render.text(ctx, x, y, fg, bg, str)
  if y < 1 or y > ctx.height or x > ctx.width or str == "" then return end
  local s, startX = str, x
  if startX < 1 then
    s = s:sub(2 - startX)
    startX = 1
  end
  local maxLen = ctx.width - startX + 1
  if maxLen <= 0 or s == "" then return end
  if #s > maxLen then s = s:sub(1, maxLen) end
  ctx.gpu.setForeground(fg)
  ctx.gpu.setBackground(bg)
  ctx.gpu.set(startX, y, s)
end

function render.hline(ctx, x, y, len, style)
  if y < 1 or y > ctx.height or len <= 0 then return end
  local x1, x2 = math.max(x, 1), math.min(x + len - 1, ctx.width)
  if x2 < x1 then return end
  ctx.gpu.setForeground(COLOR_FG)
  ctx.gpu.setBackground(COLOR_BG)
  ctx.gpu.fill(x1, y, x2 - x1 + 1, 1, LINE_CHAR[style] or LINE_CHAR.single)
end

function render.vline(ctx, x, y, len, style)
  if x < 1 or x > ctx.width or len <= 0 then return end
  local y1, y2 = math.max(y, 1), math.min(y + len - 1, ctx.height)
  if y2 < y1 then return end
  ctx.gpu.setForeground(COLOR_FG)
  ctx.gpu.setBackground(COLOR_BG)
  ctx.gpu.fill(x, y1, 1, y2 - y1 + 1, LINE_CHAR_V[style] or LINE_CHAR_V.single)
end

-- Draws a straight orthogonal run between two screen points (layout.lua
-- hands back plain x1,y1,x2,y2 endpoints for `segments`/
-- `transformerLinks`, without pre-classifying orientation -- every
-- segment scl/char_layout.py emits is purely horizontal or vertical by
-- construction, never diagonal).
function render.line(ctx, x1, y1, x2, y2, style)
  if y1 == y2 then
    render.hline(ctx, math.min(x1, x2), y1, math.abs(x2 - x1) + 1, style)
  elseif x1 == x2 then
    render.vline(ctx, x1, math.min(y1, y2), math.abs(y2 - y1) + 1, style)
  end
end

function render.tick(ctx, x, y, orientation)
  render.text(ctx, x, y, COLOR_DISCONNECT, COLOR_BG, (orientation == "h") and "\\" or "/")
end

-- kind = "line"|"feeder"|"transformer"|"unknown"; direction = "up"/
-- "down"/"left"/"right" (which way the tap's stub points, defaults
-- "down" -- matches this project's diagrams, where taps hang below their
-- breaker). See README.md's "GUI library"/diagram notes for why
-- "(T)" stands in for a transformer rather than attempting an
-- unverifiable-in-terminal double-circle glyph.
function render.tapSymbol(ctx, x, y, kind, direction)
  direction = direction or "down"
  if kind == "transformer" then
    render.text(ctx, x - 1, y, COLOR_TAP, COLOR_BG, "(T)")
  elseif kind == "line" or kind == "feeder" then
    local ch = (TAP_GLYPH[kind] or {})[direction]
    render.text(ctx, x, y, COLOR_TAP, COLOR_BG, ch or "o")
  else
    render.text(ctx, x, y, COLOR_TAP_UNKNOWN, COLOR_BG, "o")
  end
end

--- Composite widgets ------------------------------------------------------------

-- A breaker/disconnect status tile: "[label]", colored by the caller
-- (see this file's header on why status color is the caller's, not this
-- module's, concern). Returns its screen-space hit rect -- MUST match
-- sas/hmi/layout.lua's own `tileWidth` formula (#label + 2 for the
-- brackets), which is why layout.lua computes hit rects itself rather
-- than calling into this module (kept independent/pure, see that file's
-- header) -- both sides agree on the "[label]" format as a documented
-- contract, not a shared function.
function render.tile(ctx, x, y, label, bg, fg)
  local text = "[" .. label .. "]"
  render.text(ctx, x, y, fg, bg, text)
  return { x1 = x, y1 = y, x2 = x + #text - 1, y2 = y }
end

local function fmtNum(v)
  if type(v) ~= "number" then return "--" end
  return string.format("%.1f", v)
end

-- Compact 2-line summary near a breaker: phase currents A/B/C, then
-- phase-to-phase voltages AB/BC/CA (see README.md's 3-phase-per-point
-- data model -- MMXU1.AmpA/B/C + VolAB/BC/CA, never one combined
-- reading).
function render.measureReadout(ctx, x, y, ampA, ampB, ampC, volAB, volBC, volCA)
  render.text(ctx, x, y, COLOR_MEAS, COLOR_BG,
    string.format("A:%s/%s/%s", fmtNum(ampA), fmtNum(ampB), fmtNum(ampC)))
  render.text(ctx, x, y + 1, COLOR_MEAS, COLOR_BG,
    string.format("V:%s/%s/%s", fmtNum(volAB), fmtNum(volBC), fmtNum(volCA)))
end

function render.statusLine(ctx, text, fg, bg)
  bg = bg or COLOR_STATUS_BG
  ctx.gpu.setBackground(bg)
  ctx.gpu.fill(1, ctx.height, ctx.width, 1, " ")
  render.text(ctx, 1, ctx.height, fg or COLOR_STATUS_FG, bg, text)
end

--- Modal dialog ------------------------------------------------------------
--
-- No save/restore of what's underneath: sas/hmi/engine.lua always
-- triggers a full main-screen redraw immediately after dialogClose, so a
-- pixel-exact restore (O(dialog area) component.gpu.get calls -- a real
-- per-call cost in OpenComputers, for ~500 cells here) would just be
-- thrown away anyway. dialogClose stays a real function for API
-- symmetry/a documented hook, not because it does work today.

function render.dialogOpen(ctx, title)
  local x = math.floor((ctx.width - DIALOG_W) / 2) + 1
  local y = math.floor((ctx.height - DIALOG_H) / 2) + 1
  local dlg = { root = ctx, gpu = ctx.gpu, x = x, y = y, w = DIALOG_W, h = DIALOG_H }

  ctx.gpu.setBackground(COLOR_DIALOG_BG)
  ctx.gpu.setForeground(COLOR_DIALOG_FG)
  ctx.gpu.fill(x, y, DIALOG_W, DIALOG_H, " ")
  ctx.gpu.fill(x + 1, y, DIALOG_W - 2, 1, LINE_CHAR.single)
  ctx.gpu.fill(x + 1, y + DIALOG_H - 1, DIALOG_W - 2, 1, LINE_CHAR.single)
  ctx.gpu.fill(x, y + 1, 1, DIALOG_H - 2, LINE_CHAR_V.single)
  ctx.gpu.fill(x + DIALOG_W - 1, y + 1, 1, DIALOG_H - 2, LINE_CHAR_V.single)
  ctx.gpu.set(x, y, "\xe2\x94\x8c")                       -- ┌
  ctx.gpu.set(x + DIALOG_W - 1, y, "\xe2\x94\x90")         -- ┐
  ctx.gpu.set(x, y + DIALOG_H - 1, "\xe2\x94\x94")         -- └
  ctx.gpu.set(x + DIALOG_W - 1, y + DIALOG_H - 1, "\xe2\x94\x98")  -- ┘

  if title then
    local t = " " .. title .. " "
    render.text(ctx, x + math.floor((DIALOG_W - #t) / 2), y, COLOR_DIALOG_FG, COLOR_DIALOG_BG, t)
  end
  return dlg
end

-- `row` is 1-based, relative to the dialog's interior (below the title
-- bar, inside the border).
function render.dialogText(dlg, row, str, fg)
  render.text(dlg.root, dlg.x + 2, dlg.y + 1 + row, fg or COLOR_DIALOG_FG, COLOR_DIALOG_BG, str)
end

function render.dialogButton(dlg, row, label, enabled, bg, fg)
  local text = "[" .. label .. "]"
  local bx, by = dlg.x + 2, dlg.y + 1 + row
  local useBg = enabled and (bg or COLOR_BTN_BG) or COLOR_BTN_DISABLED_BG
  local useFg = enabled and (fg or COLOR_BTN_FG) or COLOR_BTN_DISABLED_FG
  render.text(dlg.root, bx, by, useFg, useBg, text)
  return { x1 = bx, y1 = by, x2 = bx + #text - 1, y2 = by, enabled = enabled }
end

function render.dialogClose(_dlg)
  -- see this section's header -- deliberately a no-op.
end

--- Alarm panel ------------------------------------------------------------

-- One alarm row; if `ackable`, also draws an "[Ack]" button at the row's
-- right edge and returns its hit rect (nil otherwise -- an already-acked
-- alarm has nothing to click).
function render.alarmRow(ctx, x, y, w, severityColor, text, ackable)
  local ackLabel = "[Ack]"
  local textW = ackable and (w - #ackLabel - 1) or w
  render.text(ctx, x, y, severityColor, COLOR_BG, text:sub(1, textW))
  if not ackable then return nil end
  local bx = x + w - #ackLabel
  render.text(ctx, bx, y, COLOR_BTN_FG, COLOR_BTN_BG, ackLabel)
  return { x1 = bx, y1 = y, x2 = bx + #ackLabel - 1, y2 = y }
end

-- Small pan-position hint, shown only when the compiled diagram is
-- larger than the current viewport in some direction.
function render.viewportIndicator(ctx, panX, panY, diagramW, diagramH, viewW, viewH)
  if diagramW <= viewW and diagramH <= viewH then return end
  local text = string.format("[pan %d,%d of %dx%d -- arrows to scroll]", panX, panY, diagramW, diagramH)
  render.text(ctx, ctx.width - #text, ctx.height, COLOR_STATUS_FG, COLOR_STATUS_BG, text)
end

return render
