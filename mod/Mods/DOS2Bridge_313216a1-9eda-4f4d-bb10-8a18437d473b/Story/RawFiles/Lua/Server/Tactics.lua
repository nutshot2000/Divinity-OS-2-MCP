-- dos2_tactics: a positioning map for combat. Walking distance (a breadth-first search over the AI grid, around walls
-- and steep drops) decides which squares this turn's AP can reach; heights show high ground; visible enemies and
-- allies are marked. Fair play: only enemies the character can see, nothing under fog of war.

local HIGH = 1.5   -- metres above/below the character that count as high/low ground
local STEP_UP = 1.2 -- larger height jumps between neighbouring cells are not walkable (cliffs, deck edges)

local HAZARDS = { "Lava", "Fire", "Poison", "Electrified", "Deathfog", "FireCloud", "PoisonCloud", "Web", "Oil", "Frozen" }
local HAZARD_CHAR = { Lava = "!", Fire = "f", Poison = "p", Electrified = "e", Deathfog = "!", FireCloud = "f",
  PoisonCloud = "p", Web = "x", Oil = "o", Frozen = "i" }

local function metresPerAP(me)
  local total = 0
  local ok = pcall(function ()
    for _, d in ipairs(me.Stats.DynamicStats) do total = total + (d.Movement or 0) end
  end)
  if not ok or total <= 0 then total = 500 end
  return total / 100
end

local function cellInfo(grid, x, z)
  if Shrouded(x, z) then return { unknown = true } end
  local info = grid:GetCellInfo(x, z)
  if info == nil then return { blocked = true } end
  local c = { height = info.Height }
  if HasFlag(info.AiFlags, "MovementBlock") then c.blocked = true end
  for _, h in ipairs(HAZARDS) do
    if HasFlag(info.AiFlags, h) then c.hazard = h; break end
  end
  return c
end

function Handlers.tactics(args)
  local grid = Ext.Entity.GetAiGrid()
  if grid == nil then error("No AI grid: is a level loaded?") end
  local me = ActiveChar()
  local p = Pos(me)
  local r = args.radius or 12
  local cx, cz = math.floor(p.x + 0.5), math.floor(p.z + 0.5)
  local myHeight = grid:GetHeight(p.x, p.z) or p.y
  local ap = me.Stats.CurrentAP or 0
  -- Out of combat there is no AP to spend: preview what a fresh turn would allow, for planning before a fight.
  if Osiq("CharacterIsInCombat", me.MyGuid) ~= 1 then ap = me.Stats.APStart or 4 end
  local perAP = metresPerAP(me)
  local reach = ap * perAP

  -- Cells keyed by "dx,dz" offsets from the centre.
  local cells = {}
  for dz = -r, r do
    for dx = -r, r do cells[dx .. "," .. dz] = cellInfo(grid, cx + dx, cz + dz) end
  end

  -- Walking distance from the character's cell (8 directions, diagonals cost 1.41).
  local dist = { ["0,0"] = 0 }
  local frontier = { { 0, 0 } }
  while #frontier > 0 do
    local best, bi = nil, nil
    for i, f in ipairs(frontier) do
      local d = dist[f[1] .. "," .. f[2]]
      if best == nil or d < best then best, bi = d, i end
    end
    local cur = table.remove(frontier, bi)
    local here = cells[cur[1] .. "," .. cur[2]]
    for _, step in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }) do
      local nx, nz = cur[1] + step[1], cur[2] + step[2]
      local key = nx .. "," .. nz
      local cell = cells[key]
      if cell and not cell.blocked and not cell.unknown and here and here.height and cell.height
          and math.abs(cell.height - here.height) <= STEP_UP then
        local nd = best + ((step[1] ~= 0 and step[2] ~= 0) and 1.41 or 1)
        if nd <= reach + 0.01 and (dist[key] == nil or nd < dist[key]) then
          dist[key] = nd
          frontier[#frontier + 1] = { nx, nz }
        end
      end
    end
  end

  -- Visible combatants.
  local units = {}
  local enemies = {}
  for _, g in ipairs(Ext.Entity.GetCharacterGuidsAroundPosition(p.x, p.y, p.z, r + 2)) do
    local c = GetChar(g)
    if c and c.MyGuid ~= me.MyGuid and not c.Dead and not c.OffStage and CanSeeObject(me, c) then
      local cp = Pos(c)
      local enemy = Osiq("CharacterIsEnemy", me.MyGuid, c.MyGuid) == 1
      local key = math.floor(cp.x + 0.5) - cx .. "," .. math.floor(cp.z + 0.5) - cz
      units[key] = enemy and "E" or "A"
      if enemy then
        enemies[#enemies + 1] = { name = NameOf(c) or "enemy", x = cp.x, z = cp.z, dist = Dist(p, cp),
          height = Round((grid:GetHeight(cp.x, cp.z) or cp.y) - myHeight) }
      end
    end
  end

  -- Draw: rows north (higher z) at the top, like dos2_grid.
  local rows = {}
  local ruler = "       "
  for dx = -r, r do ruler = ruler .. (((cx + dx) % 10 == 0) and "|" or " ") end
  rows[1] = ruler
  for dz = r, -r, -1 do
    local line = {}
    for dx = -r, r do
      local key = dx .. "," .. dz
      local c = cells[key]
      local ch
      if dx == 0 and dz == 0 then ch = "@"
      elseif units[key] then ch = units[key]
      elseif c.unknown then ch = "?"
      elseif c.blocked then ch = "#"
      elseif c.hazard then ch = HAZARD_CHAR[c.hazard]
      else
        local dh = (c.height or myHeight) - myHeight
        local reachable = dist[key] ~= nil
        if dh >= HIGH then ch = reachable and "^" or "'"
        elseif dh <= -HIGH then ch = reachable and "v" or ";"
        else ch = reachable and "." or "," end
      end
      line[#line + 1] = ch
    end
    rows[#rows + 1] = string.format("%6s ", cz + dz) .. table.concat(line)
  end

  -- Suggestions: reachable, hazard-free squares, scored by height gain and by not having enemies on opposite sides.
  local spots = {}
  for key, d in pairs(dist) do
    local c = cells[key]
    if key ~= "0,0" and c and not c.hazard and not units[key] then
      local dx, dz = key:match("(-?%d+),(-?%d+)")
      local x, z = cx + tonumber(dx), cz + tonumber(dz)
      local dh = (c.height or myHeight) - myHeight
      local near, flank = math.huge, false
      for i, a in ipairs(enemies) do
        local ad = math.sqrt((a.x - x) ^ 2 + (a.z - z) ^ 2)
        near = math.min(near, ad)
        for j = i + 1, #enemies do
          local b = enemies[j]
          -- two enemies roughly on opposite sides of the square = flanked there
          local v1x, v1z, v2x, v2z = a.x - x, a.z - z, b.x - x, b.z - z
          local l1, l2 = math.sqrt(v1x ^ 2 + v1z ^ 2), math.sqrt(v2x ^ 2 + v2z ^ 2)
          if l1 < 3 and l2 < 3 and (v1x * v2x + v1z * v2z) / (l1 * l2 + 0.001) < -0.5 then flank = true end
        end
      end
      spots[#spots + 1] = { x = x, z = z, ap = math.ceil(d / perAP), height = Round(dh), nearest_enemy = near < math.huge and Round(near) or nil,
        flanked = flank, score = dh * 2 - (flank and 5 or 0) }
    end
  end
  table.sort(spots, function (a, b) return a.score > b.score end)
  for i = #spots, 6, -1 do spots[i] = nil end
  for _, s in ipairs(spots) do s.score = nil end

  return { x = cx, z = cz, ap = ap, metres_per_ap = perAP, reach = Round(reach), rows = rows,
    enemies = enemies, high_ground = spots }
end

--- A walking route to x,z that avoids blocked cells, steep drops and hazards (fire, poison, ...), found with a
--- search over the AI grid. The game's own pathfinding happily walks through fire, so dos2_move follows these
--- waypoints instead. Returns { waypoints = {{x,z},...} } or { error = reason }.
function Handlers.safe_path(args)
  local grid = Ext.Entity.GetAiGrid()
  if grid == nil then error("No AI grid: is a level loaded?") end
  local me = ActiveChar()
  local p = Pos(me)
  local sx, sz = math.floor(p.x + 0.5), math.floor(p.z + 0.5)
  local gx, gz = math.floor(args.x + 0.5), math.floor(args.z + 0.5)
  -- The AI grid keeps one height per cell; on stacked decks the character may be on a floor above or below it.
  local here = grid:GetHeight(p.x, p.z)
  if here == nil or math.abs(here - p.y) > 1.5 then
    return { error = "multi-level: the grid describes another floor here, so no route can be planned" }
  end
  local margin = 12
  local minX, maxX = math.min(sx, gx) - margin, math.max(sx, gx) + margin
  local minZ, maxZ = math.min(sz, gz) - margin, math.max(sz, gz) + margin
  if (maxX - minX) * (maxZ - minZ) > 120 * 120 then error("Too far for one move: pick a closer point") end

  local cache = {}
  local function cell(x, z)
    local k = x .. "," .. z
    if cache[k] == nil then cache[k] = cellInfo(grid, x, z) end
    return cache[k]
  end
  local function free(c) return c and not c.blocked and not c.unknown and not c.hazard and c.height end

  -- The goal itself may be an object's cell (blocked) or in a hazard: accept the nearest free cell within 2 m.
  local goalCell = cell(gx, gz)
  if not free(goalCell) then
    local best = nil
    for dz = -2, 2 do for dx = -2, 2 do
      local c = cell(gx + dx, gz + dz)
      if free(c) and (best == nil or dx * dx + dz * dz < best[3]) then best = { gx + dx, gz + dz, dx * dx + dz * dz } end
    end end
    if best == nil then
      return { error = goalCell.hazard and ("the destination is in " .. goalCell.hazard:lower()) or "the destination is blocked" }
    end
    gx, gz = best[1], best[2]
  end

  local start = sx .. "," .. sz
  local dist, prev = { [start] = 0 }, {}
  local open = { { sx, sz } }
  local goalKey = gx .. "," .. gz
  while #open > 0 do
    local bi, best = 1, dist[open[1][1] .. "," .. open[1][2]]
    for i = 2, #open do
      local d = dist[open[i][1] .. "," .. open[i][2]]
      if d < best then bi, best = i, d end
    end
    local cur = table.remove(open, bi)
    local ck = cur[1] .. "," .. cur[2]
    if ck == goalKey then break end
    local here = cell(cur[1], cur[2])
    for _, s in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }) do
      local nx, nz = cur[1] + s[1], cur[2] + s[2]
      if nx >= minX and nx <= maxX and nz >= minZ and nz <= maxZ then
        local c = cell(nx, nz)
        local hh = here and here.height or c and c.height
        if free(c) and hh and math.abs(c.height - hh) <= STEP_UP then
          local nk = nx .. "," .. nz
          local nd = best + ((s[1] ~= 0 and s[2] ~= 0) and 1.41 or 1)
          if dist[nk] == nil or nd < dist[nk] then
            dist[nk], prev[nk] = nd, ck
            open[#open + 1] = { nx, nz }
          end
        end
      end
    end
  end
  if dist[goalKey] == nil then return { error = "every route crosses fire, poison or another hazard (or is blocked)" } end

  -- Walk back from the goal; keep a waypoint wherever the direction changes, and at least every 6 cells.
  local path = {}
  local k = goalKey
  while k do
    local x, z = k:match("(-?%d+),(-?%d+)")
    table.insert(path, 1, { tonumber(x), tonumber(z) })
    k = prev[k]
  end
  local waypoints, sinceLast = {}, 0
  for i = 2, #path do
    sinceLast = sinceLast + 1
    local a, b, c = path[i - 1], path[i], path[i + 1]
    local turn = c and ((b[1] - a[1]) ~= (c[1] - b[1]) or (b[2] - a[2]) ~= (c[2] - b[2]))
    if c == nil or turn or sinceLast >= 6 then
      waypoints[#waypoints + 1] = { x = b[1], z = b[2] }
      sinceLast = 0
    end
  end
  return { waypoints = waypoints, length = Round(dist[goalKey]) }
end
