-- sas.alarms: SCADA-side alarm evaluation and active-alarm-list state
-- machine. Two kinds of alarms share the same activeList/lifecycle:
--   - user-defined, config-driven condition alarms (evaluate() below),
--     e.g. "MMXU1.VolAB lt 200" -> undervoltage;
--   - built-in comm-health alarms (IED unreachable, GOOSE stale) that
--     sas/scada/engine.lua raises/clears directly via raise()/clear(),
--     since they aren't expressible as a single point-value condition.
--
-- Lifecycle per alarm id: inactive -> active/unacked (condition true) ->
-- active/acked (operator ack). If the condition clears while still
-- unacked, the alarm stays visible as "cleared/unacked" until acked, then
-- is removed -- standard SCADA behavior so a fleeting condition can't
-- silently vanish before an operator ever saw it.
local model = require("sas.model")

local alarms = {}

local CONDITIONS = {
  eq = function(v, target) return v == target end,
  ne = function(v, target) return v ~= target end,
  lt = function(v, target) return type(v) == "number" and v < target end,
  gt = function(v, target) return type(v) == "number" and v > target end,
}

function alarms.newActiveList()
  return {} -- [id] = { def=, severity=, message=, active=, acked=, ackedBy=, raisedAt=, clearedAt=, ackedAt= }
end

-- Directly raises (or refreshes) a built-in, non-condition alarm, e.g.
-- "IED-BRK1 unreachable". Idempotent -- calling it again while already
-- active is a no-op besides refreshing metadata.
function alarms.raise(activeList, id, severity, message, now)
  local a = activeList[id]
  if a and a.active then
    a.message = message
    return a
  end
  activeList[id] = {
    id = id, severity = severity, message = message,
    active = true, acked = (a and a.acked) or false, ackedBy = a and a.ackedBy,
    raisedAt = now, clearedAt = nil, ackedAt = a and a.ackedAt,
  }
  return activeList[id]
end

-- Clears a built-in alarm raised via raise(). If already acked, it's
-- removed immediately; otherwise it lingers as cleared/unacked until an
-- operator acks it (see file header).
function alarms.clear(activeList, id, now)
  local a = activeList[id]
  if not a or not a.active then return end
  a.active = false
  a.clearedAt = now
  if a.acked then
    activeList[id] = nil
  end
end

function alarms.ack(activeList, id, operator, now)
  local a = activeList[id]
  if not a then return nil, "no such alarm" end
  a.acked = true
  a.ackedBy = operator
  a.ackedAt = now
  if not a.active then
    activeList[id] = nil -- was cleared-but-unacked; ack finally removes it
  end
  return true
end

-- Evaluates every user-defined alarmDef against the aggregate database's
-- current point values, raising/clearing activeList entries as
-- conditions transition. Returns nothing; mutates activeList in place.
function alarms.evaluate(aggDb, alarmDefs, activeList, now)
  for _, def in ipairs(alarmDefs) do
    local check = CONDITIONS[def.condition]
    if check then
      local point = model.lookupAggregatePoint(aggDb, def.ref)
      local conditionTrue = point ~= nil and point.quality == "good" and check(point.value, def.value)
      if conditionTrue then
        alarms.raise(activeList, def.id, def.severity, def.message, now)
      else
        alarms.clear(activeList, def.id, now)
      end
    end
  end
end

-- Returns the active-list contents as a plain array (for wire transfer
-- via alarm-list-reply), each entry a shallow copy safe to serialize.
function alarms.toArray(activeList)
  local out = {}
  for id, a in pairs(activeList) do
    table.insert(out, {
      id = id, severity = a.severity, message = a.message,
      active = a.active, acked = a.acked, ackedBy = a.ackedBy,
      raisedAt = a.raisedAt, clearedAt = a.clearedAt, ackedAt = a.ackedAt,
    })
  end
  return out
end

return alarms
