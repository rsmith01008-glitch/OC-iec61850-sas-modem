-- sas.scada.engine: the station-bus data concentrator. Same daemon
-- skeleton as sas.ied.engine / OC-IP-Stack's ipstack.daemon: start()
-- registers an event.timer tick callback and returns immediately; tick()
-- stays entirely non-blocking.
--
-- Role: MMS-lite client + GOOSE subscriber to every configured IED,
-- maintaining a live aggregate database; MMS-lite server to HMI clients,
-- who read from that aggregate (never from the IEDs directly) and whose
-- control commands are forwarded down to the owning IED. Also runs
-- alarm evaluation and historian logging.
local event = require("event")
local netmsg = require("sas.proto.netmsg")
local discovery = require("sas.proto.discovery")

local config = require("sas.config")
local model = require("sas.model")
local messages = require("sas.proto.messages")
local goose = require("sas.proto.goose")
local mmsclient = require("sas.proto.mmsclient")
local alarms = require("sas.alarms")
local historian = require("sas.historian")
local util = require("sas.util")

local engine = {}

local CFG_PATH = "/etc/sas-scada.cfg"

local DEFAULTS = {
  -- Name this SCADA answers "who-is" discovery queries for -- must match
  -- sas-hmi.cfg's `scada` field on every HMI that talks to it.
  scadaName = "SCADA",
  hms = { port = 8103 },
  goose = { port = 8104 },
  tickIntervalSec = 0.2,
  resyncSec = 60,
  connectTimeoutSec = 5,
  reconnectIntervalSec = 10,
  gooseStaleAfterSec = 15,
  ieds = {},
  historian = { dir = "/var/log/sas-scada", maxBytes = 262144, maxFiles = 5 },
  alarms = {},
}

engine.state = {
  running = false,
  cfg = nil,
  db = nil,               -- model.newAggregateDatabase()
  iedClients = {},         -- [iedName] = { cfg={name}, client=mmsclient|nil, lastAttemptAt=, modelId=, subId= }
  hmiClients = {},         -- [peerAddress] = { addr=, subs=nil|"*"|{[ref]=true} }
  alarmList = nil,         -- alarms.newActiveList()
  lastResyncAt = nil,
  tickTimerId = nil,
  log = {},
}

engine.log = util.makeLogger(engine.state.log, 200)

--- IED-facing: connection management ------------------------------------------------------------

local function connectIed(iedEntry, now)
  iedEntry.lastAttemptAt = now
  local client, err = mmsclient.connect(iedEntry.cfg.name, engine.state.cfg.connectTimeoutSec)
  if not client then
    engine.log("warn", "scada: connect to %s failed: %s", iedEntry.cfg.name, tostring(err))
    -- Raise COMM_<name> here too, not just from disconnectIed(): an IED
    -- that fails to connect from the very first attempt (never reaches
    -- pollIedClient) would otherwise retry silently forever with no
    -- alarm ever raised.
    alarms.raise(engine.state.alarmList, "COMM_" .. iedEntry.cfg.name, "high",
      iedEntry.cfg.name .. " unreachable: " .. tostring(err), now)
    return
  end
  iedEntry.client = client
  local aggEntry = model.ensureIedEntry(engine.state.db, iedEntry.cfg.name)
  aggEntry.connOk = false -- flips true once get-model-reply arrives
  iedEntry.modelId = client:sendRequest({ type = "get-model" })
  alarms.clear(engine.state.alarmList, "COMM_" .. iedEntry.cfg.name, now)
  engine.log("info", "scada: connecting to %s", iedEntry.cfg.name)
end

local function disconnectIed(iedEntry, now, reason)
  if iedEntry.client then
    pcall(function() iedEntry.client:close() end)
    iedEntry.client = nil
  end
  iedEntry.modelId = nil
  iedEntry.subId = nil
  local aggEntry = model.ensureIedEntry(engine.state.db, iedEntry.cfg.name)
  aggEntry.connOk = false
  alarms.raise(engine.state.alarmList, "COMM_" .. iedEntry.cfg.name, "high",
    iedEntry.cfg.name .. " unreachable: " .. tostring(reason), now)
end

local function handleIedPush(iedEntry, msg, now)
  local aggEntry = model.ensureIedEntry(engine.state.db, iedEntry.cfg.name)
  if msg.type == "report" then
    for ref, v in pairs(msg.values or {}) do
      local rec = aggEntry.points[ref]
      if rec then
        local changed = model.setValue(rec, v.value, v.quality, now)
        if changed then
          -- Historian/history-query addresses points the same way the
          -- rest of the HMI-facing protocol does: fully qualified, not
          -- the IED-local `ref` used on the wire to/from the IED itself.
          local fullRef = model.fullRef(iedEntry.cfg.name, aggEntry.ld or "?", rec.ln, rec.doName)
          historian.append(engine.state.cfg.historian.dir, {
            t = now, type = "point", ied = iedEntry.cfg.name, ref = fullRef,
            value = v.value, quality = v.quality,
          }, engine.state.cfg.historian.maxBytes, engine.state.cfg.historian.maxFiles)
        end
      end
    end
  end
end

-- Sends a fresh "read" against every point currently known for this IED,
-- as a defense-in-depth full refresh against a dropped report/GOOSE
-- update (on top of, not instead of, the IED's own periodic integrity
-- refresh -- see sas.ied.engine's forceIntegrity -- since that covers
-- "the IED forgot to tell us" but not "we missed what it sent").
-- Fire-and-forget on a timer; the reply is picked up on a later tick via
-- the same popReply(id) mechanism used for the initial get-model.
local function maybeResync(iedEntry, now)
  if iedEntry.resyncId then
    local reply = iedEntry.client:popReply(iedEntry.resyncId)
    if reply then
      local aggEntry = model.ensureIedEntry(engine.state.db, iedEntry.cfg.name)
      for ref, v in pairs(reply.values or {}) do
        local rec = aggEntry.points[ref]
        if rec then model.setValue(rec, v.value, v.quality, now) end
      end
      iedEntry.resyncId = nil
    end
    return
  end

  if iedEntry.lastResyncAt and (now - iedEntry.lastResyncAt) < (engine.state.cfg.resyncSec or 60) then
    return
  end
  iedEntry.lastResyncAt = now

  local aggEntry = model.ensureIedEntry(engine.state.db, iedEntry.cfg.name)
  local refs = {}
  for ref in pairs(aggEntry.points) do table.insert(refs, ref) end
  if #refs > 0 then
    iedEntry.resyncId = iedEntry.client:sendRequest({ type = "read", refs = refs })
  end
end

local function pollIedClient(iedEntry, now)
  local client = iedEntry.client
  local ok, err = client:poll(now)
  if not ok then
    disconnectIed(iedEntry, now, err)
    return
  end

  if iedEntry.modelId then
    local reply = client:popReply(iedEntry.modelId)
    if reply then
      model.applyModelReply(engine.state.db, iedEntry.cfg.name, reply.ld, reply.points)
      local aggEntry = model.ensureIedEntry(engine.state.db, iedEntry.cfg.name)
      aggEntry.connOk = true
      iedEntry.modelId = nil
      -- Prefer the IED's own ReportControl-derived report (dataset +
      -- trigger-option-gated, IED-side rate-limited via bufTime) if it
      -- advertises one, matching SCL's actual reporting model instead of
      -- an unconditional "everything, every tick" subscribe. Falls back
      -- to refs="*" for an IED with no reports[] configured (hand-
      -- written cfg, not yet SCL-ified) -- fully backward compatible.
      -- Only the first advertised report is used; an IED offering
      -- several named reports is a real 61850 capability this keeps
      -- deliberately unexploited for now (SCADA subscribes to one
      -- primary report per IED connection).
      if reply.reports and reply.reports[1] then
        iedEntry.subId = client:sendRequest({ type = "subscribe", rcbName = reply.reports[1].name })
      else
        iedEntry.subId = client:sendRequest({ type = "subscribe", refs = "*" })
      end
      engine.log("info", "scada: %s model learned (%d point(s))", iedEntry.cfg.name, #reply.points)
    end
  else
    maybeResync(iedEntry, now)
  end

  for _, push in ipairs(client:drainInbox()) do
    handleIedPush(iedEntry, push, now)
  end
end

local function tickIeds(now)
  for _, iedEntry in pairs(engine.state.iedClients) do
    if iedEntry.client and iedEntry.client:isConnected() then
      pollIedClient(iedEntry, now)
    elseif (not iedEntry.lastAttemptAt) or (now - iedEntry.lastAttemptAt) >= (engine.state.cfg.reconnectIntervalSec or 10) then
      connectIed(iedEntry, now)
    end
  end
end

--- GOOSE subscriber ------------------------------------------------------------

local function tickGoose(now)
  for _, item in ipairs(netmsg.drain(engine.state.cfg.goose.port)) do
    local msg = item.data
    if goose.isValid(msg) then
      local aggEntry = model.ensureIedEntry(engine.state.db, msg.ied)
      if not aggEntry.gooseState then aggEntry.gooseState = goose.newSubscriberState() end
      goose.recordReceived(aggEntry.gooseState, msg, now)

      for ref, v in pairs(msg.values) do
        local rec = aggEntry.points[ref]
        if rec then
          local changed = model.setValue(rec, v.v, v.q, now)
          if changed then
            local fullRef = model.fullRef(msg.ied, aggEntry.ld or "?", rec.ln, rec.doName)
            historian.append(engine.state.cfg.historian.dir, {
              t = now, type = "point", ied = msg.ied, ref = fullRef, value = v.v, quality = v.q, via = "goose",
            }, engine.state.cfg.historian.maxBytes, engine.state.cfg.historian.maxFiles)
          end
        end
      end
    else
      engine.log("warn", "scada: dropped malformed GOOSE datagram from %s", tostring(item.from))
    end
  end

  -- Staleness check: an IED that stops publishing GOOSE (but whose
  -- MMS-lite request/reply may still look fine) needs its own alarm,
  -- independent of COMM_<iedName>.
  for iedName, aggEntry in pairs(engine.state.db.ieds) do
    local subState = aggEntry.gooseState
    local staleId = "GOOSE_" .. iedName
    if subState and not goose.isStale(subState, now, engine.state.cfg.gooseStaleAfterSec) then
      alarms.clear(engine.state.alarmList, staleId, now)
    elseif aggEntry.connOk then
      -- Only alarm once we've actually learned this IED's model (i.e. it
      -- is a real, currently-configured IED, not stale leftover state).
      alarms.raise(engine.state.alarmList, staleId, "medium", iedName .. " GOOSE stale/lost", now)
      for ref, rec in pairs(aggEntry.points) do
        rec.quality = "stale"
      end
    end
  end
end

--- Alarm evaluation ------------------------------------------------------------

local function tickAlarms(now)
  alarms.evaluate(engine.state.db, engine.state.cfg.alarms, engine.state.alarmList, now)
end

--- HMI-facing server ------------------------------------------------------------

local function sendMsg(client, msg)
  local ok, err = netmsg.send(client.addr, engine.state.cfg.hms.port, msg)
  if not ok then
    engine.log("warn", "scada: could not send to %s: %s", tostring(client.addr), tostring(err))
  end
end

local function findOwningIedClient(fullRef)
  local iedName = model.parseFullRef(fullRef)
  if not iedName then return nil end
  return engine.state.iedClients[iedName]
end

local function handleGetModel(client, msg)
  local points = {}
  local byIed = {}
  model.eachAggregatePoint(engine.state.db, function(iedName, ref, rec)
    local aggEntry = engine.state.db.ieds[iedName]
    local p = {
      ln = rec.ln, doName = rec.doName, type = rec.type,
      fullRef = model.fullRef(iedName, aggEntry.ld or "?", rec.ln, rec.doName),
    }
    table.insert(points, p)
    local group = byIed[iedName]
    if not group then group = {}; byIed[iedName] = group end
    table.insert(group, p)
  end)
  -- Cross-reference each status point to its control counterpart (and
  -- vice versa) so the HMI knows which ref to select/operate against
  -- when the operator clicks a status tile -- see
  -- model.computePointPairing's header for why this can't be guessed
  -- from the status ref alone. Grouped per-IED first since `ln`
  -- uniqueness is IED-scoped, not global across the aggregate.
  for iedName, group in pairs(byIed) do
    local aggEntry = engine.state.db.ieds[iedName]
    model.computePointPairing(group, "pairedFullRef", function(ln, doName)
      return model.fullRef(iedName, aggEntry.ld or "?", ln, doName)
    end)
  end
  sendMsg(client, messages.replyTo(msg, { ld = "SCADA", points = points }))
end

local function handleRead(client, msg)
  local values = {}
  for _, ref in ipairs(msg.refs or {}) do
    local rec = model.lookupAggregatePoint(engine.state.db, ref)
    if rec then
      values[ref] = { value = rec.value, quality = rec.quality, t = rec.lastChangeAt }
    end
  end
  sendMsg(client, messages.replyTo(msg, { values = values }))
end

local function handleSubscribe(client, msg)
  if msg.refs == "*" then
    client.subs = "*"
  else
    local subs = {}
    for _, ref in ipairs(msg.refs or {}) do subs[ref] = true end
    client.subs = subs
  end
  sendMsg(client, messages.replyTo(msg, {}))
end

-- select/operate/cancel are relayed to the owning IED, stateless (SCADA
-- keeps no reservation copy of its own -- see sas.sbo's file header).
-- The forwarded request's reply is relayed back to the HMI client once
-- the IED client's poll() picks it up on a later tick; we track the
-- pending relay as { hmiClient=, hmiMsgId=, iedReqId= } in
-- engine.state.pendingRelays.
local function forwardControl(client, msg)
  local iedEntry = findOwningIedClient(msg.ref)
  if not iedEntry or not iedEntry.client or not iedEntry.client:isConnected() then
    sendMsg(client, messages.replyTo(msg, { ok = false, err = "owning IED is unreachable" }))
    return
  end

  -- Wire refs are fully qualified ("IED-BRK1/LD0/XCBR1.Pos") between
  -- HMI<->SCADA but IED-local ("XCBR1.Pos") between SCADA<->IED -- rewrite
  -- before forwarding.
  local _iedName, _ldName, ln, doName = model.parseFullRef(msg.ref)
  local localMsg = {}
  for k, v in pairs(msg) do localMsg[k] = v end
  localMsg.ref = model.ref(ln, doName)

  local iedReqId, err = iedEntry.client:sendRequest(localMsg)
  if not iedReqId then
    sendMsg(client, messages.replyTo(msg, { ok = false, err = err }))
    return
  end
  table.insert(engine.state.pendingRelays, {
    hmiClient = client, hmiMsg = msg, iedClient = iedEntry.client, iedReqId = iedReqId,
    createdAt = computer.uptime(),
  })
end

local function handleAlarmList(client, msg)
  sendMsg(client, messages.replyTo(msg, { alarms = alarms.toArray(engine.state.alarmList) }))
end

local function handleAlarmAck(client, msg)
  local ok, err = alarms.ack(engine.state.alarmList, msg.alarmId, msg.operator, computer.uptime())
  sendMsg(client, messages.replyTo(msg, { ok = ok and true or false, err = err }))
end

local function handleHistoryQuery(client, msg)
  local filter = msg.filter or {}
  local filterFn = function(ev)
    if filter.ref and ev.ref ~= filter.ref then return false end
    if filter.from and ev.t and ev.t < filter.from then return false end
    if filter.to and ev.t and ev.t > filter.to then return false end
    return true
  end
  local events = historian.query(engine.state.cfg.historian.dir, filterFn, filter.limit or 100,
    engine.state.cfg.historian.maxFiles)
  sendMsg(client, messages.replyTo(msg, { events = events }))
end

local function handleHeartbeat(client, msg)
  sendMsg(client, messages.replyTo(msg, {}))
end

local HANDLERS = {
  ["get-model"] = handleGetModel,
  read = handleRead,
  subscribe = handleSubscribe,
  select = forwardControl,
  operate = forwardControl,
  cancel = forwardControl,
  ["alarm-list"] = handleAlarmList,
  ["alarm-ack"] = handleAlarmAck,
  ["history-query"] = handleHistoryQuery,
  heartbeat = handleHeartbeat,
}

local function dispatchHmi(client, msg)
  local handler = HANDLERS[msg.type]
  if not handler then
    engine.log("warn", "scada: unknown HMI message type '%s'", tostring(msg.type))
    return
  end
  local ok, err = pcall(handler, client, msg)
  if not ok then
    engine.log("error", "scada: handler error for '%s': %s", tostring(msg.type), tostring(err))
  end
end

-- Same address-keyed, no-explicit-close model as sas/ied/engine.lua's
-- serviceRequests -- see that function's header for why stale entries are
-- deliberately never pruned.
local function serviceHmiClients()
  for _, item in ipairs(netmsg.drain(engine.state.cfg.hms.port)) do
    local client = engine.state.hmiClients[item.from]
    if not client then
      client = { addr = item.from, subs = nil }
      engine.state.hmiClients[item.from] = client
    end
    dispatchHmi(client, item.data)
  end
end

local function deliverHmiReports()
  local changed = {}
  model.eachAggregatePoint(engine.state.db, function(iedName, ref, rec)
    if rec.lastChangeAt and rec.lastChangeAt == engine.state._tickNow then
      local aggEntry = engine.state.db.ieds[iedName]
      local fullRef = model.fullRef(iedName, aggEntry.ld or "?", rec.ln, rec.doName)
      table.insert(changed, { fullRef = fullRef, value = rec.value, quality = rec.quality, t = rec.lastChangeAt })
    end
  end)
  if #changed == 0 then return end

  for _, client in pairs(engine.state.hmiClients) do
    if client.subs then
      local values = {}
      for _, c in ipairs(changed) do
        if client.subs == "*" or client.subs[c.fullRef] then
          values[c.fullRef] = { value = c.value, quality = c.quality, t = c.t }
        end
      end
      if next(values) then
        sendMsg(client, { type = "report", values = values })
      end
    end
  end
end

local function relayControlReplies(now)
  local relays = engine.state.pendingRelays
  local i = 1
  while i <= #relays do
    local relay = relays[i]
    local reply = relay.iedClient:popReply(relay.iedReqId)
    local expired = (now - relay.createdAt) > (engine.state.cfg.connectTimeoutSec or 5) * 2
    if reply then
      sendMsg(relay.hmiClient, messages.replyTo(relay.hmiMsg, {
        ok = reply.ok, token = reply.token, err = reply.err,
      }))
      table.remove(relays, i)
    elseif expired then
      sendMsg(relay.hmiClient, messages.replyTo(relay.hmiMsg, { ok = false, err = "timeout waiting on IED reply" }))
      table.remove(relays, i)
    else
      i = i + 1
    end
  end
end

--- Alarm push to subscribed HMI clients ------------------------------------------------------------

-- Pushed unconditionally every tick to every subscribed client rather
-- than diffed against the previous snapshot: alarm lists are small and
-- this keeps the push path simple, at the cost of some redundant
-- traffic -- an acceptable trade at OC scale (matches OC-IP-Stack's own
-- "don't over-engineer for OC scale" design philosophy).
local function pushAlarmUpdates()
  local arr = alarms.toArray(engine.state.alarmList)
  for _, client in pairs(engine.state.hmiClients) do
    if client.subs then
      sendMsg(client, { type = "alarm-update", alarms = arr })
    end
  end
end

--- Tick ------------------------------------------------------------

function engine.tick()
  local ok, err = pcall(function()
    local now = computer.uptime()
    engine.state._tickNow = now

    discovery.tick(now)
    tickIeds(now)
    tickGoose(now)
    tickAlarms(now)

    serviceHmiClients()
    relayControlReplies(now)
    deliverHmiReports()
    pushAlarmUpdates()
  end)
  if not ok then
    engine.log("error", "scada: tick error: %s", tostring(err))
  end
end

--- Lifecycle ------------------------------------------------------------

function engine.start()
  if engine.state.running then return true end

  local cfg, cfgErr = config.load(CFG_PATH, DEFAULTS)
  engine.state.cfg = cfg
  engine.log = util.makeLogger(engine.state.log, 200)
  if cfgErr then
    engine.log("warn", "scada: %s (using built-in defaults)", cfgErr)
  end

  engine.state.db = model.newAggregateDatabase()
  engine.state.alarmList = alarms.newActiveList()
  engine.state.iedClients = {}
  for _, iedCfg in ipairs(cfg.ieds) do
    engine.state.iedClients[iedCfg.name] = { cfg = iedCfg, client = nil, lastAttemptAt = nil }
  end
  engine.state.hmiClients = {}
  engine.state.pendingRelays = {}
  engine.state.lastResyncAt = nil

  -- Fails loudly (no retry loop) if this machine has no modem component
  -- at all -- matches OC-IP-Stack's own ipstack.socket "never hang on a
  -- dead daemon" rule.
  local gok, gerr = netmsg.open(cfg.goose.port)
  if not gok then
    engine.log("error", "scada: could not open GOOSE port %d: %s", cfg.goose.port, tostring(gerr))
    return nil, gerr
  end
  local hok, herr = netmsg.open(cfg.hms.port)
  if not hok then
    engine.log("error", "scada: could not open HMI-facing port %d: %s", cfg.hms.port, tostring(herr))
    netmsg.close(cfg.goose.port)
    return nil, herr
  end
  discovery.advertise(cfg.scadaName, cfg.hms.port)

  engine.state.tickTimerId = event.timer(cfg.tickIntervalSec, engine.tick, math.huge)
  engine.state.running = true

  engine.log("info", "scadad started: hms port %d, goose port %d, %d configured IED(s)",
    cfg.hms.port, cfg.goose.port, #cfg.ieds)
  return true
end

function engine.stop()
  if not engine.state.running then return true end

  if engine.state.tickTimerId then
    event.cancel(engine.state.tickTimerId)
    engine.state.tickTimerId = nil
  end

  for _, iedEntry in pairs(engine.state.iedClients) do
    if iedEntry.client then pcall(function() iedEntry.client:close() end) end
  end
  engine.state.hmiClients = {}

  if engine.state.cfg then
    netmsg.close(engine.state.cfg.goose.port)
    netmsg.close(engine.state.cfg.hms.port)
  end

  engine.state.running = false
  engine.log("info", "scadad stopped")
  return true
end

function engine.isRunning()
  return engine.state.running
end

return engine
