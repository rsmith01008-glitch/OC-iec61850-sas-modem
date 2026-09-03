-- sas.util: small shared helpers, currently just the ring-buffer logger
-- pattern established by OC-IP-Stack's ipstack.util.makeLogger (kept as a
-- separate copy here, not a dependency on the ipstack.* namespace, so
-- sas/ stays cleanly layered on top of ipstack.socket only).
local computer = require("computer")

local util = {}

function util.makeLogger(sink, ringSize)
  ringSize = ringSize or 200
  return function(level, fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = fmt end
    table.insert(sink, {
      time = computer.uptime(),
      level = level,
      message = msg,
    })
    while #sink > ringSize do
      table.remove(sink, 1)
    end
  end
end

function util.countTable(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

return util
