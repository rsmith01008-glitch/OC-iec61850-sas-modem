-- sas.sbo: select-before-operate reservation state machine, matching IEC
-- 61850's SBO control model (simplified -- no cryptographic guarantees,
-- which is an acceptable non-goal on a trusted local network, the same
-- call OC-IP-Stack itself makes for its TCP initial sequence numbers).
--
-- Only the IED that owns the physical output runs a Manager -- SCADA is a
-- stateless relay for select/operate/cancel (see sas/scada/engine.lua),
-- so there is exactly one authoritative copy of "who has this point
-- reserved" and it can never drift out of sync with the machine that
-- actually drives the redstone output.
local computer = require("computer")

local sbo = {}

local Mgr = {}
Mgr.__index = Mgr

function sbo.new()
  return setmetatable({ reservations = {} }, Mgr) -- [ref] = {clientId=, token=, expiresAt=}
end

local function newToken(ref)
  return ref .. ":" .. tostring(computer.uptime()) .. ":" .. tostring(math.random(1, 1000000))
end

-- Reserves `ref` for `clientId`. Returns token, or nil, err if already
-- reserved by a different, not-yet-expired client.
function Mgr:select(ref, clientId, timeoutSec, now)
  local existing = self.reservations[ref]
  if existing and existing.expiresAt > now and existing.clientId ~= clientId then
    return nil, "already selected by another client"
  end

  local token = newToken(ref)
  self.reservations[ref] = {
    clientId = clientId,
    token = token,
    expiresAt = now + (timeoutSec or 30),
  }
  return token
end

-- Validates token+clientId+not-expired for `ref` and, if valid, clears
-- the reservation. Returns true, or nil, err. Caller (the IED engine)
-- must only apply the physical output after this returns true.
function Mgr:operate(ref, token, clientId, now)
  local r = self.reservations[ref]
  if not r then return nil, "no active selection for this point" end
  if r.expiresAt <= now then
    self.reservations[ref] = nil
    return nil, "selection expired"
  end
  if r.token ~= token or r.clientId ~= clientId then
    return nil, "selection token/client mismatch"
  end
  self.reservations[ref] = nil
  return true
end

-- Explicitly releases a reservation before it expires. Returns true, or
-- nil, err.
function Mgr:cancel(ref, token, clientId, now)
  local r = self.reservations[ref]
  if not r then return true end -- already gone; cancel is idempotent
  if r.token ~= token or r.clientId ~= clientId then
    return nil, "selection token/client mismatch"
  end
  self.reservations[ref] = nil
  return true
end

-- Called every IED tick to expire reservations nobody operated in time.
function Mgr:tick(now)
  for ref, r in pairs(self.reservations) do
    if r.expiresAt <= now then
      self.reservations[ref] = nil
    end
  end
end

function Mgr:isReserved(ref, now)
  local r = self.reservations[ref]
  return r ~= nil and r.expiresAt > now
end

sbo.Mgr = Mgr

return sbo
