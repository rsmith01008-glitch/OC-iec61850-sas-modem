-- sas.proto.discovery: name -> (modem address, service port) resolution.
--
-- OC-IP-Stack gave every node a small hand-assigned "subnet.host" address
-- a peer could just be configured with directly. A built-in OpenComputers
-- modem's own address is a game-assigned UUID with no such friendliness,
-- and can change outright if a modem is ever broken/replaced -- so instead
-- of hand-configuring addresses, every node that wants to be reachable by
-- name (an IED by its `iedName`, SCADA by its own configured name)
-- advertises that name here, and a client resolves it at runtime with a
-- broadcast "who-is" query answered directly by whichever node owns it.
-- One shared well-known port for this, not user-configurable -- keeping
-- one less thing to get wrong/mismatched across a station's .cfg files.
local netmsg = require("sas.proto.netmsg")

local discovery = {}

discovery.PORT = 8100

-- How long a resolved (address, port) is trusted before a fresh query is
-- required -- long enough that a steady-state client essentially never
-- re-queries, short enough that a swapped modem's new address is picked
-- up within one reconnect cycle.
discovery.CACHE_TTL_SEC = 120
-- Minimum gap between repeat "who-is" broadcasts for the same name, so a
-- caller that asks every tick while unresolved doesn't flood the network.
discovery.QUERY_INTERVAL_SEC = 2

local registered = {}   -- [name] = servicePort -- names THIS node answers for
local cache = {}         -- [name] = { address=, port=, resolvedAt= }
local lastQueryAt = {}   -- [name] = uptime of the last broadcast query sent

-- Registers `name` as reachable on `servicePort` on THIS node -- answered
-- automatically the next time discovery.tick() sees a matching "who-is".
function discovery.advertise(name, servicePort)
  registered[name] = servicePort
end

-- Fire-and-forget: broadcasts a "who-is" query for `name`, rate-limited to
-- at most one per QUERY_INTERVAL_SEC per name so a caller can safely call
-- this every tick while waiting on a resolution.
function discovery.request(name, now)
  local last = lastQueryAt[name]
  if last and (now - last) < discovery.QUERY_INTERVAL_SEC then return end
  lastQueryAt[name] = now
  netmsg.broadcast(discovery.PORT, { type = "who-is", name = name })
end

-- Returns address, port for `name` if a still-fresh resolution is cached,
-- else nil.
function discovery.lookup(name, now)
  local e = cache[name]
  if e and (now - e.resolvedAt) < discovery.CACHE_TTL_SEC then
    return e.address, e.port
  end
  return nil
end

-- Must be called once per tick by every node that either advertises a
-- name (to answer queries) or resolves one (to receive replies) --
-- opens/drains the shared discovery port and updates `cache`/answers
-- "who-is" queries matching `registered`.
function discovery.tick(now)
  local ok = netmsg.open(discovery.PORT)
  if not ok then return end

  for _, item in ipairs(netmsg.drain(discovery.PORT)) do
    local msg = item.data
    if msg.type == "who-is" and type(msg.name) == "string" and registered[msg.name] then
      netmsg.send(item.from, discovery.PORT, {
        type = "who-is-reply", name = msg.name, port = registered[msg.name],
      })
    elseif msg.type == "who-is-reply" and type(msg.name) == "string" and type(msg.port) == "number" then
      cache[msg.name] = { address = item.from, port = msg.port, resolvedAt = now }
    end
  end
end

return discovery
