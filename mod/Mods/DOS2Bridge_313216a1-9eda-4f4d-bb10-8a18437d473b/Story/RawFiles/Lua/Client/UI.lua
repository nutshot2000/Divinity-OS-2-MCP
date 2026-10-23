-- Client handlers: ClientHandlers[cmd](args). UI traffic is kept in a ring buffer so tools can read what the game
-- showed (dialogue lines, answers, message boxes) and learn which call a click makes.
ClientHandlers = {}

local LOG_MAX = 400
UILog = UILog or {}
UILogSeq = UILogSeq or 0

-- Very chatty UI updates that would flood the log (hotbar, minimap, tooltips, overhead text).
local NOISY = { updateStatuses = true, setHPBars = true, updateInfo = true, onEventResize = true, setCompassRot = true,
  updateOHs = true, setMapPos = true, clearOHs = true, setCursor = true, updateArraySystem = true,
  removeLabel = true, update = true }

local function argsOf(e)
  local out = {}
  for i, v in ipairs(e.Args or {}) do
    local t = type(v)
    out[i] = (t == "string" or t == "number" or t == "boolean") and v or tostring(v)
  end
  return out
end

local function record(kind, e)
  if NOISY[e.Function] then return end
  local ok, typeId = pcall(function () return e.UI:GetTypeId() end)
  UILogSeq = UILogSeq + 1
  UILog[#UILog + 1] = { seq = UILogSeq, kind = kind, ui = ok and typeId or -1, fn = e.Function, args = argsOf(e),
    when = tostring(e.When) }
  if #UILog > LOG_MAX then table.remove(UILog, 1) end
end

-- Subscriptions are kept in globals so a hot reload can drop the old ones instead of stacking duplicates.
for _, sub in ipairs(UISubs or {}) do pcall(function () sub.event:Unsubscribe(sub.id) end) end
UISubs = {}
local function subscribe(event, fn) UISubs[#UISubs + 1] = { event = event, id = event:Subscribe(fn) } end

subscribe(Ext.Events.UIInvoke, function (e) pcall(record, "invoke", e) end)

-- Dialogue screen only (UI type 14): what the game shows and what clicking an answer calls. Kept apart from the
-- general log so busy UI updates never push it out.
DIALOG_UI = 14
DialogLog = DialogLog or {}
DialogLogSeq = DialogLogSeq or 0
local function flashArray(root, name)
  local out = {}
  local ok, arr = pcall(function () return root[name] end)
  if not ok or arr == nil then return out end
  for i = 0, #arr - 1 do
    local v = arr[i]
    local t = type(v)
    out[#out + 1] = (t == "string" or t == "number" or t == "boolean") and v or tostring(v)
  end
  return out
end

-- The game fills these arrays and then invokes updateDialog; the screen empties them once drawn, so they are only
-- readable at that moment. Snapshots accumulate until a tool reads them.
DialogSnapshots = DialogSnapshots or {}
local function snapshotDialog(ui)
  local root = ui:GetRoot()
  -- seq of the updateDialog entry about to be logged, so a read "since" the previous last position includes it
  DialogSnapshots[#DialogSnapshots + 1] = { seq = DialogLogSeq + 1, text = flashArray(root, "addTextArray"),
    answers = flashArray(root, "addAHArray"), keywords = flashArray(root, "addKWAnswerArray") }
  if #DialogSnapshots > 50 then table.remove(DialogSnapshots, 1) end
end

local function recordDialog(kind, e)
  local ok, typeId = pcall(function () return e.UI:GetTypeId() end)
  if not ok or typeId ~= DIALOG_UI or tostring(e.When) == "After" then return end
  if kind == "invoke" and e.Function == "updateDialog" then pcall(snapshotDialog, e.UI) end
  DialogLogSeq = DialogLogSeq + 1
  DialogLog[#DialogLog + 1] = { seq = DialogLogSeq, kind = kind, fn = e.Function, args = argsOf(e) }
  if #DialogLog > 300 then table.remove(DialogLog, 1) end
end
subscribe(Ext.Events.UIInvoke, function (e) pcall(recordDialog, "invoke", e) end)
-- A global UICall hook seemed to freeze the main menu once (unconfirmed: the save may just have been loading).
-- This one only records the dialogue screen's calls.
subscribe(Ext.Events.UICall, function (e) pcall(recordDialog, "call", e) end)

-- Popups. Tutorial boxes (UI 55) arrive as fadeInModal(category, title, text) and close with OkPressed; message
-- boxes (UI 29, e.g. "leave the Tutorial Deck?") are built from invokes and answered with ButtonPressed(id).
TUTORIAL_UI, MSGBOX_UI = 55, 29
PendingTutorials = PendingTutorials or {}
MsgBoxCalls = MsgBoxCalls or {}
local function recordPopup(e)
  local ok, typeId = pcall(function () return e.UI:GetTypeId() end)
  if not ok or tostring(e.When) == "After" then return end
  if typeId == TUTORIAL_UI and e.Function == "fadeInModal" then
    local a = argsOf(e)
    PendingTutorials[#PendingTutorials + 1] = { category = a[1], title = a[2], text = a[3] }
  elseif typeId == MSGBOX_UI then
    if e.Function == "removeButtons" then MsgBoxCalls = {} end
    MsgBoxCalls[#MsgBoxCalls + 1] = { fn = e.Function, args = argsOf(e) }
    if #MsgBoxCalls > 40 then table.remove(MsgBoxCalls, 1) end
  end
end
subscribe(Ext.Events.UIInvoke, function (e) pcall(recordPopup, e) end)

local function uiVisible(typeId)
  local ui = Ext.UI.GetByType(typeId)
  if ui == nil then return false end
  local ok, visible = pcall(function () return ui.OF_Visible end)
  return not ok or visible ~= false
end

--- Dismiss any open tutorial boxes ("Understood") and return what they said.
function ClientHandlers.tutorials()
  local shown = PendingTutorials
  PendingTutorials = {}
  if #shown > 0 and uiVisible(TUTORIAL_UI) then
    for _ = 1, #shown do pcall(function () Ext.UI.GetByType(TUTORIAL_UI):ExternalInterfaceCall("OkPressed") end) end
  end
  return shown
end

--- The open message box, if any: the raw invokes that built it (text and buttons), for the server tool to parse.
function ClientHandlers.msgbox()
  return { open = uiVisible(MSGBOX_UI), calls = MsgBoxCalls }
end

function ClientHandlers.msgbox_press(args)
  local ui = Ext.UI.GetByType(MSGBOX_UI)
  if ui == nil then error("No message box open") end
  ui:ExternalInterfaceCall("ButtonPressed", args.id)
  return { pressed = args.id }
end

function ClientHandlers.dialog_log(args)
  local out = {}
  for _, entry in ipairs(DialogLog) do
    if entry.seq > (args.since or 0) then out[#out + 1] = entry end
  end
  local snaps = {}
  for _, s in ipairs(DialogSnapshots) do
    if s.seq >= (args.since or 0) then snaps[#snaps + 1] = s end
  end
  return { last = DialogLogSeq, entries = out, snapshots = snaps, open = Ext.UI.GetByType(DIALOG_UI) ~= nil }
end

function ClientHandlers.ping()
  return { pong = true, side = "client", log = UILogSeq }
end

--- UI log entries after `since`, optionally only one UI type and/or one kind ("invoke" | "call").
function ClientHandlers.ui_log(args)
  local out = {}
  for _, entry in ipairs(UILog) do
    if entry.seq > (args.since or 0) and (args.ui == nil or entry.ui == args.ui)
        and (args.kind == nil or entry.kind == args.kind) then
      out[#out + 1] = entry
    end
  end
  local limit = args.limit or 100
  while #out > limit do table.remove(out, 1) end
  return { last = UILogSeq, entries = out }
end

--- Which UI types are currently open.
function ClientHandlers.ui_open(args)
  local open = {}
  for typeId = 0, (args.max or 200) do
    local ok, ui = pcall(Ext.UI.GetByType, typeId)
    if ok and ui ~= nil then open[#open + 1] = { type = typeId, path = tostring(ui.Path) } end
  end
  return open
end

--- Make the call a click on that UI would make (ExternalInterfaceCall), e.g. pick a dialogue answer.
function ClientHandlers.ui_call(args)
  local ui = Ext.UI.GetByType(args.ui)
  if ui == nil then error("UI type " .. tostring(args.ui) .. " is not open") end
  ui:ExternalInterfaceCall(args.fn, table.unpack(args.args or {}))
  return { called = args.fn }
end

function ClientHandlers.lua(args)
  local chunk, err = load("local _ENV = Mods.DOS2Bridge\n" .. args.code, "dos2_lua_client", "t")
  if chunk == nil then error(err) end
  return chunk()
end
