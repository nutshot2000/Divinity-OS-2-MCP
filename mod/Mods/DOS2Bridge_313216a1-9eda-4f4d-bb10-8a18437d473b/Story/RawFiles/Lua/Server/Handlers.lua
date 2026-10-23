-- Command handlers: Handlers[cmd](args) returns a JSON-able value or raises an error.
Handlers = Handlers or {}  -- kept across hot reloads, so reloading this file leaves Grid.lua's handlers in place

function Handlers.ping()
  return { pong = true, level = CurrentLevelName(), time = Ext.Utils.MonotonicTime() }
end

local function charSummary(c)
  local s = c.Stats
  local p = Pos(c)
  return {
    name = NameOf(c), guid = c.MyGuid, x = p.x, y = p.y, z = p.z,
    level = s and s.Level, hp = s and s.CurrentVitality, max_hp = s and s.MaxVitality,
    armor = s and s.CurrentArmor, magic_armor = s and s.CurrentMagicArmor,
    ap = s and s.CurrentAP, dead = c.Dead, in_dialog = c.InDialog,
    in_combat = Osiq("CharacterIsInCombat", c.MyGuid) == 1,
  }
end

function Handlers.status()
  local active = ActiveChar()
  local party = {}
  for _, g in ipairs(PartyGuids()) do
    local c = GetChar(g)
    if c then party[#party + 1] = charSummary(c) end
  end
  return { level = active.CurrentLevel, active = NameOf(active), active_guid = active.MyGuid, party = party }
end

local function characterTags(me, c)
  local tags = {}
  local g = c.MyGuid
  if c.Dead then tags[#tags + 1] = "dead" end
  if c.IsPlayer or c.InParty then tags[#tags + 1] = "party"
  elseif Osiq("CharacterIsEnemy", me, g) == 1 then tags[#tags + 1] = "enemy"
  elseif Osiq("CharacterIsAlly", me, g) == 1 then tags[#tags + 1] = "ally" end
  if c.Trader then tags[#tags + 1] = "trader" end
  if c.InDialog then tags[#tags + 1] = "in dialogue" end
  if Osiq("CharacterIsInCombat", g) == 1 then tags[#tags + 1] = "in combat" end
  return tags
end

local function itemTags(i)
  local tags = {}
  local g = i.MyGuid
  if Osiq("ItemIsContainer", g) == 1 then tags[#tags + 1] = "container" end
  -- Only what hovering shows: "locked". Which key opens it is not something a player knows.
  if Osiq("ItemIsLocked", g) == 1 then tags[#tags + 1] = "locked" end
  if Osiq("ItemIsDestroyed", g) == 1 then tags[#tags + 1] = "destroyed" end
  if (i.Amount or 1) > 1 then tags[#tags + 1] = "x" .. i.Amount end
  return tags
end

--- Fair play: skip objects the player could not see. Off-stage (story-hidden), inventory items, and anything with a
--- wall between it and the active character. Perception-hidden items and sneaking characters: see docs/design.md.
local function visibleItem(i)
  if i.OffStage then return false end
  if Osiq("GetInventoryOwner", i.MyGuid) ~= nil then return false end
  return true
end

local EYE_HEIGHT = 1.5
local losWorks = nil  -- nil until the first raycast tells us whether the vision grid is usable

--- Could a player see this object right now? The engine's own CharacterCanSee first (covers walls, sneaking and
--- invisibility); a vision-grid raycast if that query fails. Anything under fog of war is never visible.
local function inSight(me, obj)
  local p = obj.WorldPos
  if Shrouded(p[1], p[3]) then return false end
  local seen = Osiq("CharacterCanSee", me.MyGuid, obj.MyGuid)
  if seen ~= nil then losWorks = true; return seen == 1 end
  local vision = Ext.Entity.GetVisionGrid and Ext.Entity.GetVisionGrid()
  if vision == nil then losWorks = false; return true end
  local a, b = me.WorldPos, obj.WorldPos
  local ok, hit = pcall(function ()
    return vision:RaycastToPosition({ a[1], a[2] + EYE_HEIGHT, a[3] }, { b[1], b[2] + 0.5, b[3] },
      Ext.Enums.VisionFlags.VisionBlock)
  end)
  if not ok then losWorks = false; return true end
  losWorks = true
  return not HasFlag(hit, "VisionBlock")
end

-- Shared with Combat.lua.
CharacterTags = characterTags
CanSeeObject = inSight

function Handlers.look(args)
  local me = ActiveChar()
  local from = Pos(me)
  local radius = args.radius or 20
  local limit = args.limit or 40
  local kind = args.kind or "all"
  local out = { level = me.CurrentLevel, radius = radius,
    from = { name = NameOf(me), x = from.x, y = from.y, z = from.z } }

  local function collect(guids, get, keep, tagger)
    local list = {}
    for _, g in ipairs(guids or {}) do
      local o = get(g)
      if o ~= nil and o.MyGuid ~= me.MyGuid and NameOf(o) ~= nil and keep(o) and inSight(me, o) then
        local p = Pos(o)
        list[#list + 1] = { name = NameOf(o), guid = o.MyGuid, x = p.x, z = p.z, dist = Dist(from, p), tags = tagger(o) }
      end
    end
    table.sort(list, function (a, b) return a.dist < b.dist end)
    if #list > limit then
      out.truncated = true
      for k = #list, limit + 1, -1 do list[k] = nil end
    end
    return list
  end

  if kind ~= "items" then
    out.characters = collect(Ext.Entity.GetCharacterGuidsAroundPosition(from.x, from.y, from.z, radius), GetChar,
      function (c) return not c.OffStage end, function (c) return characterTags(me.MyGuid, c) end)
  end
  if kind ~= "characters" then
    out.items = collect(Ext.Entity.GetItemGuidsAroundPosition(from.x, from.y, from.z, radius), GetItem,
      visibleItem, itemTags)
  end
  -- If raycasts fail, say so rather than silently listing things behind walls as if they were seen.
  if losWorks == false then out.warning = "Line-of-sight check unavailable: some listed objects may be out of sight." end
  return out
end

local moveSeq = 0

function Handlers.move(args)
  local me = ActiveChar()
  moveSeq = moveSeq + 1
  local event = "DOS2Bridge_move_" .. moveSeq
  Arrivals[event] = nil
  local running = args.run and 1 or 0
  if args.target then
    -- CharacterMoveTo(character, target, running, event, increaseSpeed)
    Osi.CharacterMoveTo(me.MyGuid, args.target, running, event, 0)
  else
    local grid = Ext.Entity.GetAiGrid()
    local y = (grid and grid:GetHeight(args.x, args.z)) or me.WorldPos[2]
    -- CharacterMoveToPosition(character, x, y, z, running, event)
    Osi.CharacterMoveToPosition(me.MyGuid, args.x, y, args.z, running, event)
  end
  Moves[event] = { target = args.target, x = args.x, z = args.z }
  return { event = event }
end

function Handlers.move_status(args)
  local me = ActiveChar()
  local p = Pos(me)
  local goal = Moves[args.event] or {}
  local gx, gz = goal.x, goal.z
  if goal.target then
    local t = GetChar(goal.target) or GetItem(goal.target)
    if t then local tp = Pos(t); gx, gz = tp.x, tp.z end
  end
  return {
    arrived = Arrivals[args.event] == true, x = p.x, z = p.z,
    dist_to_goal = gx and Dist(p, { x = gx, z = gz }) or nil,
    in_combat = Osiq("CharacterIsInCombat", me.MyGuid) == 1, in_dialog = me.InDialog,
  }
end

function Handlers.use(args)
  local me = ActiveChar()
  local item = GetItem(args.item)
  if item == nil then error("No item with GUID " .. tostring(args.item)) end
  local event = "DOS2Bridge_use_" .. Ext.Utils.MonotonicTime()
  Uses[BareGuid(item.MyGuid)] = nil
  -- CharacterUseItem(character, item, event)
  Osi.CharacterUseItem(me.MyGuid, item.MyGuid, event)
  return { using = NameOf(item), guid = item.MyGuid, event = event, tags = itemTags(item) }
end

function Handlers.use_status(args)
  local item = GetItem(args.item)
  local me = ActiveChar()
  return {
    result = Uses[BareGuid(args.item)],
    opened = item and Osiq("ItemIsOpened", item.MyGuid) == 1 or false,
    dist = item and Dist(Pos(me), Pos(item)) or nil,
    in_combat = Osiq("CharacterIsInCombat", me.MyGuid) == 1, in_dialog = me.InDialog,
  }
end

--- Talk to a character the way a click does: raise DialogStartRequested(target, player) and let the story pick the
--- dialogue. The caller walks the character close first. Nothing about the dialogue is read here.
function Handlers.talk(args)
  local me = ActiveChar()
  local npc = GetChar(args.target)
  if npc == nil then error("No character with GUID " .. tostring(args.target)) end
  Osi.DialogStartRequested(npc.MyGuid, me.MyGuid)
  return { talking_to = NameOf(npc), dist = Dist(Pos(me), Pos(npc)) }
end

local LOOT_REACH = 3

--- Fair play: a container's contents are only known once it is open and the character stands next to it, as with
--- the loot window in game.
local function openContainer(me, guid)
  local box = GetItem(guid)
  if box == nil then error("No container with GUID " .. tostring(guid)) end
  if Osiq("ItemIsContainer", box.MyGuid) ~= 1 then error(NameOf(box) .. " is not a container") end
  local d = Dist(Pos(me), Pos(box))
  if d > LOOT_REACH then error(NameOf(box) .. " is " .. d .. "m away: walk to it and open it first (dos2_use)") end
  if Osiq("ItemIsOpened", box.MyGuid) ~= 1 then error(NameOf(box) .. " is closed: open it first (dos2_use)") end
  return box
end

--- Who owns an item, from the party's point of view: nil (nobody), "party", or the owner's name.
local function ownerOf(item)
  local owner = Osiq("ItemGetOwner", item.MyGuid)
  if owner == nil or owner == "" or owner == "NULL_00000000-0000-0000-0000-000000000000" then return nil end
  if Osiq("CharacterIsPartyMember", owner) == 1 then return "party" end
  local c = GetChar(owner)
  return c and NameOf(c) or "someone"
end

local function lootEntry(item)
  local owner = ownerOf(item)
  return { name = NameOf(item) or "(unnamed)", guid = item.MyGuid, amount = item.Amount or 1,
    owned_by = owner ~= "party" and owner or nil }
end

function Handlers.loot_list(args)
  local me = ActiveChar()
  local box = openContainer(me, args.container)
  local items = {}
  for _, g in ipairs(box:GetInventoryItems() or {}) do
    local it = GetItem(g)
    if it then items[#items + 1] = lootEntry(it) end
  end
  return { container = NameOf(box), items = items }
end

--- Take items from an open container: all of them, or the listed GUIDs. Items owned by someone else are skipped:
--- taking them is theft, which needs its own, deliberate tool.
function Handlers.loot_take(args)
  local me = ActiveChar()
  local box = openContainer(me, args.container)
  local wanted = nil
  if args.items then
    wanted = {}
    for _, g in ipairs(args.items) do wanted[BareGuid(g)] = true end
  end
  local taken, skipped = {}, {}
  for _, g in ipairs(box:GetInventoryItems() or {}) do
    local it = GetItem(g)
    if it and (wanted == nil or wanted[BareGuid(it.MyGuid)]) then
      local entry = lootEntry(it)
      if entry.owned_by then
        skipped[#skipped + 1] = entry
      else
        Osi.ItemToInventory(it.MyGuid, me.MyGuid, entry.amount, 1, 0)
        taken[#taken + 1] = entry
      end
    end
  end
  return { container = NameOf(box), taken = taken, skipped_owned = skipped }
end

--- Narration: a line of overhead text on the active character, so the watching player sees what is planned.
function Handlers.say(args)
  local me = ActiveChar()
  Osi.CharacterStatusText(me.MyGuid, args.text)
  return { said = args.text, by = NameOf(me) }
end

function Handlers.lua(args)
  -- The extender's restricted load() ignores the env argument, so bind _ENV to the mod table in the source itself.
  local chunk, err = load("local _ENV = Mods.DOS2Bridge\n" .. args.code, "dos2_lua", "t")
  if chunk == nil then error(err) end
  return chunk()
end
