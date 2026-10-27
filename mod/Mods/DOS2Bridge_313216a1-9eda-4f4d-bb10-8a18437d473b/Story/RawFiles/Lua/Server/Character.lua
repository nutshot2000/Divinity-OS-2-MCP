-- Character sheet, levelling and party control. Spending follows the character sheet's rules: only points the
-- character has, within the game's caps (Ext.ExtraData), one point at a time like the + buttons.

local ATTRIBUTES = { "Strength", "Finesse", "Intelligence", "Constitution", "Memory", "Wits" }
local COMBAT_ABILITIES = { "WarriorLore", "RangerLore", "RogueLore", "SingleHanded", "TwoHanded", "Ranged",
  "DualWielding", "Leadership", "Perseverance", "PainReflection", "FireSpecialist", "WaterSpecialist", "AirSpecialist",
  "EarthSpecialist", "Necromancy", "Summoning", "Polymorph" }
local CIVIL_ABILITIES = { "Barter", "Luck", "Persuasion", "Loremaster", "Telekinesis", "Sneaking", "Thievery" }

-- The talents the Definitive Edition's talent screen offers (internal name -> display name). Anything else - race,
-- origin, quest, item and internal talents such as "Rosy-cheeked" (+AP) - cannot be picked. Display names from
-- LeaderLib's LocalizedText.
local TALENT_SCREEN = {
  ExtraSkillPoints = "All Skilled Up", Ambidextrous = "Ambidextrous", RangerLoreArrowRecover = "Arrow Recovery",
  ExtraStatPoints = "Bigger And Better", ResistDead = "Comeback Kid", Demon = "Demon",
  NoAttackOfOpportunity = "Duck Duck Goose", ElementalAffinity = "Elemental Affinity",
  ElementalRanger = "Elemental Ranger", Escapist = "Escapist", Executioner = "Executioner",
  FaroutDude = "Far Out Man", FiveStarRestaurant = "Five-Star Diner", Raistlin = "Glass Cannon",
  SurpriseAttack = "Guerrilla", Perfectionist = "Hothead", IceKing = "Ice King", Leech = "Leech",
  LivingArmor = "Living Armour", LoneWolf = "Lone Wolf", Memory = "Mnemonic", ResurrectToFullHealth = "Morning Person",
  AttackOfOpportunity = "Opportunist", DualWieldingDodging = "Parry Master", AnimalEmpathy = "Pet Pal",
  WarriorLoreNaturalHealth = "Picture Of Health", ViolentMagic = "Savage Sortilege",
  WarriorLoreGrenadeRange = "Slingshot", Stench = "Stench", QuickStep = "The Pawn", Torturer = "Torturer",
  Unstable = "Unstable", WalkItOff = "Walk It Off", WhatARush = "What A Rush", Sadist = "Sadist",
  Gladiator = "Gladiator", Haymaker = "Haymaker", Indomitable = "Indomitable", Jitterbug = "Jitterbug",
  Soulcatcher = "Soulcatcher", MasterThief = "Master Thief", GreedyVessel = "Greedy Vessel",
  MagicCycles = "Magic Cycles",
}
local function pickableTalent(name) return TALENT_SCREEN[name] ~= nil end

local ALL_TALENTS = {}
pcall(function ()
  for name, _ in pairs(Ext.Enums.TalentType) do
    if type(name) == "string" then ALL_TALENTS[#ALL_TALENTS + 1] = name end
  end
end)
table.sort(ALL_TALENTS)

local function member(guid)
  local c = GetChar(guid)
  if c == nil then error("No character with GUID " .. tostring(guid)) end
  if Osiq("CharacterIsPartyMember", c.MyGuid) ~= 1 then error((NameOf(c) or "They") .. " is not in your party") end
  return c
end

local function translated(handle, fallback)
  if handle == nil or handle == "" then return fallback end
  local ok, s = pcall(Ext.L10N.GetTranslatedStringFromKey, handle)
  return (ok and s ~= nil and s ~= "") and s or fallback
end

function Handlers.sheet(args)
  local me = args.character and member(args.character) or ActiveChar()
  local g = me.MyGuid
  local out = {
    name = NameOf(me), guid = g, level = Osiq("CharacterGetLevel", g),
    experience = me.Stats.Experience,
    points = { attribute = Osiq("CharacterGetAttributePoints", g) or 0, combat = Osiq("CharacterGetAbilityPoints", g) or 0,
      civil = Osiq("CharacterGetCivilAbilityPoints", g) or 0, talent = Osiq("CharacterGetTalentPoints", g) or 0 },
    caps = { attribute = Ext.ExtraData.AttributeSoftCap, combat = Ext.ExtraData.CombatAbilityCap,
      civil = Ext.ExtraData.CivilAbilityCap },
    attributes = {}, combat = {}, civil = {}, talents = {}, skills = {},
    free_memory_slots = me.SkillManager.FreeMemorySlots,
  }
  for _, a in ipairs(ATTRIBUTES) do
    out.attributes[a] = { base = Osiq("CharacterGetBaseAttribute", g, a), total = Osiq("CharacterGetAttribute", g, a) }
  end
  for _, a in ipairs(COMBAT_ABILITIES) do out.combat[a] = Osiq("CharacterGetBaseAbility", g, a) or 0 end
  for _, a in ipairs(CIVIL_ABILITIES) do out.civil[a] = Osiq("CharacterGetBaseAbility", g, a) or 0 end
  for _, t in ipairs(ALL_TALENTS) do
    if t ~= "None" and t ~= "Max" and Osiq("CharacterHasTalent", g, t) == 1 then
      out.talents[#out.talents + 1] = TALENT_SCREEN[t] and (TALENT_SCREEN[t] .. " (" .. t .. ")") or t
    end
  end
  for id, skill in pairs(me.SkillManager.Skills) do
    if skill.IsLearned then
      local st = Ext.Stats.Get(id, nil, false)
      out.skills[#out.skills + 1] = { id = id, name = st and translated(st.DisplayName, id) or id,
        memorised = skill.IsActivated, memory_cost = st and st["Memory Cost"] or 1 }
    end
  end
  table.sort(out.skills, function (a, b) return a.id < b.id end)
  if args.talents then
    out.pickable_talents = {}
    for _, t in ipairs(ALL_TALENTS) do
      if pickableTalent(t) and Osiq("CharacterHasTalent", g, t) ~= 1 then
        out.pickable_talents[#out.pickable_talents + 1] = TALENT_SCREEN[t] .. " (" .. t .. ")"
      end
    end
  end
  return out
end

local function listHas(list, name)
  for _, v in ipairs(list) do if v == name then return true end end
  return false
end

--- Spend one point. kind = attribute | combat | civil | talent.
function Handlers.level_up(args)
  local me = args.character and member(args.character) or ActiveChar()
  local g = me.MyGuid
  if Osiq("CharacterIsInCombat", g) == 1 then error("The character sheet cannot be changed in combat") end
  local kind, name = args.kind, args.name
  -- Value before and after, so the bridge can caption the change on screen for a watcher.
  local function baseValue()
    if kind == "attribute" then return Osiq("CharacterGetBaseAttribute", g, name) end
    if kind == "combat" or kind == "civil" then return Osiq("CharacterGetBaseAbility", g, name) end
    return nil
  end
  local before = baseValue()
  if kind == "attribute" then
    if not listHas(ATTRIBUTES, name) then error("Unknown attribute " .. tostring(name)) end
    if (Osiq("CharacterGetAttributePoints", g) or 0) < 1 then error("No attribute points to spend") end
    if (Osiq("CharacterGetBaseAttribute", g, name) or 0) >= Ext.ExtraData.AttributeSoftCap then error(name .. " is at its cap") end
    Osi.CharacterAddAttribute(g, name, 1)
    Osi.CharacterAddAttributePoint(g, -1)
  elseif kind == "combat" or kind == "civil" then
    local list = kind == "combat" and COMBAT_ABILITIES or CIVIL_ABILITIES
    if not listHas(list, name) then error("Unknown " .. kind .. " ability " .. tostring(name)) end
    local pts
    if kind == "combat" then pts = Osiq("CharacterGetAbilityPoints", g) else pts = Osiq("CharacterGetCivilAbilityPoints", g) end
    if (pts or 0) < 1 then error("No " .. kind .. " ability points to spend") end
    local cap = kind == "combat" and Ext.ExtraData.CombatAbilityCap or Ext.ExtraData.CivilAbilityCap
    if (Osiq("CharacterGetBaseAbility", g, name) or 0) >= cap then error(name .. " is at its cap") end
    Osi.CharacterAddAbility(g, name, 1)
    if kind == "combat" then Osi.CharacterAddAbilityPoint(g, -1) else Osi.CharacterAddCivilAbilityPoint(g, -1) end
  elseif kind == "talent" then
    if not listHas(ALL_TALENTS, name) or not pickableTalent(name) then error(tostring(name) .. " is not a talent you can pick") end
    if (Osiq("CharacterGetTalentPoints", g) or 0) < 1 then error("No talent points to spend") end
    if Osiq("CharacterHasTalent", g, name) == 1 then error("Already have " .. name) end
    Osi.CharacterAddTalent(g, name)
    Osi.CharacterAddTalentPoint(g, -1)
  else
    error("kind must be attribute, combat, civil or talent")
  end
  return { character = NameOf(me), spent = kind, on = name, from = before, to = baseValue() }
end

--- Memorise or forget a learned skill, within the free memory slots (as dragging it on or off the skills screen).
function Handlers.memorise(args)
  local me = args.character and member(args.character) or ActiveChar()
  if Osiq("CharacterIsInCombat", me.MyGuid) == 1 then error("Skills cannot be memorised in combat") end
  local sm = me.SkillManager
  local skill = sm.Skills[args.skill]
  if skill == nil or not skill.IsLearned then error("You have not learned " .. tostring(args.skill)) end
  local st = Ext.Stats.Get(args.skill, nil, false)
  local cost = (st and st["Memory Cost"]) or 1
  if args.forget then
    if not skill.IsActivated then error(args.skill .. " is not memorised") end
    skill.IsActivated = false  -- FreeMemorySlots is read-only: the game recomputes it from the memorised skills
  else
    if skill.IsActivated then error(args.skill .. " is already memorised") end
    if sm.FreeMemorySlots < cost then
      error("Not enough memory: needs " .. cost .. ", " .. sm.FreeMemorySlots .. " free (forget something or raise Memory)")
    end
    skill.IsActivated = true
  end
  pcall(function () me:ForceSyncToPeers() end)
  return { character = NameOf(me), skill = args.skill, memorised = not args.forget, free_slots = sm.FreeMemorySlots }
end

-- Party control ------------------------------------------------------------------------------------------------

function Handlers.party()
  local acting = ActiveChar()
  local out = {}
  for _, g in ipairs(PartyGuids()) do
    local c = GetChar(g)
    if c then
      local p = Pos(c)
      out[#out + 1] = { name = NameOf(c), guid = c.MyGuid, level = Osiq("CharacterGetLevel", c.MyGuid),
        hp = c.Stats.CurrentVitality, max_hp = c.Stats.MaxVitality, x = p.x, z = p.z, dead = c.Dead,
        acting = c.MyGuid == acting.MyGuid,
        chained = c.MyGuid ~= acting.MyGuid and Osiq("CharactersAreGrouped", acting.MyGuid, c.MyGuid) == 1 or nil,
        sneaking = Osiq("HasActiveStatus", c.MyGuid, "SNEAKING") == 1 }
    end
  end
  return out
end

--- Choose which party member the tools act with (moves, attacks, skills, looting, talking).
function Handlers.party_select(args)
  local c = member(args.character)
  if c.Dead then error((NameOf(c) or "They") .. " is dead") end
  ActingGuid = c.MyGuid
  return { acting = NameOf(c) }
end

--- Chain a member to the acting character's group, or unchain them to act alone.
function Handlers.party_chain(args)
  local c = member(args.character)
  if args.chain then
    Osi.CharacterAttachToGroup(c.MyGuid, ActiveChar().MyGuid)
  else
    Osi.CharacterDetachFromGroup(c.MyGuid)
  end
  return { character = NameOf(c), chained = args.chain and true or false }
end

--- Sneak or stand up (out of combat; in combat sneaking costs AP and needs the game's own action).
function Handlers.sneak(args)
  local me = ActiveChar()
  if Osiq("CharacterIsInCombat", me.MyGuid) == 1 then error("Sneaking in combat is not supported yet") end
  if args.on then
    -- ApplyStatus(object, status, duration, force, source)
    Osi.ApplyStatus(me.MyGuid, "SNEAKING", -1.0, 1, me.MyGuid)
  else
    Osi.RemoveStatus(me.MyGuid, "SNEAKING")
  end
  return { character = NameOf(me), sneaking = args.on and true or false }
end

--- Send every other living party member walking to the acting character (outside combat). The game only moves chained
--- members along when the player orders it, so the bridge does it after each walk.
function Handlers.party_gather(args)
  local acting = ActiveChar()
  local sent = {}
  if Osiq("CharacterIsInCombat", acting.MyGuid) == 1 then return { sent = sent } end
  for _, g in ipairs(PartyGuids()) do
    local c = GetChar(g)
    if c and c.MyGuid ~= acting.MyGuid and not c.Dead and Dist(Pos(c), Pos(acting)) > (args.within or 4) then
      Osi.CharacterMoveTo(c.MyGuid, acting.MyGuid, 1, "", 0)
      sent[#sent + 1] = NameOf(c)
    end
  end
  return { sent = sent }
end

--- Hand an item from the acting character to another party member (like dragging it between their inventories).
function Handlers.give(args)
  local me = ActiveChar()
  local item = GetItem(args.item)
  if item == nil then error("No item with GUID " .. tostring(args.item)) end
  local owner = Osiq("GetInventoryOwner", item.MyGuid)
  if owner == nil or BareGuid(owner) ~= BareGuid(me.MyGuid) then error((NameOf(item) or "That") .. " is not in your inventory") end
  local to = member(args.to)
  if to.MyGuid == me.MyGuid then error("Pick another party member") end
  if Osiq("ItemIsEquipped", item.MyGuid) == 1 then error("Take it off first: " .. (NameOf(item) or "that") .. " is equipped") end
  local amount = math.min(args.amount or item.Amount or 1, item.Amount or 1)
  -- ItemToInventory(item, character, count, showNotification, equipOnPickup)
  Osi.ItemToInventory(item.MyGuid, to.MyGuid, amount, 0, 0)
  return { gave = NameOf(item), amount = amount, to = NameOf(to) }
end

--- Experience and unspent points of every party member, so the bridge can announce XP gains and level-ups by itself.
function Handlers.progress()
  local out = {}
  for _, g in ipairs(PartyGuids()) do
    local c = GetChar(g)
    if c then
      local gg = c.MyGuid
      out[#out + 1] = { name = NameOf(c), guid = gg, xp = c.Stats.Experience, level = Osiq("CharacterGetLevel", gg),
        points = (Osiq("CharacterGetAttributePoints", gg) or 0) + (Osiq("CharacterGetAbilityPoints", gg) or 0) +
          (Osiq("CharacterGetCivilAbilityPoints", gg) or 0) + (Osiq("CharacterGetTalentPoints", gg) or 0) }
    end
  end
  return out
end

--- Everything the bridge asks after each tool call, in one round trip: is the acting character in combat, and the party's
--- XP and unspent points (see Handlers.progress).
function Handlers.post()
  local me = ActiveChar()
  return { in_combat = Osiq("CharacterIsInCombat", me.MyGuid) == 1, party = Handlers.progress() }
end
