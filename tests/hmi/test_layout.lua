-- tests/hmi/test_layout.lua: executable unit test for sas.hmi.layout,
-- runnable with plain `lua5.3` (zero OC-API coupling by design -- this
-- is the one HMI module with no `component`/`event` dependency at all).
-- Run from the repo root:
--   lua5.3 tests/hmi/test_layout.lua
-- Exits non-zero on any assertion failure.
package.path = "./?.lua;" .. package.path
local layout = require("sas.hmi.layout")

local failures = 0
local function check(cond, label)
  if cond then
    print("ok:   " .. label)
  else
    failures = failures + 1
    print("FAIL: " .. label)
  end
end

-- A small fake diagram: one bus, two breakers on a diameter, one tap,
-- matching the shape scl/char_layout.py's build_diagram actually
-- produces (see tools/scl-compiler/tests/test_char_layout.py for the
-- Python-side equivalent of this same shape).
local diagram = {
  width = 40, height = 20,
  buses = { { id = "bus1", label = "800kV Bus A", x1 = 0, y1 = 0, x2 = 20, y2 = 0, orientation = "h" } },
  breakers = {
    { id = "CB1", label = "CB1", x = 4, y = 2,
      statusFullRef = "CB1/LD0/XCBR1.Pos", controlFullRef = "CB1/LD0/XCBR1.PosCtl",
      measFullRefBase = "CB1/LD0/MMXU1" },
    { id = "CB2", label = "CB2", x = 4, y = 10,
      statusFullRef = "CB2/LD0/XCBR1.Pos", controlFullRef = "CB2/LD0/XCBR1.PosCtl",
      measFullRefBase = "CB2/LD0/MMXU1" },
  },
  disconnects = {},
  taps = { { id = "n1", kind = "line", label = "Line1", x = 4, y = 6 } },
  segments = { { x1 = 4, y1 = 0, x2 = 4, y2 = 2 }, { x1 = 4, y1 = 2, x2 = 4, y2 = 6 } },
  transformerLinks = {},
}

--- buildFrame: pan shifts screen coordinates -----------------------------------------------------------

local vp0 = { panX = 0, panY = 0, viewW = 40, viewH = 20 }
local frame0 = layout.buildFrame(diagram, vp0)
local cb1_0 = frame0.tiles[1]
check(cb1_0 ~= nil and cb1_0.id == "CB1", "CB1 present with panX=panY=0")
check(cb1_0.x == 5 and cb1_0.y == 3, "screen coords are diagram coords + 1 (1-based) with no pan (got x=" .. tostring(cb1_0.x) .. " y=" .. tostring(cb1_0.y) .. ")")

local vp1 = { panX = 2, panY = 1, viewW = 40, viewH = 20 }
local frame1 = layout.buildFrame(diagram, vp1)
local cb1_1 = frame1.tiles[1]
check(cb1_1.x == cb1_0.x - 2 and cb1_1.y == cb1_0.y - 1, "panning by (2,1) shifts screen coords by (-2,-1)")

--- buildFrame: viewport clipping -----------------------------------------------------------

local vpNarrow = { panX = 0, panY = 0, viewW = 3, viewH = 20 }  -- CB1/CB2 sit at diagram x=4, outside a 3-wide view
local frameNarrow = layout.buildFrame(diagram, vpNarrow)
check(#frameNarrow.tiles == 0, "breakers outside a narrow viewport are dropped")
check(#frameNarrow.buses == 1, "the bus (x1=0..20) still overlaps a 3-wide viewport starting at x=0")

--- hitTest: exact tile, near-miss, and empty space -----------------------------------------------------------

local kind, id = layout.hitTest(frame0, cb1_0.hitRect.x1, cb1_0.hitRect.y1)
check(kind == "breaker" and id == "CB1", "click on CB1's top-left corner hits CB1")

kind, id = layout.hitTest(frame0, cb1_0.hitRect.x2, cb1_0.hitRect.y1)
check(kind == "breaker" and id == "CB1", "click on CB1's rendered-width right edge (label wrapped in brackets) still hits CB1")

kind, id = layout.hitTest(frame0, cb1_0.hitRect.x1, cb1_0.hitRect.y1 + 1)
check(kind == nil, "click one row below CB1's tile hits nothing")

kind, id = layout.hitTest(frame0, 1, 1)
check(kind == nil, "click on empty space (screen 1,1) hits nothing")

local cb2 = frame0.tiles[2]
kind, id = layout.hitTest(frame0, cb2.hitRect.x1, cb2.hitRect.y1)
check(kind == "breaker" and id == "CB2", "click on CB2 hits CB2, not CB1")

local tap = frame0.taps[1]
kind, id = layout.hitTest(frame0, tap.hitRect.x1, tap.hitRect.y1)
check(kind == "tap" and id == "n1", "click on the tap symbol hits the tap")

--- panClamp -----------------------------------------------------------

local clamped = layout.panClamp({ panX = 1000, panY = 1000, viewW = 40, viewH = 20 }, diagram)
check(clamped.panX == 0 and clamped.panY == 0,
  "panClamp clamps to 0 when the diagram fits entirely within the viewport (got " .. clamped.panX .. "," .. clamped.panY .. ")")

local bigDiagram = { width = 200, height = 100 }
local clamped2 = layout.panClamp({ panX = 1000, panY = 1000, viewW = 40, viewH = 20 }, bigDiagram)
check(clamped2.panX == 160 and clamped2.panY == 80,
  "panClamp clamps to (width-viewW, height-viewH) when over-panned (got " .. clamped2.panX .. "," .. clamped2.panY .. ")")

local clamped3 = layout.panClamp({ panX = -5, panY = -5, viewW = 40, viewH = 20 }, bigDiagram)
check(clamped3.panX == 0 and clamped3.panY == 0, "panClamp never returns a negative pan")

if failures > 0 then
  print(string.format("\n%d assertion(s) FAILED", failures))
  os.exit(1)
end
print("\nall assertions passed")
