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
BookPages = BookPages or {}

--- Pages of the note or book read since the last call (and forget them).
function ClientHandlers.book_text()
  local pages = BookPages
  BookPages = {}
  return pages
end
MsgBoxCalls = MsgBoxCalls or {}
local function recordPopup(e)
  local ok, typeId = pcall(function () return e.UI:GetTypeId() end)
  if not ok or tostring(e.When) == "After" then return end
  if e.Function == "addPage" then
    -- Notes and books: the book screen is handed each page's text (reading = using the item).
    local a = argsOf(e)
    if type(a[1]) == "string" then BookPages[#BookPages + 1] = a[1] end
  elseif typeId == TUTORIAL_UI and e.Function == "fadeInModal" then
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
-- Panels that can be left open on screen (opening a container shows its loot window, a stray key opens the journal,
-- ...). Dialogue and message boxes are not here: those need an answer, not closing. Close-call names from each SWF.
-- Only panels the bridge's own actions leave open. The player's own windows (crafting, trade, journal, skills,
-- examine, waypoints) are never touched: closeUI destroyed the crafting screen so K no longer opened it, and closing the
-- trade window under the game is the likely cause of two crashes (2026-10-28).
local PANELS = {
  ["containerInventory.swf"] = "loot window", ["partyInventory.swf"] = "inventory", ["characterSheet.swf"] = "character sheet",
  ["book.swf"] = "book", ["gameMenu.swf"] = "pause menu",
}
-- Proper close calls first: hideUI only hides a panel, and the game may then think it is still open (a hidden book
-- screen blocked every later read). hideUI is the last resort.
-- (Close-call guessing was removed: see tidy_ui.)

local function isVisible(ui)
  local ok, v = pcall(function () return ui.OF_Visible end)
  return ok and v == true
end

BridgeShown = BridgeShown or {}   -- panel file -> true while the bridge has it on screen

--- Close every open panel from PANELS and say which ones were closed.
function ClientHandlers.tidy_ui()
  local closed = {}
  for typeId = 0, 200 do
    local ok, ui = pcall(Ext.UI.GetByType, typeId)
    if ok and ui ~= nil and isVisible(ui) then
      local file = tostring(ui.Path):match("[^/\\]+$")
      local label = PANELS[file]
      if label then
        -- The loot window, the inventory and the character sheet are hidden with their own hideUI call (closeUI on them
        -- left the game's state dangling or destroyed the screen). Everything else gets closeUI, the one close call known
        -- to work (books). Two things crashed the game and are not used: guessing other close-call names, and the
        -- engine's ui:Hide() (crash in the character sheet's own code, 2026-10-26, when a sheet the player had opened was
        -- hidden that way).
        local hideOnly = file == "containerInventory.swf" or file == "partyInventory.swf" or file == "characterSheet.swf"
        -- The inventory and character sheet are left alone when the watching player opened them; only screens the bridge
        -- showed (show_inventory / show_sheet) are put away again.
        local playersOwn = (file == "partyInventory.swf" or file == "characterSheet.swf") and not BridgeShown[file]
        if not playersOwn then
          pcall(function () ui:ExternalInterfaceCall(hideOnly and "hideUI" or "closeUI") end)
          BridgeShown[file] = nil
        end
        if not playersOwn then closed[#closed + 1] = isVisible(ui) and (label .. " (could not close)") or label end
      end
    end
  end
  return closed
end

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

-- Camera: the player's game camera can be pointed, zoomed (within the game's own limit) and rotated. The server
-- checks fair play first (only visible objects or explored ground), the client moves the camera.
local function gameCamera()
  local ok, cams = pcall(function () return Ext.Client.GetCameraManager().Controllers end)
  if not ok or cams == nil then error("No game camera") end
  local cam = cams["GameCamera_player0"]
  if cam == nil then error("No game camera") end
  return cam
end

function ClientHandlers.camera(args)
  local cam = gameCamera()
  if args.x and args.z then cam.TargetLookAt = { args.x, args.y or cam.TargetLookAt[2], args.z } end
  if args.zoom then cam.TargetCameraDistance = args.zoom end
  if args.rotation then cam.Rotation = args.rotation % 360 end
  if args.turn then cam.Rotation = (cam.Rotation + args.turn) % 360 end
  return { look_at = cam.TargetLookAt, zoom = cam.TargetCameraDistance, rotation = cam.Rotation }
end

-- Minimap (UI type 30): what the player sees on it. Before each full redraw ("update" with false) the game fills
-- map_mc's add_icons with groups of five numbers: the object's handle (bit-cast to a double), icon type, x, y, and the
-- icon's rotation. Seen so far: type 11 = you, 1 = an enemy, 3 = a person nearby (shown even behind walls, as the minimap does).
-- Only what the minimap draws is kept, so nothing here goes beyond what the player can see on screen.
local MINIMAP_UI = 30
local ICON_KIND = { [1] = "enemy", [3] = "person", [11] = "you" }
MinimapIcons = MinimapIcons or {}

local function recordMinimap(e)
  if e.When ~= "Before" or e.Function ~= "update" or e.Args[1] ~= false or e.UI:GetTypeId() ~= MINIMAP_UI then return end
  local a = e.UI:GetRoot().add_icons
  if a == nil then return end
  local icons = {}
  for i = 0, a.length - 5, 5 do
    local handle = string.unpack("<i8", string.pack("<d", a[i]))
    icons[#icons + 1] = { handle = handle, type = a[i + 1], x = a[i + 2], y = a[i + 3] }
  end
  MinimapIcons = icons
end
subscribe(Ext.Events.UIInvoke, function (e) pcall(recordMinimap, e) end)

--- The minimap's icons with the object each one stands for: name, GUID and position.
function ClientHandlers.minimap()
  local out = {}
  for _, icon in ipairs(MinimapIcons) do
    local entry = { kind = ICON_KIND[icon.type] or ("marker type " .. tostring(icon.type)), mx = icon.x, my = icon.y }
    if icon.handle ~= 0 then
      local obj = nil
      pcall(function () obj = Ext.Entity.GetGameObject(Ext.Utils.IntegerToHandle(icon.handle)) end)
      if obj then
        pcall(function () entry.name = obj.DisplayName end)
        pcall(function () entry.guid = obj.MyGuid end)
        pcall(function () local p = obj.WorldPos; entry.x, entry.y, entry.z = p[1], p[2], p[3] end)
      end
    end
    out[#out + 1] = entry
  end
  return out
end

-- Show the inventory the way the I key does: the character sheet (equipment slots) on the left and the party bags on the
-- right, so a watcher can follow item handling. The inventory screen can always be shown. The character sheet crashed the
-- game when forced open before the game had ever filled it in (a bad copy in its own data code, 2026-10-26), so it is only
-- shown once the game has sent it its data (updateItems logged), i.e. after the player has pressed I once. The next tool
-- call's tidy_ui hides both again (hideUI: closing them with closeUI seems to destroy them).
local INVENTORY_UI, SHEET_UI = 116, 119
local function sheetFilledIn()
  for _, e in ipairs(UILog) do
    if e.ui == SHEET_UI and e.fn == "updateItems" then return true end
  end
  return false
end
function ClientHandlers.show_inventory()
  local ui = Ext.UI.GetByType(INVENTORY_UI)
  if ui == nil then error("No inventory screen") end
  local sheet = Ext.UI.GetByType(SHEET_UI)
  local sheetShown = false
  if sheet ~= nil and sheetFilledIn() then
    sheet:Show(); sheetShown = true; BridgeShown["characterSheet.swf"] = true
    -- Items equipped by script do not redraw the equipment slots by themselves (a hand-made equip sends updateItems).
    pcall(function () sheet:GetRoot().updateItems() end)
    pcall(function () sheet:GetRoot().stats_mc.ClickTab(0) end)   -- always the attributes tab, next to the equipment
  end
  ui:Show()
  BridgeShown["partyInventory.swf"] = true
  return { visible = ui.OF_Visible, sheet = sheetShown }
end

--- Show the character sheet on one of its tabs (0 attributes, 1 combat abilities, 2 civil abilities, 3 talents, 4 traits)
--- for a watcher, e.g. while points are being spent. Same guard as show_inventory: only once the game has filled the sheet
--- in. ClickTab is the sheet's own tab-button handler (selectTab alone changes only the title).
function ClientHandlers.show_sheet(args)
  local sheet = Ext.UI.GetByType(SHEET_UI)
  if sheet == nil or not sheetFilledIn() then error("No character sheet") end
  sheet:Show()
  BridgeShown["characterSheet.swf"] = true
  pcall(function () sheet:GetRoot().updateItems() end)
  pcall(function () sheet:GetRoot().stats_mc.ClickTab(args.tab or 0) end)
  return { visible = sheet.OF_Visible, tab = args.tab or 0 }
end

--- What the bridge does on the client after every tool call, in one round trip: dismiss tutorial boxes (returning their
--- text) and put away panels left open (returning their names).
function ClientHandlers.post_tool()
  local shown, closed = {}, {}
  pcall(function () shown = ClientHandlers.tutorials() end)
  pcall(function () closed = ClientHandlers.tidy_ui() end)
  return { tutorials = shown, closed = closed }
end
