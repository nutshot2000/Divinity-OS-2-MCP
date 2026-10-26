-- dos2_advice: a battle plan for the acting character's turn, built only from what the player can see (the same data as
-- dos2_combat, dos2_skills and dos2_tactics). It exists because play kept going wrong in the same ways: standing in fire,
-- trading blows on flat ground, spreading damage over several enemies, ignoring armour, fighting on when outnumbered.
-- Every line is a concrete suggestion in priority order; nothing here acts by itself.

local HAZARDS = { "Lava", "Fire", "Poison", "Electrified", "Deathfog", "FireCloud", "PoisonCloud", "Web", "Oil", "Frozen" }

local function has(list, value)
  for _, v in ipairs(list or {}) do if v == value then return true end end
  return false
end

local function anyStatus(statuses, pattern)
  for _, s in ipairs(statuses or {}) do
    if tostring(s):find(pattern) then return tostring(s) end
  end
  return nil
end

function Handlers.advise()
  local st = Handlers.combat({ since = 1e9 })
  if not st.in_combat then error("Not in combat: nothing to plan") end
  local me = st.me
  local plan = {}
  local function add(prio, text) plan[#plan + 1] = { prio = prio, text = text } end

  local enemies, allies = {}, {}
  for _, f in ipairs(st.fighters) do
    if has(f.tags, "enemy") and not has(f.tags, "dead") then enemies[#enemies + 1] = f
    elseif has(f.tags, "party") and f.guid ~= me.guid and not has(f.tags, "dead") then allies[#allies + 1] = f end
  end

  -- What I am standing in.
  local hazard
  local grid = Ext.Entity.GetAiGrid()
  local info = grid and GridCell(grid, me.x, me.z)
  if info then
    for _, h in ipairs(HAZARDS) do
      if HasFlag(info.AiFlags, h) then hazard = h; break end
    end
  end
  local burning = anyStatus(me.statuses, "^BURNING")
  local poisoned = anyStatus(me.statuses, "^POISONED")
  local hpFrac = (me.hp or 0) / math.max(1, me.max_hp or 1)

  -- Positions: reuse the tactics search (reachable this turn, no hazard, high ground, flanking).
  local spots = {}
  local okT, tac = pcall(Handlers.tactics, { radius = 10 })
  if okT and tac then spots = tac.high_ground or {} end
  local safeSpot
  for _, s in ipairs(spots) do
    if (s.ap or 99) <= (me.ap or 0) and not s.flanked then safeSpot = s; break end
  end
  local spotText = safeSpot and string.format("%s,%s (%s AP, %s m of height, nearest enemy %s m)", safeSpot.x, safeSpot.z, safeSpot.ap,
    safeSpot.height, safeSpot.nearest_enemy or "?") or nil

  -- Adjacent enemies (melee range) and nearby ones.
  local adjacent, near = 0, 0
  for _, e in ipairs(enemies) do
    if e.dist <= 2.5 then adjacent = adjacent + 1 end
    if e.dist <= 9 then near = near + 1 end
  end

  -- 0. Hazards first: nothing is worth more than not burning.
  if hazard then
    add(0, "You are STANDING IN " .. hazard:upper() .. ". Move out of it BEFORE doing anything else" ..
      (spotText and (": best nearby spot " .. spotText) or " (see dos2_tactics for safe squares)") .. ".")
  end
  if burning then
    add(0, "You are BURNING: it hurts every turn and grows if you stand in fire. Leave burning ground now; water or rain puts it out. " ..
      "Never breathe fire or throw fire onto ground you or your friends stand on.")
  elseif poisoned and not hazard then
    add(1, "You are POISONED: it ticks every turn. Do not stand in poison clouds; a healing skill or potion helps.")
  end
  for _, bad in ipairs({ "FROZEN", "BLIND", "SLOWED", "SILENCED", "KNOCKED_DOWN", "STUNNED" }) do
    local s = anyStatus(me.statuses, "^" .. bad)
    if s then add(2, "You are " .. bad:lower():gsub("_", " ") .. (bad == "BLIND" and ": you cannot see enemies, but adjacent ones can still be attacked; move first, then use ground-aimed skills." or ": plan around it (Break the Shackles, if you have Source, clears several of these).")) end
  end

  -- 1. Health.
  if hpFrac < 0.4 then
    add(1, string.format("Low HP (%d/%d). Heal (potion, healing skill, Blood Sucker next to blood), put distance between you and the enemies, " ..
      "or let someone tankier take the front. Do not end the turn next to several enemies.", me.hp, me.max_hp))
  end

  -- 2. Outnumbered: the game's own Flee prompt.
  local alive = 1 + #allies
  if #enemies > alive and (hpFrac < 0.5 or #enemies >= alive + 2) then
    add(1, string.format("Outnumbered %d to %d. If the fight turns, dos2_flee leaves combat for the whole party - do it early, with HP to spare.", #enemies, alive))
  end

  -- 3. Ground: high ground and chokepoints beat standing in the open.
  if adjacent >= 2 then
    add(3, "You are flanked by " .. adjacent .. " enemies. Step back so only one can reach you (a corridor, a wall at your back, an ally beside you)" ..
      (spotText and (": " .. spotText) or "") .. ".")
  elseif safeSpot and (safeSpot.height or 0) >= 1.5 and (safeSpot.nearest_enemy or 0) >= 3 and not hazard then
    add(3, "High ground is reachable: " .. spotText .. ". Ranged and spell attacks do more from above and enemies hit you less; take it, then attack.")
  elseif adjacent == 0 and near > 0 and #enemies > 1 then
    add(3, "Do not walk into the middle of the group. Let them come to you at a spot with a wall or ally at your back" ..
      (spotText and (" (e.g. " .. spotText .. ")") or "") .. ".")
  end

  -- 4. Focus fire: finish one enemy at a time, weakest effective health first.
  local ranked = {}
  for _, e in ipairs(enemies) do
    ranked[#ranked + 1] = { e = e, eff = (e.hp or 0) + (e.armor or 0) + (e.magic_armor or 0) }
  end
  table.sort(ranked, function (a, b) return a.eff < b.eff end)
  for i = 1, math.min(3, #ranked) do
    local e = ranked[i].e
    local weak = ""
    if (e.armor or 0) > (e.magic_armor or 0) * 1.5 then weak = " magic damage goes through easier"
    elseif (e.magic_armor or 0) > (e.armor or 0) * 1.5 then weak = " physical damage goes through easier"
    elseif (e.armor or 0) == 0 and (e.magic_armor or 0) == 0 then weak = " no armour: control effects (knockdown, stun) land" end
    add(4, string.format("Target %d: %s [%s] %d HP, %d armour, %d magic armour, %sm away.%s", i, e.name, e.guid, e.hp or 0, e.armor or 0,
      e.magic_armor or 0, math.floor((e.dist or 0) * 10) / 10, weak ~= "" and (" " .. weak:gsub("^ ", "") .. ".") or ""))
  end
  if #ranked >= 2 then
    add(4, "Focus ONE target until it dies (a dead enemy stops hurting you; spreading damage keeps them all alive). Strip the armour that is lower first.")
  end

  -- 5. What I can actually use now.
  local ready = {}
  local okS, skills = pcall(Handlers.skills, {})
  if okS and skills then
    for _, k in ipairs(skills) do
      if k.memorised and (k.cooldown_left or 0) == 0 and (k.ap or 0) <= (me.ap or 0) then
        local srcOk = true
        local okC, cost = pcall(function () return Ext.Stats.Get(k.id)["Magic Cost"] end)
        if okC and type(cost) == "number" and cost > 0 and (Osiq("CharacterGetSourcePoints", me.guid) or 0) < cost then srcOk = false end
        if srcOk then ready[#ready + 1] = string.format("%s (%d AP%s)", k.id, k.ap or 0, k.range and (", " .. math.floor(k.range) .. " m") or "") end
      end
    end
  end
  add(5, string.format("%d AP. Ready skills: %s.", me.ap or 0, #ready > 0 and table.concat(ready, ", ") or "none (basic attack, potions, moving)"))

  table.sort(plan, function (a, b) return a.prio < b.prio end)
  local lines = {}
  for _, p in ipairs(plan) do lines[#lines + 1] = p.text end
  return { lines = lines, hazard = hazard, burning = burning ~= nil, hp = me.hp, max_hp = me.max_hp, enemies = #enemies,
    allies = #allies }
end
