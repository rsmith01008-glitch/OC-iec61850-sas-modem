-- sas.hmi.layout: pure viewport/hit-test math over a compiled `diagram`
-- table (see scl/char_layout.py's build_diagram -- this module is the
-- Lua-side consumer of that exact shape, passed through unchanged on
-- SCADA's get-model-reply). Deliberately has NO `component`/`event`
-- dependency at all -- everything here is plain table/arithmetic code,
-- which is what makes it testable with plain `lua5.3`
-- (tests/hmi/test_layout.lua), unlike sas/hmi/render.lua (the only
-- module that actually touches component.gpu).
--
-- Diagram-space coordinates (as compiled) are 0-based small integers;
-- screen-space coordinates (as produced here) are 1-based, matching
-- OpenComputers' own gpu.set/fill convention, and already shifted by the
-- viewport's pan -- sas/hmi/render.lua does no further translation, only
-- per-character bounds clamping against the actual screen resolution
-- (which this module doesn't need to know, only the caller-supplied
-- `viewW`/`viewH` -- kept separate from the real GPU resolution so this
-- stays testable without one).
local layout = {}

-- A breaker/disconnect tile renders as "[label]" (see
-- sas/hmi/render.lua's `tile`) -- both modules agree on this format, but
-- layout.lua needs the rendered width itself to compute a hit-rect, so
-- the +2 (brackets) is duplicated here rather than introducing a
-- render<->layout dependency for one small formula.
local function tileWidth(label)
  return #label + 2
end

local function toScreen(x, y, viewport)
  return x - viewport.panX + 1, y - viewport.panY + 1
end

-- True if the (inclusive) diagram-space rect [x1,y1]-[x2,y2] overlaps the
-- viewport's currently visible diagram-space window at all.
local function rectVisible(x1, y1, x2, y2, viewport)
  local vx2, vy2 = viewport.panX + viewport.viewW - 1, viewport.panY + viewport.viewH - 1
  return x2 >= viewport.panX and x1 <= vx2 and y2 >= viewport.panY and y1 <= vy2
end

-- Builds a screen-space draw frame: every diagram element whose
-- bounding box overlaps the current viewport, translated to screen
-- coordinates. Elements entirely outside the viewport are dropped
-- (render.lua still defensively clamps per-character against the real
-- screen resolution, since a tile/label can straddle the viewport edge).
function layout.buildFrame(diagram, viewport)
  local frame = { buses = {}, segments = {}, transformerLinks = {}, tiles = {}, disconnects = {}, taps = {} }
  if not diagram then return frame end

  local nodeXY = {}  -- diagram-space id -> {x,y}, for resolving transformerLinks below
  for _, t in ipairs(diagram.taps or {}) do
    nodeXY[t.id] = { x = t.x, y = t.y }
  end

  for _, b in ipairs(diagram.buses or {}) do
    if rectVisible(math.min(b.x1, b.x2), math.min(b.y1, b.y2), math.max(b.x1, b.x2), math.max(b.y1, b.y2), viewport) then
      local sx1, sy1 = toScreen(b.x1, b.y1, viewport)
      local sx2, sy2 = toScreen(b.x2, b.y2, viewport)
      table.insert(frame.buses, {
        id = b.id, label = b.label, orientation = b.orientation, x1 = sx1, y1 = sy1, x2 = sx2, y2 = sy2,
      })
    end
  end

  for _, s in ipairs(diagram.segments or {}) do
    if rectVisible(math.min(s.x1, s.x2), math.min(s.y1, s.y2), math.max(s.x1, s.x2), math.max(s.y1, s.y2), viewport) then
      local sx1, sy1 = toScreen(s.x1, s.y1, viewport)
      local sx2, sy2 = toScreen(s.x2, s.y2, viewport)
      table.insert(frame.segments, { x1 = sx1, y1 = sy1, x2 = sx2, y2 = sy2 })
    end
  end

  for _, link in ipairs(diagram.transformerLinks or {}) do
    local hv, lv = nodeXY[link.hvTapId], nodeXY[link.lvTapId]
    if hv and lv then
      local x1, y1, x2, y2 = hv.x, hv.y, lv.x, lv.y
      if rectVisible(math.min(x1, x2), math.min(y1, y2), math.max(x1, x2), math.max(y1, y2), viewport) then
        local sx1, sy1 = toScreen(x1, y1, viewport)
        local sx2, sy2 = toScreen(x2, y2, viewport)
        table.insert(frame.transformerLinks, { name = link.name, x1 = sx1, y1 = sy1, x2 = sx2, y2 = sy2 })
      end
    end
  end

  for _, brk in ipairs(diagram.breakers or {}) do
    local w = tileWidth(brk.label)
    if rectVisible(brk.x, brk.y, brk.x + w - 1, brk.y, viewport) then
      local sx, sy = toScreen(brk.x, brk.y, viewport)
      table.insert(frame.tiles, {
        kind = "breaker", id = brk.id, label = brk.label, x = sx, y = sy,
        statusFullRef = brk.statusFullRef, controlFullRef = brk.controlFullRef,
        measFullRefBase = brk.measFullRefBase,
        hitRect = { x1 = sx, y1 = sy, x2 = sx + w - 1, y2 = sy },
      })
    end
  end

  for _, d in ipairs(diagram.disconnects or {}) do
    if rectVisible(d.x, d.y, d.x, d.y, viewport) then
      local sx, sy = toScreen(d.x, d.y, viewport)
      table.insert(frame.disconnects, {
        kind = "disconnect", id = d.id, orientation = d.orientation, x = sx, y = sy,
        hitRect = { x1 = sx, y1 = sy, x2 = sx, y2 = sy },
      })
    end
  end

  for _, t in ipairs(diagram.taps or {}) do
    if rectVisible(t.x, t.y, t.x, t.y, viewport) then
      local sx, sy = toScreen(t.x, t.y, viewport)
      table.insert(frame.taps, {
        kind = "tap", id = t.id, tapKind = t.kind, label = t.label, x = sx, y = sy,
        hitRect = { x1 = sx, y1 = sy, x2 = sx, y2 = sy },
      })
    end
  end

  return frame
end

local function hitRectAt(items, screenX, screenY)
  for _, item in ipairs(items) do
    local r = item.hitRect
    if r and screenX >= r.x1 and screenX <= r.x2 and screenY >= r.y1 and screenY <= r.y2 then
      return item
    end
  end
  return nil
end

-- Returns kind, id for whichever interactive element (in priority order:
-- breaker tiles, then taps, then disconnects) occupies screen-space
-- (screenX, screenY), or nil if none does.
function layout.hitTest(frame, screenX, screenY)
  local hit = hitRectAt(frame.tiles, screenX, screenY)
    or hitRectAt(frame.taps, screenX, screenY)
    or hitRectAt(frame.disconnects, screenX, screenY)
  if not hit then return nil end
  return hit.kind, hit.id
end

-- Keeps `viewport.panX`/`panY` within [0, diagram.width-viewW] /
-- [0, diagram.height-viewH] (0 when the diagram is smaller than the
-- viewport in that axis -- nothing to pan). Returns a fresh viewport
-- table; does not mutate the argument.
function layout.panClamp(viewport, diagram)
  local maxPanX = math.max(0, (diagram.width or 0) - viewport.viewW)
  local maxPanY = math.max(0, (diagram.height or 0) - viewport.viewH)
  return {
    panX = math.min(math.max(0, viewport.panX), maxPanX),
    panY = math.min(math.max(0, viewport.panY), maxPanY),
    viewW = viewport.viewW,
    viewH = viewport.viewH,
  }
end

return layout
