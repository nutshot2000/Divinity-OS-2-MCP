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
  local okOrder, order = pcall(function () return Ext.Entity.GetCombat(id):GetCurrentTurnOrder() end)
  if okOrder and order then
    for i, team in ipairs(order) do
      local c = team.Character
      if c and not seen[c.MyGuid] then
        seen[c.MyGuid] = true
        if c.MyGuid == me.MyGuid or c.IsPlayer or CanSeeObject(me, c) then fighters[#fighters + 1] = fighter(me, c, i) end
      end
    end
  end
  return {
    in_combat = true, combat_id = id,
    active = active and nameOfGuid(active), my_turn = active ~= nil and BareGuid(active) == BareGuid(me.MyGuid),
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
    if skill.IsLearned then
      local ok, st = pcall(Ext.Stats.Get, id, nil, false)
      if ok and st then
        out[#out + 1] = {
          id = id, name = translated(st.DisplayName, id), memorised = skill.IsActivated,
          ap = st.ActionPoints, cooldown_turns = st.Cooldown,
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
  if not CanSeeObject(me, target) then error((NameOf(target) or "That") .. " is not in sight") end
  Osi.CharacterAttack(me.MyGuid, target.MyGuid)
  return { attacking = NameOf(target), ap_before = me.Stats.CurrentAP }
end

function Handlers.cast(args)
  local me = ActiveChar()
  needMyTurn(me)
  local skill = me.SkillManager.Skills[args.skill]
  if skill == nil or not skill.IsLearned then error("Unknown skill " .. tostring(args.skill) .. " (see dos2_skills)") end
  if not skill.IsActivated then error(args.skill .. " is not memorised") end
  if (skill.ActiveCooldown or 0) > 0 then error(args.skill .. " is on cooldown") end
  if args.target then
    local target = GetChar(args.target) or GetItem(args.target)
    if target == nil then error("No target with GUID " .. tostring(args.target)) end
    if not CanSeeObject(me, target) and target.MyGuid ~= me.MyGuid then error((NameOf(target) or "That") .. " is not in sight") end
    -- CharacterUseSkill(character, skill, target, forceResetCooldown, ignoreHasSkill, ignoreChecks)
    Osi.CharacterUseSkill(me.MyGuid, args.skill, target.MyGuid, 0, 0, 0)
    return { casting = args.skill, at = NameOf(target), ap_before = me.Stats.CurrentAP }
  end
  local grid = Ext.Entity.GetAiGrid()
  local y = (grid and grid:GetHeight(args.x, args.z)) or me.WorldPos[2]
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
