-- DOS2 bridge, client side. Dialogue and other screens only exist in the client's Flash UI, so this half of the mod
-- records UI traffic and can call into UI elements. Same file transport as the server, with its own file names.
Ext.Require("Client/UI.lua")

local REQUEST = "dos2bridge_client_request.json"
local RESPONSE = "dos2bridge_client_response.json"
local HEARTBEAT = "dos2bridge_client_heartbeat.json"
local POLL_EVERY = 3
local BEAT_EVERY = 30

local tick = 0
local lastSeq = nil

local function respond(seq, ok, value)
  local out = { seq = seq }
  if ok then out.result = value else out.error = tostring(value) end
  local okJson, text = pcall(Ext.Json.Stringify, out, { Beautify = false, StringifyInternalTypes = true })
  if not okJson then
    text = Ext.Json.Stringify({ seq = seq, error = "Could not encode result: " .. tostring(text) }, { Beautify = false })
  end
  Ext.IO.SaveFile(RESPONSE, text)
end

local function poll()
  local raw = Ext.IO.LoadFile(REQUEST)
  if raw == nil or raw == "" then return end
  local okParse, req = pcall(Ext.Json.Parse, raw)
  if not okParse or type(req) ~= "table" or req.seq == nil or req.seq == lastSeq then return end
  lastSeq = req.seq
  local handler = ClientHandlers[req.cmd]
  if handler == nil then return respond(req.seq, false, "Unknown client command: " .. tostring(req.cmd)) end
  respond(req.seq, xpcall(handler, debug.traceback, req.args or {}))
end

Ext.Events.Tick:Subscribe(function ()
  tick = tick + 1
  if tick % POLL_EVERY == 0 then
    local ok, err = pcall(poll)
    if not ok then Ext.Utils.PrintError("[DOS2Bridge] client poll failed: " .. tostring(err)) end
  end
  if tick % BEAT_EVERY == 0 then
    pcall(Ext.IO.SaveFile, HEARTBEAT, Ext.Json.Stringify({ tick = tick }, { Beautify = false }))
  end
end)

Ext.Utils.Print("[DOS2Bridge] client loaded; polling " .. REQUEST)
