-- DOS2 bridge, server side. Polls a request file in Osiris Data, runs the named handler, writes the answer.
-- The MCP server (src/bridge.js) writes dos2bridge_request.json {seq, cmd, args} and waits for a
-- dos2bridge_response.json with the same seq.
Ext.Require("Server/Util.lua")
Ext.Require("Server/Handlers.lua")
Ext.Require("Server/Grid.lua")
Ext.Require("Server/Combat.lua")

local REQUEST = "dos2bridge_request.json"
local RESPONSE = "dos2bridge_response.json"
local HEARTBEAT = "dos2bridge_heartbeat.json"
local POLL_EVERY = 3     -- ticks (~10 polls a second at 30 Hz)
local BEAT_EVERY = 30    -- ticks (~1 s)

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
  local handler = Handlers[req.cmd]
  if handler == nil then return respond(req.seq, false, "Unknown command: " .. tostring(req.cmd)) end
  respond(req.seq, xpcall(handler, debug.traceback, req.args or {}))
end

Ext.Events.Tick:Subscribe(function ()
  tick = tick + 1
  if tick % POLL_EVERY == 0 then
    local ok, err = pcall(poll)
    if not ok then Ext.Utils.PrintError("[DOS2Bridge] poll failed: " .. tostring(err)) end
  end
  if tick % BEAT_EVERY == 0 then
    pcall(Ext.IO.SaveFile, HEARTBEAT, Ext.Json.Stringify({ tick = tick, level = CurrentLevelName() }, { Beautify = false }))
  end
end)

-- Arrival events for dos2_move: CharacterMoveTo* raise StoryEvent(character, eventName) when the move ends.
Ext.Osiris.RegisterListener("StoryEvent", 2, "after", function (_, event)
  if type(event) == "string" and event:sub(1, 10) == "DOS2Bridge" then Arrivals[event] = true end
end)

-- Item use outcome for dos2_use.
Ext.Osiris.RegisterListener("CharacterUsedItem", 2, "after", function (_, item) Uses[BareGuid(item)] = "used" end)
Ext.Osiris.RegisterListener("CharacterUsedItemFailed", 2, "after", function (_, item) Uses[BareGuid(item)] = "failed" end)

Ext.Utils.Print("[DOS2Bridge] loaded; polling " .. REQUEST .. " in Osiris Data")
