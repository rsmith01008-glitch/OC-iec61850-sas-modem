-- sas.ied.engine: the generic, config-driven IED. Same daemon skeleton as
-- OC-IP-Stack's own ipstack.daemon (see that file's comments): start()
-- registers an event.timer tick callback and returns immediately;
-- tick() itself must stay entirely non-blocking (no os.sleep, no
-- timeoutSec>0 ipstack.socket call), matching daemon.lua's safeTick.
local event = require("event")
local computer = require("computer")
local netmsg = require("sas.proto.netmsg")
local discovery = require("sas.proto.discovery")

local config = require("sas.config")
local model = require("sas.model")
local messages = require("sas.proto.messages")
local goose = require("sas.proto.goose")
local sbo = require("sas.sbo")
local io_rs = require("sas.io.redstone")
local meter = require("sas.io.meter")
local util = require("sas.util")
local ptocmod = require("sas.protection.ptoc")
local pdifmod = require("sas.protection.pdif")
local pdismod = require("sas.protection.pdis")

local engine = {}

local CFG_PATH = "/etc/sas-ied.cfg"

local DEFAULTS = {
  iedName = "IED1",
  logicalDevice = "LD0",
  mms = { port = 8102 },
  goose = { port = 8104, burstIntervalsSec = { 0.2, 0.5, 1, 2 }, heartbeatSec = 5 },
  tickIntervalSec = 0.2,
  integritySec = 30,
  -- How long a PEER IED's GOOSE can go without a fresh datagram before
  -- that peer's points (used by `interlocks` below) are treated as stale.
  gooseStaleAfterSec = 15,
  points = {},
  interlocks = {},
  -- Named report control blocks (SCL ReportControl): dataset + trigger-
  -- option-gated reporting, offered to clients by name via
  -- subscribe{rcbName=...} instead of the raw subscribe{refs=...}/"*"
  -- path (which stays exactly as-is for backward compatibility -- an
  -- IED with no reports[] configured behaves identically to before this
  -- existed). See handleSubscribe/deliverRcbReport below.
  reports = {},
  -- Protection function logical nodes -- see sas/protection/*.lua.
  -- ptoc (overcurrent) and pdif (differential) have real trip logic;
  -- pdis (distance) is modeled for completeness only, never trips (see
  -- sas/protection/pdis.lua's header for why).
  protection = { ptoc = {}, pdif = {}, pdis = {} },
  -- Cross-IED trip commands: forces a local control point to `tripValue`
  -- when a PEER IED's GOOSE-sourced point satisfies `condition`/
  -- `peerValue` -- e.g. a transformer's differential-protection Op point
  -- commanding the adjacent breaker IEDs to open, since the transformer
  -- IED doesn't own those breakers itself. Structurally the inverse of
  -- `interlocks` (forces an operate instead of blocking one); always
  -- bypasses local interlocks, matching "protection commands win".
  remoteTrips = {},
}

-- Condition vocabulary for interlock rules, deliberately duplicated from
-- sas/alarms.lua rather than shared -- matches this codebase's existing
-- norm of small per-module tables over a shared abstraction (see
-- sas/proto/goose.lua's and OC-IP-Stack's own multicast.lua's header
-- comments on the same point re: wire header formats).
local CONDITIONS = {
  eq = function(v, target) return v == target end,
  ne = function(v, target) return v ~= target end,
  lt = function(v, target) return type(v) == "number" and v < target end,
  gt = function(v, target) return type(v) == "number" and v > target end,
}

engine.state = {
  running = false,
  cfg = nil,
  db = nil,
  iedName = nil,
  clients = {},        -- [peerAddress] = { addr=, subs=nil|"*"|{[ref]=true}, rcb=nil }
  gooseState = nil,    -- goose.newPublisher(...)
  peers = {},           -- [peerIedName] = model.ensureGoosePeerEntry(...) -- GOOSE heard from other IEDs, for interlocking
  sbo = nil,
  pulses = {},          -- pending redstone pulses, see sas.io.redstone
  lastIntegrityAt = nil,
  tickTimerId = nil,
  log = {},
  protection = { ptoc = {}, pdif = {} },  -- runtime state parallel to cfg.protection.{ptoc,pdif} by index
  remoteTripState = {},                    -- runtime state parallel to cfg.remoteTrips by index
}

engine.log = util.makeLogger(engine.state.log, 200)

--- Point I/O ------------------------------------------------------------

local function readPointValue(rec)
  local io_ = rec.io
  if not io_ then return nil, "no io binding" end

  if io_.kind == "redstone" then
    if rec.type == "DPS" then
      return io_rs.readDouble(io_)
    elseif rec.type == "SPS" then
      local level, err = io_rs.readLevel(io_)
      if not level then return nil, err end
      return level >= (io_.onLevel or 1)
    end
    return nil, "redstone io binding on unsupported point type " .. tostring(rec.type)
  elseif io_.kind == "meter" then
    return meter.read(io_)
  end
  return nil, "unknown io kind: " .. tostring(io_.kind)
end

local function valueChangedEnough(rec, newValue)
  if rec.type == "MV" then
    if rec.value == nil then return true end
    return math.abs(newValue - rec.value) >= (rec.deadband or 0)
  end
  return rec.value ~= newValue
end

--- Client connection handling ------------------------------------------------------------

local function sendMsg(client, msg)
  local ok, err = netmsg.send(client.addr, engine.state.cfg.mms.port, msg)
  if not ok then
    engine.log("warn", "ied: could not send to %s: %s", tostring(client.addr), tostring(err))
  end
end

local function handleGetModel(client, msg)
  local points = {}
  model.eachPoint(engine.state.db, function(_, rec)
    table.insert(points, { ln = rec.ln, doName = rec.doName, type = rec.type })
  end)
  sendMsg(client, messages.replyTo(msg, { ld = engine.state.db.ld, points = points, reports = engine.state.cfg.reports }))
end

local function handleRead(client, msg)
  local values = {}
  for _, ref in ipairs(msg.refs or {}) do
    local rec = engine.state.db.points[ref]
    if rec then
      values[ref] = { value = rec.value, quality = rec.quality, t = rec.lastChangeAt }
    end
  end
  sendMsg(client, messages.replyTo(msg, { values = values }))
end

local function findReportControl(name)
  for _, rcb in ipairs(engine.state.cfg.reports) do
    if rcb.name == name then return rcb end
  end
  return nil
end

-- Sends the current value of every point in `rcb.dataset` as one report,
-- unconditionally -- used for TrgOps.gi (general interrogation) right
-- after a client subscribes to a report control block, mirroring real
-- 61850's "GI gives you the full picture on subscribe" behavior.
local function sendFullDataset(client, rcb, now)
  local values = {}
  for _, ref in ipairs(rcb.dataset) do
    local rec = engine.state.db.points[ref]
    if rec then
      values[ref] = { value = rec.value, quality = rec.quality, t = rec.lastChangeAt }
    end
  end
  if next(values) then
    sendMsg(client, { type = "report", values = values })
    client.rcb.lastSentAt = now
  end
end

-- subscribe{rcbName=...} (dataset + TrgOps-gated, IED-side rate-limited)
-- and subscribe{refs=...|"*"} (unconditional "any change", the original
-- behavior) are mutually exclusive per client connection -- whichever
-- was subscribed most recently wins, matching handleSubscribe's existing
-- overwrite-on-resubscribe semantics.
local function handleSubscribe(client, msg)
  if msg.rcbName then
    local rcb = findReportControl(msg.rcbName)
    if not rcb then
      sendMsg(client, messages.replyTo(msg, { ok = false, err = "unknown report control block: " .. tostring(msg.rcbName) }))
      return
    end
    local datasetSet = {}
    for _, ref in ipairs(rcb.dataset) do datasetSet[ref] = true end

    client.subs = nil
    client.rcb = { cfg = rcb, datasetSet = datasetSet, pending = {}, lastSentAt = 0, lastPeriodicAt = 0 }

    sendMsg(client, messages.replyTo(msg, { ok = true }))
    if rcb.trgOps and rcb.trgOps.gi then
      sendFullDataset(client, rcb, computer.uptime())
    end
    return
  end

  client.rcb = nil
  if msg.refs == "*" then
    client.subs = "*"
  else
    local subs = {}
    for _, ref in ipairs(msg.refs or {}) do subs[ref] = true end
    client.subs = subs
  end
  sendMsg(client, messages.replyTo(msg, { ok = true }))
end

local function handleSelect(client, msg)
  local rec = engine.state.db.points[msg.ref]
  if not rec or not model.CONTROL_TYPES[rec.type] then
    sendMsg(client, messages.replyTo(msg, { ok = false, err = "not a control point: " .. tostring(msg.ref) }))
    return
  end
  local timeoutSec = (rec.sbo and rec.sbo.timeoutSec) or 30
  local token, err = engine.state.sbo:select(msg.ref, msg.clientId, timeoutSec, computer.uptime())
  if not token then
    sendMsg(client, messages.replyTo(msg, { ok = false, err = err }))
    return
  end
  sendMsg(client, messages.replyTo(msg, { ok = true, token = token }))
end

local function applyOperate(rec, value)
  if rec.type == "DPC" then
    return io_rs.operateDouble(engine.state.pulses, rec.io, value, computer.uptime())
  elseif rec.type == "SPC" then
    return io_rs.writeLevel(rec.io, value)
  end
  return nil, "unsupported control type: " .. tostring(rec.type)
end

-- Peer-to-peer safety interlocking (IEC 61850 GOOSE's actual primary
-- real-world use case): block operating `ref` to `targetValue` while a
-- condition against a PEER IED's GOOSE-sourced point value holds true.
-- Evaluated here (called from handleOperate, after SBO validation
-- succeeds but before the physical output is applied) rather than in
-- handleSelect, since only operate carries the target value -- select
-- never does (see sas/proto/messages.lua's catalog).
--
-- Fail-safe by default: if the referenced peer point has never been
-- heard, or its GOOSE has gone stale, the rule BLOCKS (matches safety-
-- interlock convention: unknown state is treated as unsafe). A rule can
-- opt into fail-open (`failOpen = true`) when availability matters more
-- than that specific safety case.
local function interlockBlocks(ref, targetValue, now)
  for _, rule in ipairs(engine.state.cfg.interlocks) do
    if rule.localRef == ref and rule.blockValue == targetValue then
      local peerEntry = engine.state.peers[rule.peerIed]
      local peerPoint = peerEntry and peerEntry.points[rule.peerRef]
      local staleAfterSec = rule.staleAfterSec or engine.state.cfg.gooseStaleAfterSec
      local stale = (not peerEntry) or (not peerEntry.gooseState)
        or goose.isStale(peerEntry.gooseState, now, staleAfterSec)
      local unknown = (not peerPoint) or peerPoint.quality ~= "good"

      if stale or unknown then
        if rule.failOpen ~= true then
          return true, string.format("interlock %s: peer %s/%s unknown or stale",
            rule.id or ref, rule.peerIed, rule.peerRef)
        end
        -- failOpen == true: this rule does not block on unknown/stale data.
      elseif CONDITIONS[rule.condition](peerPoint.value, rule.peerValue) then
        return true, string.format("interlock %s: blocked by %s/%s",
          rule.id or ref, rule.peerIed, rule.peerRef)
      end
    end
  end
  return false
end

-- Applies a protection-initiated trip. `localTripRef` is nil for a
-- scheme with no local control target of its own (e.g. PDIF on a
-- transformer IED that doesn't own the breakers it must trip -- see
-- `remoteTrips` above), in which case this only sets the scheme's
-- synthetic Op indication.
--
-- Deliberately bypasses select-before-operate entirely, unlike
-- handleOperate's client-initiated path -- matches real substation
-- practice: protection trips are direct-with-normal-security, never
-- SBO, since SBO exists to guard slow *human* commands against
-- fat-fingering/comms corruption, not time-critical automatic ones.
-- Whether a local trip still respects interlockBlocks is a per-scheme
-- `respectInterlocks` config flag (default false -- "protection always
-- wins" -- overridable per scheme).
local function tripFromProtection(schemeCfg, localTripRef, tripValue, now)
  if localTripRef then
    local rec = engine.state.db.points[localTripRef]
    if not rec or not model.CONTROL_TYPES[rec.type] then
      engine.log("error", "protection: %s trip target is not a control point: %s",
        schemeCfg.name, tostring(localTripRef))
      return nil, "not a control point"
    end
    if schemeCfg.respectInterlocks then
      local blocked, reason = interlockBlocks(localTripRef, tripValue, now)
      if blocked then
        engine.log("warn", "protection: %s trip on %s blocked by interlock: %s",
          schemeCfg.name, localTripRef, reason)
        return nil, reason
      end
    end
    local ok, err = applyOperate(rec, tripValue)
    if not ok then
      engine.log("error", "protection: %s trip on %s failed: %s", schemeCfg.name, localTripRef, tostring(err))
      return nil, err
    end
  end

  local opRec = engine.state.db.points[model.ref(schemeCfg.name, "Op")]
  if opRec then
    model.setValue(opRec, true, "good", now)
  end
  engine.log("warn", "protection: %s OPERATED%s", schemeCfg.name,
    localTripRef and (" (" .. localTripRef .. " -> " .. tostring(tripValue) .. ")") or "")
  return true
end

local function handleOperate(client, msg)
  local rec = engine.state.db.points[msg.ref]
  if not rec or not model.CONTROL_TYPES[rec.type] then
    sendMsg(client, messages.replyTo(msg, { ok = false, err = "not a control point: " .. tostring(msg.ref) }))
    return
  end

  local now = computer.uptime()
  local ok, err = engine.state.sbo:operate(msg.ref, msg.token, msg.clientId, now)
  if not ok then
    sendMsg(client, messages.replyTo(msg, { ok = false, err = err }))
    return
  end

  local blocked, blockReason = interlockBlocks(msg.ref, msg.value, now)
  if blocked then
    sendMsg(client, messages.replyTo(msg, { ok = false, err = blockReason }))
    return
  end

  local applyOk, applyErr = applyOperate(rec, msg.value)
  if not applyOk then
    sendMsg(client, messages.replyTo(msg, { ok = false, err = applyErr or "operate failed" }))
    return
  end
  sendMsg(client, messages.replyTo(msg, { ok = true }))
end

local function handleCancel(client, msg)
  local ok, err = engine.state.sbo:cancel(msg.ref, msg.token, msg.clientId, computer.uptime())
  sendMsg(client, messages.replyTo(msg, { ok = ok and true or false, err = err }))
end

local function handleHeartbeat(client, msg)
  sendMsg(client, messages.replyTo(msg, {}))
end

local HANDLERS = {
  ["get-model"] = handleGetModel,
  read = handleRead,
  subscribe = handleSubscribe,
  select = handleSelect,
  operate = handleOperate,
  cancel = handleCancel,
  heartbeat = handleHeartbeat,
}

local function dispatch(client, msg)
  local handler = HANDLERS[msg.type]
  if not handler then
    if messages.REQUEST_TYPES[msg.type] then
      sendMsg(client, messages.replyTo(msg, { ok = false, err = "not supported by an IED server" }))
    else
      engine.log("warn", "ied: unknown message type '%s'", tostring(msg.type))
    end
    return
  end
  local ok, err = pcall(handler, client, msg)
  if not ok then
    engine.log("error", "ied: handler error for '%s': %s", tostring(msg.type), tostring(err))
  end
end

--- Tick ------------------------------------------------------------

-- Every inbound request identifies its sender by modem address (the
-- closest thing to OC-IP-Stack's per-connection `conn` this connectionless
-- transport has) -- a client entry is created the first time an address is
-- heard from, and simply kept (not pruned) for as long as iedd runs: a
-- SCADA that goes away for good just leaves a harmless, small, unused
-- subs/rcb entry behind, an acceptable "don't over-engineer for OC scale"
-- trade-off (same one sas/scada/engine.lua's pushAlarmUpdates makes for
-- resend-every-tick alarm pushes) rather than inventing a liveness/idle-
-- timeout protocol this connectionless transport has no built-in notion of.
local function serviceRequests()
  for _, item in ipairs(netmsg.drain(engine.state.cfg.mms.port)) do
    local client = engine.state.clients[item.from]
    if not client then
      client = { addr = item.from, subs = nil, rcb = nil }
      engine.state.clients[item.from] = client
    end
    dispatch(client, item.data)
  end
end

-- Polls every status/measured-value point's I/O binding, updates its live
-- value, and returns the list of refs that changed (or that are due for
-- a periodic integrity refresh even without a real change, so subscribed
-- reports/GOOSE never go silently stale on a genuinely static plant),
-- plus a ref->"dchg"|"qchg" map (a point only ever gets one tag per
-- tick, since the two branches below are mutually exclusive) used by
-- deliverRcbReport to apply TrgOps filtering -- a forced integrity
-- refresh is tagged "dchg" (the common/default TrgOps case) rather than
-- inventing a third category for it.
local function pollPoints(now)
  local changedRefs = {}
  local changeKind = {}
  local forceIntegrity = (not engine.state.lastIntegrityAt)
    or (now - engine.state.lastIntegrityAt >= (engine.state.cfg.integritySec or 30))

  model.eachPoint(engine.state.db, function(ref, rec)
    if rec.io and (model.STATUS_TYPES[rec.type] or rec.type == "MV") then
      local val, rerr = readPointValue(rec)
      if val ~= nil then
        local changed = valueChangedEnough(rec, val)
        model.setValue(rec, val, "good", now)
        if changed or forceIntegrity then
          table.insert(changedRefs, ref)
          changeKind[ref] = "dchg"
        end
      elseif rec.quality ~= "invalid" then
        rec.quality = "invalid"
        table.insert(changedRefs, ref)
        changeKind[ref] = "qchg"
      end
    end
  end)

  if forceIntegrity then engine.state.lastIntegrityAt = now end
  return changedRefs, changeKind
end

-- Applies one report-control-block client's TrgOps/bufTime semantics.
-- dchg/qchg: in-dataset refs from this tick's changedRefs, gated on the
-- matching TrgOps flag (dupd, if enabled, accepts either kind -- real
-- SCL dupd means "report even with no real change", which this
-- simplified model approximates as "don't filter by kind" rather than
-- adding a third fully-distinct signal for it). period: forces the
-- WHOLE dataset in on a fixed cadence regardless of change. bufTime:
-- IED-side minimum spacing between sends for this client -- eligible
-- values accumulate in `rcb.pending` and flush together once bufTime
-- has elapsed since the last send, rather than being dropped.
local function deliverRcbReport(client, changedRefs, changeKind, now)
  local rcb = client.rcb
  local cfg = rcb.cfg
  local trgOps = cfg.trgOps or {}

  for _, ref in ipairs(changedRefs) do
    if rcb.datasetSet[ref] then
      local kind = changeKind[ref]
      local include = trgOps.dupd or (kind == "dchg" and trgOps.dchg) or (kind == "qchg" and trgOps.qchg)
      if include then
        local rec = engine.state.db.points[ref]
        rcb.pending[ref] = { value = rec.value, quality = rec.quality, t = rec.lastChangeAt }
      end
    end
  end

  if trgOps.period and cfg.periodSec and cfg.periodSec > 0
      and (now - rcb.lastPeriodicAt) >= cfg.periodSec then
    rcb.lastPeriodicAt = now
    for _, ref in ipairs(cfg.dataset) do
      local rec = engine.state.db.points[ref]
      if rec then
        rcb.pending[ref] = { value = rec.value, quality = rec.quality, t = rec.lastChangeAt }
      end
    end
  end

  if next(rcb.pending) and (now - rcb.lastSentAt) >= (cfg.bufTime or 0) then
    sendMsg(client, { type = "report", values = rcb.pending })
    rcb.pending = {}
    rcb.lastSentAt = now
  end
end

local function deliverReports(changedRefs, changeKind, now)
  for _, client in pairs(engine.state.clients) do
    if client.rcb then
      deliverRcbReport(client, changedRefs, changeKind, now)
    elseif client.subs and #changedRefs > 0 then
      local values = {}
      for _, ref in ipairs(changedRefs) do
        if client.subs == "*" or client.subs[ref] then
          local rec = engine.state.db.points[ref]
          values[ref] = { value = rec.value, quality = rec.quality, t = rec.lastChangeAt }
        end
      end
      if next(values) then
        sendMsg(client, { type = "report", values = values })
      end
    end
  end
end

local function publishGoose(changedRefs, now)
  local dirty = false
  for _, ref in ipairs(changedRefs) do
    local rec = engine.state.db.points[ref]
    if rec.goose then dirty = true; break end
  end
  if dirty then
    engine.state.gooseState:markDirty(now)
  end

  if not engine.state.gooseState:dueSend(now) then return end

  local values = {}
  model.eachPoint(engine.state.db, function(ref, rec)
    if rec.goose then
      values[ref] = { v = rec.value, q = rec.quality }
    end
  end)
  local payload = goose.encode(engine.state.iedName, engine.state.db.ld,
    engine.state.gooseState.stNum, engine.state.gooseState.sqNum, now, values)

  local ok, serr = netmsg.broadcast(engine.state.cfg.goose.port, payload)
  if not ok then
    engine.log("warn", "ied: goose broadcast send failed: %s", tostring(serr))
  end
end

-- Non-blocking drain of GOOSE heard from other IEDs on the shared
-- broadcast port -- used to feed interlockBlocks() above. Unlike
-- OC-IP-Stack's multicast (which flooded every local interface, including
-- back to the sender), an OC modem broadcast is never delivered back to
-- its own sender, but the self-filter below is kept anyway as cheap
-- defense-in-depth.
local function receiveGoosePeers(now)
  for _, item in ipairs(netmsg.drain(engine.state.cfg.goose.port)) do
    local msg = item.data
    if goose.isValid(msg) and msg.ied ~= engine.state.iedName then
      local peerEntry = model.ensureGoosePeerEntry(engine.state.peers, msg.ied)
      if not peerEntry.gooseState then peerEntry.gooseState = goose.newSubscriberState() end
      goose.recordReceived(peerEntry.gooseState, msg, now)
      for ref, v in pairs(msg.values) do
        local rec = peerEntry.points[ref]
        if not rec then
          rec = { value = nil, quality = "invalid", lastChangeAt = nil }
          peerEntry.points[ref] = rec
        end
        model.setValue(rec, v.v, v.q, now)
      end
    elseif not goose.isValid(msg) then
      engine.log("warn", "ied: dropped malformed GOOSE datagram from %s", tostring(item.from))
    end
  end
end

-- Evaluates every configured protection scheme against current point
-- readings, applying real trip logic for ptoc/pdif (pdis never trips --
-- see sas/protection/pdis.lua). Each scheme LATCHES on its first trip
-- (via engine.state.protection.{ptoc,pdif}[i].latched) and stops
-- re-evaluating until iedd restarts -- without this, a sustained fault
-- condition would re-trip (re-pulse the breaker, re-log, re-report)
-- every single tick forever. Returns the list of refs that changed
-- (the scheme's own "<name>.Op" point, plus a ptoc's local trip target).
local function evaluateProtection(now)
  local changed = {}
  local cfg = engine.state.cfg

  for i, pcfg in ipairs(cfg.protection.ptoc) do
    local state = engine.state.protection.ptoc[i]
    if not state.latched then
      local dt = now - (state.lastEvalAt or now)
      if dt <= 0 then dt = cfg.tickIntervalSec end
      state.lastEvalAt = now

      local inputRec = engine.state.db.points[pcfg.input]
      local measured = (inputRec and inputRec.quality == "good") and inputRec.value or nil
      if ptocmod.tick(state, pcfg, measured, dt) then
        state.latched = true
        -- Control points (DPC/SPC) never populate .value/.quality in
        -- this codebase's model (only status/MV points do, via
        -- pollPoints) -- reporting pcfg.trip itself as "changed" would
        -- always carry a nil/invalid payload, so only the Op point
        -- (which DOES carry a real true/false) goes into `changed`, and
        -- only if the trip actually applied (tripFromProtection can fail
        -- -- not a control point, interlocked, or the physical operate
        -- itself failing -- in which case Op was never set, so reporting
        -- a "change" would be a false report).
        local applied = tripFromProtection(pcfg, pcfg.trip, "open", now)
        if applied then
          table.insert(changed, model.ref(pcfg.name, "Op"))
        end
      end
    end
  end

  for i, pcfg in ipairs(cfg.protection.pdif) do
    local state = engine.state.protection.pdif[i]
    if not state.latched then
      local values = {}
      for j, input in ipairs(pcfg.inputs) do
        local rec = engine.state.db.points[input.ref]
        values[j] = (rec and rec.quality == "good") and rec.value or nil
      end
      if pdifmod.evaluate(pcfg, values) then
        state.latched = true
        local applied = tripFromProtection(pcfg, nil, nil, now)
        if applied then
          table.insert(changed, model.ref(pcfg.name, "Op"))
        end
      end
    end
  end

  return changed
end

-- Cross-IED trip commands (see `remoteTrips` in DEFAULTS): reacts to a
-- peer IED's GOOSE-sourced point (typically another scheme's synthetic
-- Op indication, itself GOOSE-published like any other point) by forcing
-- a local control point to a target value -- reusing the same
-- receiveGoosePeers-populated peer tracking interlockBlocks already
-- reads, no new transport. Always bypasses local interlocks (protection
-- commands win, same convention as tripFromProtection's default) and
-- latches per-rule so a peer Op staying true doesn't re-pulse every tick.
local function remoteTripCheck(now)
  for i, rule in ipairs(engine.state.cfg.remoteTrips) do
    local state = engine.state.remoteTripState[i]
    if not state.latched then
      local peerEntry = engine.state.peers[rule.peerIed]
      local peerPoint = peerEntry and peerEntry.points[rule.peerRef]
      if peerPoint and peerPoint.quality == "good" and CONDITIONS[rule.condition](peerPoint.value, rule.peerValue) then
        local rec = engine.state.db.points[rule.localRef]
        if rec and model.CONTROL_TYPES[rec.type] then
          state.latched = true
          engine.log("warn", "protection: remote trip %s: %s/%s -> local %s = %s",
            rule.id or rule.localRef, rule.peerIed, rule.peerRef, rule.localRef, tostring(rule.tripValue))
          -- Not reporting rule.localRef into `changed`: like
          -- evaluateProtection's ptoc trip target, a control point never
          -- populates .value/.quality in this model, so there's no real
          -- change to report -- the resulting physical breaker motion
          -- shows up through the normal STATUS point poll instead.
          applyOperate(rec, rule.tripValue)
        end
      end
    end
  end
end

function engine.tick()
  local ok, err = pcall(function()
    local now = computer.uptime()

    discovery.tick(now)
    serviceRequests()

    receiveGoosePeers(now)

    local changedRefs, changeKind = pollPoints(now)
    for _, ref in ipairs(evaluateProtection(now)) do
      table.insert(changedRefs, ref)
      changeKind[ref] = "dchg"
    end
    remoteTripCheck(now)

    deliverReports(changedRefs, changeKind, now)
    publishGoose(changedRefs, now)

    engine.state.sbo:tick(now)
    io_rs.pulseTick(engine.state.pulses, now)
  end)
  if not ok then
    engine.log("error", "ied: tick error: %s", tostring(err))
  end
end

--- Lifecycle ------------------------------------------------------------

-- Hard-validates every interlocks[] rule against this IED's own point
-- database at start time: unknown/non-control localRef, missing
-- blockValue/peerIed/peerRef/peerValue, or an unrecognized condition.
-- Returns true, or nil, err.
local function validateInterlocks(db, interlocks)
  for i, rule in ipairs(interlocks) do
    local rec = type(rule.localRef) == "string" and db.points[rule.localRef]
    if not rec then
      return nil, "interlocks[" .. i .. "]: unknown localRef " .. tostring(rule.localRef)
    end
    if not model.CONTROL_TYPES[rec.type] then
      return nil, "interlocks[" .. i .. "]: localRef " .. rule.localRef .. " is not a control point"
    end
    if rule.blockValue == nil then
      return nil, "interlocks[" .. i .. "]: missing blockValue"
    end
    if type(rule.peerIed) ~= "string" or type(rule.peerRef) ~= "string" then
      return nil, "interlocks[" .. i .. "]: peerIed/peerRef must be strings"
    end
    if not CONDITIONS[rule.condition] then
      return nil, "interlocks[" .. i .. "]: unknown condition " .. tostring(rule.condition)
    end
    if rule.peerValue == nil then
      return nil, "interlocks[" .. i .. "]: missing peerValue"
    end
  end
  return true
end

-- Same shape as validateInterlocks, for the inverse relation (forces an
-- operate instead of blocking one). Returns true, or nil, err.
local function validateRemoteTrips(db, remoteTrips)
  for i, rule in ipairs(remoteTrips) do
    local rec = type(rule.localRef) == "string" and db.points[rule.localRef]
    if not rec then
      return nil, "remoteTrips[" .. i .. "]: unknown localRef " .. tostring(rule.localRef)
    end
    if not model.CONTROL_TYPES[rec.type] then
      return nil, "remoteTrips[" .. i .. "]: localRef " .. rule.localRef .. " is not a control point"
    end
    if rule.tripValue == nil then
      return nil, "remoteTrips[" .. i .. "]: missing tripValue"
    end
    if type(rule.peerIed) ~= "string" or type(rule.peerRef) ~= "string" then
      return nil, "remoteTrips[" .. i .. "]: peerIed/peerRef must be strings"
    end
    if not CONDITIONS[rule.condition] then
      return nil, "remoteTrips[" .. i .. "]: unknown condition " .. tostring(rule.condition)
    end
    if rule.peerValue == nil then
      return nil, "remoteTrips[" .. i .. "]: missing peerValue"
    end
  end
  return true
end

-- Hard-validates every reports[] report control block: unique name,
-- dataset refs all resolve, trgOps fields (if present) are booleans,
-- periodSec required and positive when trgOps.period is set, bufTime/
-- confRev are non-negative numbers if present. Returns true, or nil, err.
local function validateReports(db, reports)
  local seenNames = {}
  for i, rcb in ipairs(reports) do
    if type(rcb.name) ~= "string" or rcb.name == "" then
      return nil, "reports[" .. i .. "]: missing name"
    end
    if seenNames[rcb.name] then
      return nil, "reports[" .. i .. "]: duplicate name " .. rcb.name
    end
    seenNames[rcb.name] = true
    if type(rcb.dataset) ~= "table" or #rcb.dataset == 0 then
      return nil, "reports[" .. rcb.name .. "]: dataset must be a non-empty list of point refs"
    end
    for _, ref in ipairs(rcb.dataset) do
      if not db.points[ref] then
        return nil, "reports[" .. rcb.name .. "]: dataset references unknown point " .. tostring(ref)
      end
    end
    local trgOps = rcb.trgOps or {}
    for _, flag in ipairs({ "dchg", "qchg", "dupd", "period", "gi" }) do
      if trgOps[flag] ~= nil and type(trgOps[flag]) ~= "boolean" then
        return nil, "reports[" .. rcb.name .. "]: trgOps." .. flag .. " must be a boolean"
      end
    end
    if trgOps.period and (type(rcb.periodSec) ~= "number" or rcb.periodSec <= 0) then
      return nil, "reports[" .. rcb.name .. "]: trgOps.period requires a positive periodSec"
    end
    if rcb.bufTime ~= nil and (type(rcb.bufTime) ~= "number" or rcb.bufTime < 0) then
      return nil, "reports[" .. rcb.name .. "]: bufTime must be a non-negative number"
    end
  end
  return true
end

-- Hard-validates every protection[] scheme against the point database.
-- Returns true, or nil, err.
local function validateProtection(db, protection)
  local function resolvePoint(ref) return db.points[ref] end
  local function isControlType(t) return model.CONTROL_TYPES[t] == true end

  for _, pcfg in ipairs(protection.ptoc) do
    local ok, err = ptocmod.validate(pcfg, resolvePoint, isControlType)
    if not ok then return nil, err end
  end
  for _, pcfg in ipairs(protection.pdif) do
    local ok, err = pdifmod.validate(pcfg, resolvePoint)
    if not ok then return nil, err end
  end
  for _, pcfg in ipairs(protection.pdis) do
    local ok, err = pdismod.validate(pcfg)
    if not ok then return nil, err end
  end
  return true
end

-- Registers one synthetic SPS "<schemeName>.Op" point per configured
-- protection scheme (mirrors real IEC 61850's Op ACT-CDC output every
-- protection LN class has) -- io=nil since it's never polled from
-- hardware, only ever written by tripFromProtection. goose=true so a
-- trip is visible to peer IEDs via the same GOOSE path as any other
-- point (this is what makes `remoteTrips` possible with no new
-- transport). Reuses the existing status/report/GOOSE/historian
-- pipelines for "protection operated" with zero new plumbing.
local function registerProtectionOpPoints(db, protection)
  local function register(schemeName)
    local ref = model.ref(schemeName, "Op")
    db.points[ref] = {
      ln = schemeName, doName = "Op", type = "SPS",
      io = nil, goose = true, deadband = 0, sbo = nil,
      value = false, quality = "good", lastChangeAt = nil, lastPublishedAt = nil,
    }
  end
  for _, pcfg in ipairs(protection.ptoc) do register(pcfg.name) end
  for _, pcfg in ipairs(protection.pdif) do register(pcfg.name) end
  for _, pcfg in ipairs(protection.pdis) do register(pcfg.name) end
end

-- Idempotent: calling start() while already running is a no-op success.
function engine.start()
  if engine.state.running then return true end

  local cfg, cfgErr = config.load(CFG_PATH, DEFAULTS)
  engine.state.cfg = cfg
  engine.log = util.makeLogger(engine.state.log, 200)
  if cfgErr then
    engine.log("warn", "ied: %s (using built-in defaults)", cfgErr)
  end

  local dbOk, dbResult = pcall(model.buildIedDatabase, cfg)
  if not dbOk then
    engine.log("error", "ied: invalid point configuration: %s", tostring(dbResult))
    return nil, tostring(dbResult)
  end
  engine.state.db = dbResult
  engine.state.iedName = cfg.iedName
  registerProtectionOpPoints(engine.state.db, cfg.protection)

  -- A misconfigured safety interlock/protection scheme/remote-trip rule
  -- must refuse to start the daemon, not silently no-op.
  local ivOk, ivErr = validateInterlocks(engine.state.db, cfg.interlocks)
  if not ivOk then
    engine.log("error", "ied: invalid interlock configuration: %s", tostring(ivErr))
    return nil, ivErr
  end
  local rtOk, rtErr = validateRemoteTrips(engine.state.db, cfg.remoteTrips)
  if not rtOk then
    engine.log("error", "ied: invalid remoteTrips configuration: %s", tostring(rtErr))
    return nil, rtErr
  end
  local pOk, pErr = validateProtection(engine.state.db, cfg.protection)
  if not pOk then
    engine.log("error", "ied: invalid protection configuration: %s", tostring(pErr))
    return nil, pErr
  end
  local repOk, repErr = validateReports(engine.state.db, cfg.reports)
  if not repOk then
    engine.log("error", "ied: invalid reports configuration: %s", tostring(repErr))
    return nil, repErr
  end

  -- Fails loudly (no retry loop) if this machine has no modem component
  -- at all -- matches OC-IP-Stack's own ipstack.socket "never hang on a
  -- dead daemon" rule.
  local mok, merr = netmsg.open(cfg.mms.port)
  if not mok then
    engine.log("error", "ied: could not open MMS-lite port %d: %s", cfg.mms.port, tostring(merr))
    return nil, merr
  end
  local gok, gerr = netmsg.open(cfg.goose.port)
  if not gok then
    engine.log("error", "ied: could not open GOOSE port %d: %s", cfg.goose.port, tostring(gerr))
    netmsg.close(cfg.mms.port)
    return nil, gerr
  end
  discovery.advertise(cfg.iedName, cfg.mms.port)

  engine.state.clients = {}
  engine.state.pulses = {}
  engine.state.sbo = sbo.new()
  engine.state.gooseState = goose.newPublisher(cfg.goose)
  engine.state.peers = {}
  engine.state.lastIntegrityAt = nil

  engine.state.protection = { ptoc = {}, pdif = {} }
  for i in ipairs(cfg.protection.ptoc) do
    local s = ptocmod.newState()
    s.latched = false
    engine.state.protection.ptoc[i] = s
  end
  for i in ipairs(cfg.protection.pdif) do
    engine.state.protection.pdif[i] = { latched = false }
  end
  for _, pcfg in ipairs(cfg.protection.pdis) do
    pdismod.logInert(engine.log, pcfg)
  end
  engine.state.remoteTripState = {}
  for i in ipairs(cfg.remoteTrips) do
    engine.state.remoteTripState[i] = { latched = false }
  end

  engine.state.tickTimerId = event.timer(cfg.tickIntervalSec, engine.tick, math.huge)
  engine.state.running = true

  engine.log("info", "iedd started: %s/%s, mms port %d, %d point(s)",
    engine.state.iedName, cfg.logicalDevice, cfg.mms.port, util.countTable(engine.state.db.points))
  return true
end

-- Unregisters the tick timer, closes the modem ports. Idempotent.
function engine.stop()
  if not engine.state.running then return true end

  if engine.state.tickTimerId then
    event.cancel(engine.state.tickTimerId)
    engine.state.tickTimerId = nil
  end

  engine.state.clients = {}
  if engine.state.cfg then
    netmsg.close(engine.state.cfg.mms.port)
    netmsg.close(engine.state.cfg.goose.port)
  end
  engine.state.peers = {}
  engine.state.protection = { ptoc = {}, pdif = {} }
  engine.state.remoteTripState = {}

  engine.state.running = false
  engine.log("info", "iedd stopped")
  return true
end

function engine.isRunning()
  return engine.state.running
end

return engine
