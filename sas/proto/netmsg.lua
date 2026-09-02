-- sas.proto.netmsg: thin wrapper over OpenComputers' built-in modem
-- component (component.modem.send/broadcast + the "modem_message" event),
-- replacing OC-IP-Stack's TCP/multicast sockets as this codebase's only
-- transport primitive. A modem message is already one discrete unit (no
-- stream framing needed, unlike TCP), so every message here is one Lua
-- table, serialized/deserialized whole via OpenOS's `serialization`
-- library -- same wire idiom sas.proto.framing and sas.proto.goose used
-- before, just without the length-prefix stream-reassembly framing.lua
-- existed for (deleted -- no longer needed).
--
-- Two read primitives, because a single physical modem port can be shared
-- by several logical readers on one node (e.g. SCADA polling several IED
-- Clients that all happen to use the same configured mms.port):
--   netmsg.drain(port)         -- SERVER use: take every queued message.
--   netmsg.take(port, address) -- CLIENT use: take only messages from one
--                                  known peer, leaving the rest queued for
--                                  other readers of the same port.
--
-- Modem messages have no delivery guarantee (a wireless peer out of range,
-- or a dropped signal, simply never arrives) and no "connection" concept
-- at all -- reliability (timeout/retry) is layered on top of this by
-- sas.proto.mmsclient, not here; this module is deliberately as dumb as
-- ipstack.socket's own transport-only layering, one level lower.
local component = require("component")
local event = require("event")
local serialization = require("serialization")

local netmsg = {}

-- Comfortably under OpenComputers' default (unupgraded) modem packet cap
-- (8192 bytes) -- guards a malformed/hostile payload from ever being built
-- in the first place, same role sas.proto.framing.MAX_FRAME_SIZE played.
netmsg.MAX_MESSAGE_SIZE = 8192

local queues = {}       -- [port] = array of { from = address, data = msgTable }
local modem = nil
local listenerId = nil

local function ensureModem()
  if modem then return modem end
  local addr = component.list("modem")()
  if not addr then return nil, "no modem component found on this machine" end
  modem = component.proxy(addr)
  return modem
end

local function onModemMessage(_signal, _localAddr, remoteAddr, port, _distance, wire)
  local q = queues[port]
  if not q or type(wire) ~= "string" then return end
  local ok, msg = pcall(serialization.unserialize, wire)
  if ok and type(msg) == "table" then
    table.insert(q, { from = remoteAddr, data = msg })
  end
end

-- Opens `port` for receiving (idempotent -- safe to call every tick, or
-- from several modules that both care about the same port). Returns true,
-- or nil, err if this machine has no modem component at all.
function netmsg.open(port)
  local m, err = ensureModem()
  if not m then return nil, err end
  if not queues[port] then queues[port] = {} end
  if not listenerId then
    listenerId = event.listen("modem_message", onModemMessage)
  end
  if not m.isOpen(port) then
    local ok, oerr = m.open(port)
    if not ok then return nil, oerr end
  end
  return true
end

function netmsg.close(port)
  queues[port] = nil
  if modem then pcall(function() modem.close(port) end) end
end

-- This machine's own modem address (the value a peer sees as `from`).
-- Returns nil, err if there is no modem component.
function netmsg.address()
  local m, err = ensureModem()
  if not m then return nil, err end
  return m.address
end

function netmsg.send(address, port, msgTable)
  local m, err = ensureModem()
  if not m then return nil, err end
  local wire = serialization.serialize(msgTable)
  if #wire > netmsg.MAX_MESSAGE_SIZE then
    return nil, "message too large to send (" .. #wire .. " > " .. netmsg.MAX_MESSAGE_SIZE .. " bytes)"
  end
  return m.send(address, port, wire)
end

function netmsg.broadcast(port, msgTable)
  local m, err = ensureModem()
  if not m then return nil, err end
  local wire = serialization.serialize(msgTable)
  if #wire > netmsg.MAX_MESSAGE_SIZE then
    return nil, "message too large to broadcast (" .. #wire .. " > " .. netmsg.MAX_MESSAGE_SIZE .. " bytes)"
  end
  return m.broadcast(port, wire)
end

-- SERVER read: returns and clears every message queued on `port` since
-- the last drain, regardless of sender. Used where the set of peers isn't
-- known in advance (an IED's mms.port serving whichever SCADA talks to
-- it, SCADA's hms.port serving whichever HMI connects, either goose.port
-- subscriber).
function netmsg.drain(port)
  local q = queues[port]
  if not q or #q == 0 then return {} end
  queues[port] = {}
  return q
end

-- CLIENT read: returns and removes only the messages from `address`,
-- leaving anything from other senders queued for their own take()/drain()
-- calls. Used by sas.proto.mmsclient.Client, since several Client objects
-- on one node (e.g. SCADA's one per configured IED) may share one
-- physical port number.
function netmsg.take(port, address)
  local q = queues[port]
  if not q or #q == 0 then return {} end
  local taken, kept = {}, {}
  for _, item in ipairs(q) do
    if item.from == address then
      table.insert(taken, item)
    else
      table.insert(kept, item)
    end
  end
  queues[port] = kept
  return taken
end

return netmsg
