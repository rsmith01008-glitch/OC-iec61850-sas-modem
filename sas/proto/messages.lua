-- sas.proto.messages: the MMS-lite message catalog. Every message is a
-- plain Lua table with a `type` field; requests additionally carry a
-- per-connection incrementing `id` used to correlate the matching reply,
-- since one TCP connection multiplexes concurrent requests alongside
-- unsolicited "report"/"alarm-update" pushes.
--
-- Request -> reply:
--   get-model              -> get-model-reply   {id, ld, points={{ln,doName,type},...},
--                                                 diagram=nil|{...}}  -- SCADA only; see
--                                                 scl/char_layout.py's build_diagram
--                                                 and sas/hmi/engine.lua
--   read      {refs}       -> read-reply        {id, values={[ref]={value,quality,t}}}
--   subscribe {refs|"*"|rcbName} -> subscribe-reply {id, ok, err}
--   select    {ref}        -> select-reply       {id, ok, token, err}
--   operate   {ref,token,value} -> operate-reply {id, ok, err}
--   cancel    {ref,token}  -> cancel-reply       {id, ok, err}
--   alarm-list              -> alarm-list-reply  {id, alarms={...}}
--   alarm-ack {alarmId}    -> alarm-ack-reply    {id, ok, err}
--   history-query {filter} -> history-query-reply {id, events={...}}
--   heartbeat               -> heartbeat-reply    {id}
--
-- Unsolicited (server -> subscribed client, no reply expected):
--   report      {values={[ref]={value,quality,t}}}
--   alarm-update {alarms={...}}
local messages = {}

messages.REQUEST_TYPES = {
  ["get-model"] = true,
  ["read"] = true,
  ["subscribe"] = true,
  ["select"] = true,
  ["operate"] = true,
  ["cancel"] = true,
  ["alarm-list"] = true,
  ["alarm-ack"] = true,
  ["history-query"] = true,
  ["heartbeat"] = true,
}

messages.PUSH_TYPES = {
  ["report"] = true,
  ["alarm-update"] = true,
}

-- REQUEST_TYPES[t] -> reply type name, e.g. "read" -> "read-reply".
messages.REPLY_OF = {}
for t in pairs(messages.REQUEST_TYPES) do
  messages.REPLY_OF[t] = t .. "-reply"
end

function messages.isRequest(msg)
  return type(msg) == "table" and messages.REQUEST_TYPES[msg.type] == true
end

function messages.isPush(msg)
  return type(msg) == "table" and messages.PUSH_TYPES[msg.type] == true
end

function messages.isReply(msg)
  if type(msg) ~= "table" or type(msg.type) ~= "string" then return false end
  return msg.type:match("%-reply$") ~= nil
end

-- Builds a reply table pre-filled with the request's id and the correct
-- reply type name, so handlers only need to add their own result fields.
function messages.replyTo(reqMsg, fields)
  local reply = { type = messages.REPLY_OF[reqMsg.type], id = reqMsg.id }
  if fields then
    for k, v in pairs(fields) do reply[k] = v end
  end
  return reply
end

return messages
