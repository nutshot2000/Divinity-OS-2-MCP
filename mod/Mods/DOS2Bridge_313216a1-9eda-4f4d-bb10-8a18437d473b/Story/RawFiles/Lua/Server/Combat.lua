-- Combat handlers: the turn order, the active character's skills, and attacking, casting and ending the turn through
-- the game's own commands, with every rule check left on (AP, cooldowns, range, memorised skills).
-- Fair play: combatants are listed only if the active character can see them; skill details are what the tooltip
-- shows.

CombatLog = CombatLog or {}
CombatLogSeq = CombatLogSeq or 0

local function logCombat(entry)
  CombatLogSeq = CombatLogSeq + 1
  entry.seq = CombatLogSeq
  CombatLog[#CombatLog + 1] = entry
  if #CombatLog > 200 then table.remove(CombatLog, 1) end
end

local function nameOfGuid(g)
  local c = GetChar(g)
  if c then return NameOf(c) or "someone" end
  local i = GetItem(g)
  return i and NameOf(i) or "something"
end

-- Osiris listeners are registered once (a hot reload re-runs this file).
if not CombatListenersRegistered then
  CombatListenersRegistered = true
  Ext.Osiris.RegisterListener("SkillCast", 4, "after", function (char, skill)
    pcall(logCombat, { event = "cast", who = nameOfGuid(char), skill = skill })
  end)
  Ext.Osiris.RegisterListener("CharacterDied", 1, "after", function (char)
    pcall(logCombat, { event = "died", who = nameOfGuid(char) })
  end)
  Ext.Osiris.RegisterListener("ObjectTurnStarted", 1, "after", function (obj)
    pcall(logCombat, { event = "turn", who = nameOfGuid(obj) })
  end)
  Ext.Osiris.RegisterListener("CombatEnded", 1, "after", function ()
    pcall(logCombat, { event = "combat ended" })
  end)
end

local function combatId(me)
  local id = Osiq("CombatGetIDForCharacter", me.MyGuid)
  if id == nil or id == 0 then return nil end
  return id
end

local function fighter(me, c, order)
  local s = c.Stats
  local p = Pos(c)
  return {
    order = order, name = NameOf(c) or "someone", guid = c.MyGuid, tags = CharacterTags(me.MyGuid, c),
    hp = s and s.CurrentVitality, max_hp = s and s.MaxVitality,
    armor = s and s.CurrentArmor, magic_armor = s and s.CurrentMagicArmor, ap = s and s.CurrentAP,
    x = p.x, z = p.z, dist = Dist(Pos(me), p), statuses = c:GetStatuses(),
    -- The weapon hit chance the game shows on hover (spells always hit); the game's own formula.
    hit_chance = c.MyGuid ~= me.MyGuid and (function ()
      local ok, v = pcall(Game.Math.CalculateHitChance, me.Stats, c.Stats)
      return ok and v or nil
    end)() or nil,
  }
end

function Handlers.combat(args)
  local me = ActiveChar()
  local id = combatId(me)
  local log = {}
  for _, e in ipairs(CombatLog) do if e.seq > (args.since or 0) then log[#log + 1] = e end end
  if id == nil then return { in_combat = false, log = log, log_last = CombatLogSeq } end

  local active = Osiq("CombatGetActiveEntity", id)
  local fighters, seen = {}, {}
  -- The current order only holds who is still to act this round; whoever already acted is in the next round's order.
  local n = 0
  for _, which in ipairs({ "GetCurrentTurnOrder", "GetNextTurnOrder" }) do
    local okOrder, order = pcall(function () local cb = Ext.Entity.GetCombat(id); return cb[which](cb) end)
    if okOrder and order then
      for _, team in ipairs(order) do
        local c = team.Character
        if c and not seen[c.MyGuid] then
          seen[c.MyGuid] = true
          n = n + 1
          if c.MyGuid == me.MyGuid or c.IsPlayer or CanSeeObject(me, c) then fighters[#fighters + 1] = fighter(me, c, n) end
        end
      end
    end
  end
  return {
    in_combat = true, combat_id = id,
    active = active and nameOfGuid(active), active_guid = active, my_turn = active ~= nil and BareGuid(active) == BareGuid(me.MyGuid),
    -- Any party member's turn (the bridge switches to them, so a party of three does not wait for one member's turn).
    party_turn = active ~= nil and Osiq("CharacterIsPartyMember", active) == 1,
    me = fighter(me, me, 0), fighters = fighters, log = log, log_last = CombatLogSeq,
  }
end

local function translated(handle, fallback)
  if handle == nil or handle == "" then return fallback end
  local ok, s = pcall(Ext.L10N.GetTranslatedStringFromKey, handle)
  if ok and s ~= nil and s ~= "" then return s end
  return fallback
end

-- Skill requirements (stat "Requirement") and the equipment check that meets them, as the tooltip's
-- "Requires a shield" line shows.
local REQUIREMENTS = {
  ShieldWeapon = { text = "needs a shield", slot = "Shield" },
  MeleeWeapon = { text = "needs a melee weapon", slot = "Weapon" },
  RangedWeapon = { text = "needs a bow or crossbow", slot = "Weapon" },
  DaggerWeapon = { text = "needs a dagger", slot = "Weapon" },
  StaffWeapon = { text = "needs a staff", slot = "Weapon" },
  RifleWeapon = { text = "needs a rifle", slot = "Weapon" },
}

local function requirementMet(me, req)
  local r = REQUIREMENTS[req]
  if r == nil then return nil end
  local g = Osiq("CharacterGetEquippedItem", me.MyGuid, r.slot)
  return { text = r.text, met = g ~= nil and g ~= "" }
end

--- The active character's skills, as the hotbar and tooltips show them.
function Handlers.skills()
  local me = ActiveChar()
  local out = {}
  for id, skill in pairs(me.SkillManager.Skills) do
    -- Skills granted by equipment or statuses are activated without being "learned"; the hotbar shows them too.
    if skill.IsLearned or skill.IsActivated then
      local ok, st = pcall(Ext.Stats.Get, id, nil, false)
      if ok and st then
        out[#out + 1] = {
          id = id, name = translated(st.DisplayName, id), memorised = skill.IsActivated,
          granted = not skill.IsLearned or nil,
          ap = st.ActionPoints, source = (st["Magic Cost"] or 0) > 0 and st["Magic Cost"] or nil, cooldown_turns = st.Cooldown,
          cooldown_left = math.ceil((skill.ActiveCooldown or 0) / 6),
          range = st.TargetRadius ~= 0 and st.TargetRadius or st.Range, area = st.AreaRadius ~= 0 and st.AreaRadius or st.ExplodeRadius,
          type = st.SkillType, damage_type = st.DamageType ~= "None" and st.DamageType or nil,
          targets = { characters = st.CanTargetCharacters == "Yes", items = st.CanTargetItems == "Yes",
            ground = st.CanTargetTerrain == "Yes" },
          description = translated(st.Description, nil),
          requirement = requirementMet(me, st.Requirement),
        }
      end
    end
  end
  table.sort(out, function (a, b) return a.id < b.id end)
  return out
end

local function needMyTurn(me)
  local id = combatId(me)
  if id == nil then return end -- out of combat, actions happen in real time
  local active = Osiq("CombatGetActiveEntity", id)
  if active == nil or BareGuid(active) ~= BareGuid(me.MyGuid) then
    error("Not " .. (NameOf(me) or "your") .. "'s turn: wait for it (dos2_end_turn waits too)")
  end
end

function Handlers.attack(args)
  local me = ActiveChar()
  needMyTurn(me)
  local target = GetChar(args.target) or GetItem(args.target)
  if target == nil then error("No target with GUID " .. tostring(args.target)) end
  if target.Dead then error((NameOf(target) or "That") .. " is already dead: pick another target") end
  if not CanSeeObject(me, target) then error((NameOf(target) or "That") .. " is not in sight") end
  Osi.CharacterAttack(me.MyGuid, target.MyGuid)
  return { attacking = NameOf(target), ap_before = me.Stats.CurrentAP }
end

-- Teleportation skills (Gloves of Teleportation) take two clicks in the game: the character or item to move, then where it
-- lands. Osiris can only aim a skill at one thing, so the cast is aimed at the landing spot and the skill's own state is
-- given the thing to move on the next tick (esv::SkillStateTeleportation: SourceHandle/SourcePosition = what moves,
-- TargetPosition = where). Learned live 2026-10-27: with TargetPosition left empty the target landed at 0,0, so both are
-- always set together, and the cast is cancelled if that fails.
if TeleportTick ~= nil then pcall(function () Ext.Events.Tick:Unsubscribe(TeleportTick) end) end
TeleportPending = nil
TeleportTick = Ext.Events.Tick:Subscribe(function ()
  local p = TeleportPending
  if p == nil then return end
  p.ticks = p.ticks + 1
  if p.ticks > 120 then TeleportPending = nil; return end -- the cast never started (refused by the game)
  local okS, st = pcall(function () return Ext.Entity.GetCharacter(p.caster).SkillManager.CurrentSkillState end)
  if not okS or st == nil then return end
  local ok = pcall(function ()
    local t = GetChar(p.target) or GetItem(p.target)
    local tp = t.WorldPos
    st.SourceHandle = t.Handle
    st.SourcePosition = { tp[1], tp[2], tp[3] }
    st.TargetPosition = { p.x, p.y, p.z }
  end)
  if not ok then pcall(function () st.RequestExit = true end) end
  TeleportPending = nil
end)

local function teleport(me, args, st, fromItem)
  if args.target == nil or args.x == nil or args.z == nil then
    error(args.skill .. " needs target (the character, item or body to move) and x,z (where it lands)")
  end
  local target = GetChar(args.target) or GetItem(args.target)
  if target == nil then error("No target with GUID " .. tostring(args.target)) end
  if target.MyGuid == me.MyGuid then error("Teleportation cannot move its caster: another party member has to cast it on you") end
  if not CanSeeObject(me, target) then error((NameOf(target) or "That") .. " is not in sight") end
  local reach = (st.TargetRadius or 0) > 0 and st.TargetRadius or 13
  local area = (st.AreaRadius or 0) > 0 and st.AreaRadius or reach
  local from = Pos(target)
  local d = Dist(Pos(me), from)
  if d > reach then error(string.format("%s is %.1f m away; the skill reaches %d m", NameOf(target) or "That", d, reach)) end
  local land = { x = args.x, z = args.z }
  local dl = Dist(from, land)
  if dl > area then error(string.format("That spot is %.1f m from %s; it can land at most %d m away", dl, NameOf(target) or "it", area)) end
  if GetChar(args.target) then
    for _, s in ipairs({ "FORTIFIED", "GROUNDED" }) do
      if Osiq("HasActiveStatus", target.MyGuid, s) == 1 then error((NameOf(target) or "That") .. " is " .. s:lower() .. " and cannot be teleported") end
    end
  end
  local grid = Ext.Entity.GetAiGrid()
  local cell = grid and GridCell(grid, args.x, args.z)
  if cell == nil or HasFlag(cell.AiFlags, "MovementBlock") then error("Nothing can stand at " .. args.x .. "," .. args.z .. ": pick open ground") end
  -- Only ground the player could click: seen already (or close by), and not fogged.
  if Shrouded(args.x, args.z) or (Unexplored(args.x, args.z) and Dist(Pos(me), land) > 14) then
    error("You have not seen the ground at " .. args.x .. "," .. args.z .. " yet")
  end
  local y = GridHeight(grid, args.x, args.z) or from.y
  TeleportPending = { caster = me.MyGuid, target = target.MyGuid, x = args.x, y = y, z = args.z, ticks = 0 }
  -- A scroll (Resurrection is a teleport-type skill: pick the body, then where it stands up) grants its skill: ignoreHasSkill.
  Osi.CharacterUseSkillAtPosition(me.MyGuid, args.skill, args.x, y, args.z, 0, fromItem and 1 or 0)
  return { casting = args.skill, moving = NameOf(target), at = land, ap_before = me.Stats.CurrentAP }
end

function Handlers.cast(args)
  local me = ActiveChar()
  needMyTurn(me)
  local skill = me.SkillManager.Skills[args.skill]
  if skill == nil or not (skill.IsLearned or skill.IsActivated) then
    error("Unknown skill " .. tostring(args.skill) .. " (see dos2_skills)")
  end
  if not skill.IsActivated then error(args.skill .. " is not memorised") end
  if (skill.ActiveCooldown or 0) > 0 then error(args.skill .. " is on cooldown") end
  -- Source skills cost Source Points; the game ignores the cast silently when there are none (Break the Shackles did).
  local okCost, cost = pcall(function () return Ext.Stats.Get(args.skill)["Magic Cost"] end)
  if okCost and type(cost) == "number" and cost > 0 then
    local have = Osiq("CharacterGetSourcePoints", me.MyGuid) or 0
    if have < cost then error(args.skill .. " needs " .. cost .. " Source Point" .. (cost > 1 and "s" or "") .. " and you have " .. have) end
  end
  local okSt, stats = pcall(Ext.Stats.Get, args.skill)
  if okSt and stats and stats.SkillType == "Teleportation" then return teleport(me, args, stats) end
  if args.target then
    local target = GetChar(args.target) or GetItem(args.target)
    if target == nil then error("No target with GUID " .. tostring(args.target)) end
    if not CanSeeObject(me, target) and target.MyGuid ~= me.MyGuid then error((NameOf(target) or "That") .. " is not in sight") end
    -- CharacterUseSkill(character, skill, target, forceResetCooldown, ignoreHasSkill, ignoreChecks)
    Osi.CharacterUseSkill(me.MyGuid, args.skill, target.MyGuid, 0, 0, 0)
    return { casting = args.skill, at = NameOf(target), ap_before = me.Stats.CurrentAP }
  end
  local grid = Ext.Entity.GetAiGrid()
  local y = GridHeight(grid, args.x, args.z) or me.WorldPos[2]
  -- CharacterUseSkillAtPosition(character, skill, x, y, z, forceResetCooldown, ignoreHasSkill)
  Osi.CharacterUseSkillAtPosition(me.MyGuid, args.skill, args.x, y, args.z, 0, 0)
  return { casting = args.skill, at = { x = args.x, z = args.z }, ap_before = me.Stats.CurrentAP }
end

function Handlers.end_turn()
  local me = ActiveChar()
  needMyTurn(me)
  Osi.EndTurn(me.MyGuid)
  return { ended = NameOf(me) }
end


--- The skill an item fires when used (grenades, scrolls), from its template's use actions.
local function itemSkill(item)
  local t = item.CurrentTemplate or item.RootTemplate
  local ok, acts = pcall(function () return t.OnUsePeaceActions end)
  if ok and acts then
    for _, a in ipairs(acts) do
      if tostring(a.Type) == "UseSkill" and a.SkillID then return a.SkillID end
    end
  end
  return nil
end

local function aimPoint(me, args)
  if args.target then
    local t = GetChar(args.target) or GetItem(args.target)
    if t == nil then error("No target with GUID " .. tostring(args.target)) end
    if t.MyGuid ~= me.MyGuid and not CanSeeObject(me, t) then error((NameOf(t) or "That") .. " is not in sight") end
    local p = Pos(t)
    return p.x, p.z, t
  end
  if args.x == nil or args.z == nil then error("Give a target GUID, or x and z") end
  return args.x, args.z, nil
end

--- Who a skill (or an item's skill) would hit if aimed here, like the game's targeting preview: everyone visible in
--- its area (allies too), and whether the aim point is in range.
function Handlers.skill_preview(args)
  local me = ActiveChar()
  local skillId = args.skill
  if args.item then
    local item = GetItem(args.item)
    skillId = item and itemSkill(item)
    if skillId == nil then error("That item has no skill to use") end
  end
  local st = Ext.Stats.Get(skillId, nil, false)
  if st == nil then error("Unknown skill " .. tostring(skillId)) end
  local x, z = aimPoint(me, args)
  local mp = Pos(me)
  local range = (st.TargetRadius ~= 0 and st.TargetRadius) or st.Range or 0
  local area = (st.AreaRadius ~= 0 and st.AreaRadius) or st.ExplodeRadius or 0
  local cone = st.SkillType == "Cone"
  local aimDist = math.sqrt((x - mp.x) ^ 2 + (z - mp.z) ^ 2)
  local hits = {}
  for _, g in ipairs(Ext.Entity.GetCharacterGuidsAroundPosition(x, mp.y, z, math.max(area, range) + 2)) do
    local c = GetChar(g)
    if c and not c.Dead and c.MyGuid ~= me.MyGuid and CanSeeObject(me, c) then
      local cp = Pos(c)
      local hit
      if cone then
        -- in front of the caster, within range and the cone's angle
        local ax, az, cx, cz = x - mp.x, z - mp.z, cp.x - mp.x, cp.z - mp.z
        local la, lc = math.sqrt(ax * ax + az * az), math.sqrt(cx * cx + cz * cz)
        local half = math.rad((st.Angle or 60) / 2)
        hit = lc <= range and la > 0 and lc > 0 and math.acos(math.max(-1, math.min(1, (ax * cx + az * cz) / (la * lc)))) <= half
      elseif area > 0 then
        hit = math.sqrt((cp.x - x) ^ 2 + (cp.z - z) ^ 2) <= area
      else
        hit = args.target ~= nil and BareGuid(c.MyGuid) == BareGuid(args.target)
      end
      if hit then hits[#hits + 1] = { name = NameOf(c) or "someone", tags = CharacterTags(me.MyGuid, c) } end
    end
  end
  return { skill = skillId, ap = st.ActionPoints, range = range, area = area, cone = cone or nil,
    in_range = cone or range == 0 or aimDist <= range + 0.5, aim_dist = Round(aimDist), hits = hits }
end

--- Throw or read an item at a target or a spot: casts the item's skill (the game checks AP, range and line of sight).
--- consume_item uses up one item afterwards, only once the cast has actually happened.
function Handlers.use_item(args)
  local me = ActiveChar()
  needMyTurn(me)
  local item = GetItem(args.item)
  if item == nil then error("No item with GUID " .. tostring(args.item)) end
  local owner = Osiq("GetInventoryOwner", item.MyGuid)
  if owner == nil or BareGuid(owner) ~= BareGuid(me.MyGuid) then error((NameOf(item) or "That") .. " is not in your inventory") end
  local skillId = itemSkill(item)
  if skillId == nil then error((NameOf(item) or "That") .. " cannot be thrown or cast: use dos2_use to drink, eat or read it") end
  local okSt, ist = pcall(Ext.Stats.Get, skillId)
  if okSt and ist and ist.SkillType == "Teleportation" then
    local r = teleport(me, { skill = skillId, target = args.target, x = args.x, z = args.z }, ist, true)
    r.using, r.skill, r.template = NameOf(item), skillId, Osiq("GetTemplate", item.MyGuid)
    return r
  end
  local x, z, t = aimPoint(me, args)
  if t then
    -- CharacterUseSkill(character, skill, target, forceResetCooldown, ignoreHasSkill, ignoreChecks): the item grants the skill
    Osi.CharacterUseSkill(me.MyGuid, skillId, t.MyGuid, 0, 1, 0)
  else
    local grid = Ext.Entity.GetAiGrid()
    local y = GridHeight(grid, x, z) or me.WorldPos[2]
    Osi.CharacterUseSkillAtPosition(me.MyGuid, skillId, x, y, z, 0, 1)
  end
  return { using = NameOf(item), skill = skillId, template = Osiq("GetTemplate", item.MyGuid), ap_before = me.Stats.CurrentAP }
end

function Handlers.consume_item(args)
  local me = ActiveChar()
  Osi.ItemTemplateRemoveFrom(args.template, me.MyGuid, 1)
  return { consumed = args.template }
end

--- Flee: the game offers it ("You're in a tight spot. Flee, if you wish.") when the party is outnumbered. Leaves combat
--- for every living party member. Only allowed while outnumbered, like the game's own prompt; enemies stay hostile.
function Handlers.flee()
  local me = ActiveChar()
  local id = combatId(me)
  if id == nil then error("Not in combat: nothing to flee from") end
  local enemies = 0
  local okOrder, order = pcall(function () return Ext.Entity.GetCombat(id):GetCurrentTurnOrder() end)
  local seen = {}
  local function count(list)
    for _, team in ipairs(list or {}) do
      local c = team.Character
      if c and not seen[c.MyGuid] then
        seen[c.MyGuid] = true
        if not c.Dead and Osiq("CharacterIsEnemy", me.MyGuid, c.MyGuid) == 1 then enemies = enemies + 1 end
      end
    end
  end
  if okOrder then count(order) end
  local okNext, nextOrder = pcall(function () local cb = Ext.Entity.GetCombat(id); return cb:GetNextTurnOrder() end)
  if okNext then count(nextOrder) end
  local party = {}
  for _, g in ipairs(PartyGuids()) do
    local c = GetChar(g)
    if c and not c.Dead then party[#party + 1] = c end
  end
  if enemies <= #party then
    error("Not outnumbered (" .. enemies .. " enemies, " .. #party .. " of you alive): fight on. Fleeing is only allowed when outnumbered, as in the game.")
  end
  for _, c in ipairs(party) do Osi.LeaveCombat(c.MyGuid) end
  return { fled = true, enemies = enemies, party = #party }
end
