-- sas.proto.mmsclient: shared non-blocking MMS-lite client, used both by
-- sas/scada/engine.lua (talking to IEDs) and the HMI (talking to SCADA)
-- -- same role, different peer.
--
-- Unlike OC-IP-Stack's TCP, a modem has no connection/stream: every
-- request is one fire-and-forget datagram (sas.proto.netmsg), with no
-- delivery guarantee. What used to be "read whatever's arrived on this
-- socket" is now netmsg.take(port, peerAddress) -- CLIENT-side reads, so
-- several Client objects sharing one physical port on this node (e.g.
-- SCADA's one Client per configured IED, several of which may resolve to
-- the same mms.port) don't steal each other's replies (see
-- sas.proto.netmsg's header). The reliability TCP gave for free -- "the
-- other side will eventually get this, or I'll know it didn't" -- is
-- reimplemented here instead: sendRequest tracks each pending request's
-- age, poll() resends it after retryIntervalSec, and gives up (marking
-- the client disconnected) after maxRetries -- at which point the caller
-- (sas.scada.engine's tickIeds, or the HMI) reconnects the same way it
-- always did on a TCP failure.
local netmsg = require("sas.proto.netmsg")
local discovery = require("sas.proto.discovery")
local messages = require("sas.proto.messages")

local mmsclient = {}

local Client = {}
Client.__index = Client

local DEFAULT_RETRY_INTERVAL_SEC = 2
local DEFAULT_MAX_RETRIES = 3

-- Resolves `targetName` (blocking up to timeoutSec, since this only
-- happens at startup/reconnect, never inside a tick -- same discipline
-- OC-IP-Stack's own socket.connect had here) via sas.proto.discovery,
-- then opens the port it announced. Returns a Client, or nil, err if
-- `targetName` never answered a "who-is" within timeoutSec.
function mmsclient.connect(targetName, timeoutSec)
  timeoutSec = timeoutSec or 10
  local deadline = computer.uptime() + timeoutSec

  local address, port
  repeat
    local now = computer.uptime()
    discovery.tick(now)
    discovery.request(targetName, now)
    address, port = discovery.lookup(targetName, now)
    if address then break end
    os.sleep(0.1)
  until computer.uptime() >= deadline

  if not address then
    return nil, "could not resolve '" .. targetName .. "' (no discovery reply within " .. timeoutSec .. "s)"
  end

  local ok, err = netmsg.open(port)
  if not ok then return nil, err end

  return setmetatable({
    targetName = targetName,
    address = address,
    port = port,
    nextId = 1,
    pending = {},   -- [id] = { msg=, sentAt=, retries= } while awaiting a reply
    replies = {},   -- [id] = replyMsg, once arrived (popped by popReply)
    inbox = {},     -- queued unsolicited pushes (report/alarm-update)
    connected = true,
    lastError = nil,
    retryIntervalSec = DEFAULT_RETRY_INTERVAL_SEC,
    maxRetries = DEFAULT_MAX_RETRIES,
  }, Client)
end

function Client:isConnected()
  return self.connected == true
end

-- Encodes and sends one request, assigning it a fresh id for reply
-- correlation. Returns the id, or nil, err.
function Client:sendRequest(msgWithoutId)
  local msg = {}
  for k, v in pairs(msgWithoutId) do msg[k] = v end
  msg.id = self.nextId
  self.nextId = self.nextId + 1

  local ok, err = netmsg.send(self.address, self.port, msg)
  if not ok then
    self.connected = false
    self.lastError = err
    return nil, err
  end
  self.pending[msg.id] = { msg = msg, sentAt = computer.uptime(), retries = 0 }
  return msg.id
end

function Client:dispatch(msg)
  if messages.isReply(msg) and msg.id ~= nil then
    self.replies[msg.id] = msg
    self.pending[msg.id] = nil
  elseif messages.isPush(msg) then
    table.insert(self.inbox, msg)
  end
  -- Anything else (malformed/unknown type) is silently dropped -- a
  -- future protocol version's client talking to an older peer, or vice
  -- versa, should degrade gracefully rather than error out.
end

-- Non-blocking: drains whatever this peer has sent since the last call,
-- decodes/dispatches it, and resends any request that's gone
-- unanswered past retryIntervalSec -- up to maxRetries, after which the
-- client is marked disconnected (caller should reconnect). Call this once
-- per tick/GUI-poll cycle. Returns true, or nil, err if the peer is
-- considered unreachable.
function Client:poll(now)
  if not self.connected then return nil, self.lastError or "not connected" end
  now = now or computer.uptime()

  for _, item in ipairs(netmsg.take(self.port, self.address)) do
    self:dispatch(item.data)
  end

  for id, p in pairs(self.pending) do
    if (now - p.sentAt) >= self.retryIntervalSec then
      if p.retries >= self.maxRetries then
        self.connected = false
        self.lastError = "no reply to request " .. tostring(id) .. " after " .. self.maxRetries .. " retries"
        return nil, self.lastError
      end
      netmsg.send(self.address, self.port, p.msg)
      p.retries = p.retries + 1
      p.sentAt = now
    end
  end

  return true
end

-- Non-blocking: returns and clears the reply for `id` if it has arrived,
-- else nil.
function Client:popReply(id)
  local r = self.replies[id]
  if r then self.replies[id] = nil end
  return r
end

function Client:hasPending(id)
  return self.pending[id] ~= nil
end

-- Non-blocking: returns and clears all queued unsolicited pushes.
function Client:drainInbox()
  local items = self.inbox
  self.inbox = {}
  return items
end

-- Blocking convenience: send a request and wait (polling + os.sleep)
-- up to timeoutSec for its reply. ONLY for foreground/manual use
-- (usr/bin/sas-ctl.lua, the MineOS HMI's startup handshake) -- never call
-- this from inside a daemon tick, which must stay non-blocking end to end.
function Client:request(msg, timeoutSec)
  timeoutSec = timeoutSec or 10
  local id, err = self:sendRequest(msg)
  if not id then return nil, err end

  local deadline = computer.uptime() + timeoutSec
  while computer.uptime() < deadline do
    local ok, perr = self:poll()
    if not ok then return nil, perr end
    local reply = self:popReply(id)
    if reply then return reply end
    os.sleep(0.1)
  end
  return nil, "timeout"
end

-- No underlying connection to tear down (modem ports stay open, shared
-- across every Client that resolved to the same port on this node) --
-- this just stops the client from polling/retrying.
function Client:close()
  self.connected = false
  return true
end

mmsclient.Client = Client

return mmsclient
