-- sas-hmi: full-screen OpenOS terminal HMI. Thin over sas.hmi.engine, like
-- rc.d/scadad.lua is thin over sas.scada.engine, except this owns its own
-- event loop directly -- there's no rc.d/event.timer owner for a
-- foreground, interactive program. Install via oppm (oc-sas-hmi); see
-- README.md's "Install (OpenOS: HMI node)" section.
local event = require("event")

local engine = require("sas.hmi.engine")

local ok, startErr = engine.start()
if not ok then
  io.stderr:write("sas-hmi: failed to start: " .. tostring(startErr) .. "\n")
  return 1
end

-- Every exit path -- clean quit ("q"), Ctrl+C (which OpenOS delivers as a
-- *thrown* Lua error from event.pull, message "interrupted", never as a
-- normal ("interrupted", ...) signal tuple -- see sas/hmi/engine.lua's own
-- handleEvent comment), or any other error -- must still restore the
-- terminal via engine.stop() (render.close()). pcall around the whole loop
-- guarantees that regardless of which path triggers it.
local runOk, runErr = pcall(function()
  while engine.isRunning() do
    local pollSec = (engine.state.cfg and engine.state.cfg.pollIntervalSec) or 0.5
    local sig, addr, arg1, arg2, arg3 = event.pull(pollSec)
    if sig == nil then
      engine.tick()
    else
      engine.handleEvent(sig, addr, arg1, arg2, arg3)
    end
  end
end)

engine.stop()

if not runOk and runErr ~= "interrupted" then
  io.stderr:write("sas-hmi: " .. tostring(runErr) .. "\n")
  return 1
end
