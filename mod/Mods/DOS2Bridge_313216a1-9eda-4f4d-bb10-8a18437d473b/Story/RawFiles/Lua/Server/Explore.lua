-- dos2_explore: where to go next in a big area. DOS2 has no fog-of-war data to read outdoors (the world view is never
-- black; only the minimap uncovers as you walk), so the mod keeps its own record: every second it notes where the
-- character stands (per level), and everything within SIGHT metres of those places counts as seen. Everything else is
-- unexplored, and nothing about it (walls, floors, objects) is read. The search walks outward over the seen part of the
-- AI grid (a Dijkstra search, 2 m cells, around walls, steep drops and hazards) and reports the edges of the seen
-- area: walkable ground next to unexplored ground. dos2_grid draws the same unexplored ground as "?".
-- Edges already stood beside are not offered again, and a model that keeps circling the same place is told how much
-- of the reachable area it has really covered.

local STEP = 2       -- metres per search cell, also the size of a remembered "visited" cell
local STEP_UP = 2.4  -- largest height change between neighbouring cells that can be walked
local HAZ = { "Lava", "Fire", "Poison", "Electrified", "Deathfog", "FireCloud", "PoisonCloud", "Web" }
local NEIGH = { { 1, 0, 1 }, { -1, 0, 1 }, { 0, 1, 1 }, { 0, -1, 1 }, { 1, 1, 1.41 }, { 1, -1, 1.41 }, { -1, 1, 1.41 }, { -1, -1, 1.41 } }

local SIGHT = 14   -- metres around a place stood that count as seen (about what the screen shows)

Visited = Visited or {}   -- level name -> { ["ix,iz"] = true, n = count }: cells the character stood in
Known = Known or {}       -- level name -> { ["ix,iz"] = true }: cells within SIGHT of one of those

local function key(ix, iz) return ix .. "," .. iz end
local function lattice(v) return math.floor(v / STEP + 0.5) end

local FILE = "dos2bridge_visited.json"
local dirty = false

--- Mark one visited cell, and the cells within SIGHT of it as seen.
local function stamp(level, cx, cz)
  local v = Visited[level]
  if v == nil then v = { n = 0 }; Visited[level] = v end
  local known = Known[level]
  if known == nil then known = {}; Known[level] = known end
  local k = key(cx, cz)
  if v[k] and known[k] then return false end
  if not v[k] then v[k] = true; v.n = v.n + 1 end
  local r = math.floor(SIGHT / STEP)
  for dx = -r, r do
    for dz = -r, r do
      if dx * dx + dz * dz <= r * r then known[key(cx + dx, cz + dz)] = true end
    end
  end
  return true
end

--- Remember the active character's current cell, and mark the cells around it as seen. Called about once a second
--- and before anything that draws the map.
function RecordVisit()
  local level = CurrentLevelName()
  if level == nil then return end
  local p = Pos(ActiveChar())
  if stamp(level, lattice(p.x), lattice(p.z)) then dirty = true end
end

--- The record survives a game restart: it is written to Osiris Data every few seconds and read back at start.
local function saveVisited()
  local out = {}
  for level, v in pairs(Visited) do
    local cells = {}
    for k in pairs(v) do if k ~= "n" then cells[#cells + 1] = k end end
    out[level] = cells
  end
  pcall(Ext.IO.SaveFile, FILE, Ext.Json.Stringify(out, { Beautify = false }))
  dirty = false
end

--- Forget everything (a new playthrough, or to start a level's exploration afresh).
function ResetVisited(level)
  if level then Visited[level] = nil; Known[level] = nil else Visited = {}; Known = {} end
  saveVisited()
end

if next(Visited) == nil then
  local ok, raw = pcall(Ext.IO.LoadFile, FILE)
  if ok and raw and raw ~= "" then
    local okParse, data = pcall(Ext.Json.Parse, raw)
    if okParse and type(data) == "table" then
      for level, cells in pairs(data) do
        for _, k in ipairs(cells) do
          local ix, iz = k:match("^(-?%d+),(-?%d+)$")
          if ix then stamp(level, tonumber(ix), tonumber(iz)) end
        end
      end
    end
  end
end

--- True if x,z is ground the character has not seen yet: not within SIGHT of anywhere stood, or fogged by the game
--- (some interiors do have real shroud).
function Unexplored(x, z)
  local known = Known[CurrentLevelName() or "?"]
  if known == nil or not known[key(lattice(x), lattice(z))] then return true end
  return Shrouded(x, z)
end

-- Self-contained tick hook (kept in a global so a hot reload replaces it instead of stacking a second one).
if ExploreTick ~= nil then pcall(function () Ext.Events.Tick:Unsubscribe(ExploreTick) end) end
local ticks = 0
ExploreTick = Ext.Events.Tick:Subscribe(function ()
  ticks = ticks + 1
  if ticks % 30 ~= 0 then return end
  local ok, ready = pcall(function () return Ext.Osiris.IsCallable() and tostring(Ext.Server.GetGameState()) == "Running" end)
  if ok and ready then pcall(RecordVisit) end
  if dirty and ticks % 300 == 0 then saveVisited() end   -- about every 10 s, only when something new was seen
end)

local COMPASS = { "E", "NE", "N", "NW", "W", "SW", "S", "SE" }
local function compass(dx, dz)
  -- North is +z, east is +x, as on dos2_grid.
  local a = math.atan(dz, dx)
  return COMPASS[(math.floor((a / (math.pi / 4)) + 0.5) % 8) + 1]
end

function Handlers.explore(args)
  local grid = Ext.Entity.GetAiGrid()
  if grid == nil then error("No AI grid: is a level loaded?") end
  if args.reset then ResetVisited(CurrentLevelName()) end
  RecordVisit()
  local me = ActiveChar()
  local p = Pos(me)
  local level = CurrentLevelName() or "?"
  local visited = Visited[level] or { n = 0 }
  local radius = math.min(args.radius or 60, 90)
  local R = math.floor(radius / STEP)
  local sx, sz = lattice(p.x), lattice(p.z)

  local cache = {}
  local function cell(ix, iz)
    local k = key(ix, iz)
    local c = cache[k]
    if c == nil then
      local x, z = ix * STEP, iz * STEP
      if not InGrid(grid, x, z) then c = { blocked = true }
      elseif Unexplored(x, z) then c = { unknown = true }
      else
        local info = GridCell(grid, x, z)
        if info == nil then c = { blocked = true }
        else
          c = { height = info.Height }
          if HasFlag(info.AiFlags, "MovementBlock") then c.blocked = true end
          for _, h in ipairs(HAZ) do
            if HasFlag(info.AiFlags, h) then c.hazard = h; break end
          end
        end
      end
      cache[k] = c
    end
    return c
  end

  -- Dijkstra over known, walkable, hazard-free cells.
  local start = key(sx, sz)
  local dist = { [start] = 0 }
  local open = NewHeap()
  open.push({ sx, sz }, 0)
  local frontier, reachable, visitedReach, expanded = {}, 0, 0, 0
  local truncated = false
  while open.n > 0 do
    local cur, d = open.pop()
    local ck = key(cur[1], cur[2])
    if d <= dist[ck] then
      expanded = expanded + 1
      if expanded > 6000 then truncated = true; break end
      reachable = reachable + 1
      if visited[ck] then visitedReach = visitedReach + 1 end
      local here = cell(cur[1], cur[2])
      for _, s in ipairs(NEIGH) do
        local nx, nz = cur[1] + s[1], cur[2] + s[2]
        if math.abs(nx - sx) <= R and math.abs(nz - sz) <= R then
          local c = cell(nx, nz)
          if c.unknown then
            frontier[ck] = { ix = cur[1], iz = cur[2], d = d }
          elseif not c.blocked and not c.hazard and c.height and (here.height == nil or math.abs(c.height - here.height) <= STEP_UP) then
            local nk = key(nx, nz)
            local nd = d + s[3] * STEP
            if dist[nk] == nil or nd < dist[nk] then
              dist[nk] = nd
              open.push({ nx, nz }, nd)
            end
          end
        end
      end
    end
  end

  -- Group touching edge cells into stretches of fog edge; each is reported once, at its nearest cell.
  local seen, clusters = {}, {}
  for fk, f in pairs(frontier) do
    if not seen[fk] then
      local stack, members = { fk }, {}
      seen[fk] = true
      while #stack > 0 do
        local k = table.remove(stack)
        local m = frontier[k]
        members[#members + 1] = m
        for dx = -1, 1 do
          for dz = -1, 1 do
            local nk = key(m.ix + dx, m.iz + dz)
            -- A long arc of edge (the rim of the seen area) is split into stretches of about 8 m, so the open
            -- directions stay apart instead of merging into one.
            local n = frontier[nk]
            if n and not seen[nk] and (n.ix - f.ix) ^ 2 + (n.iz - f.iz) ^ 2 <= 16 then
              seen[nk] = true; stack[#stack + 1] = nk
            end
          end
        end
      end
      local nearest = members[1]
      for _, m in ipairs(members) do if m.d < nearest.d then nearest = m end end
      -- Already stood within ~4 m of it? Then whatever could be seen from there has been, and the dark patch is rock or
      -- sea, not a way on.
      local been = false
      for dx = -2, 2 do
        for dz = -2, 2 do
          if visited[key(nearest.ix + dx, nearest.iz + dz)] then been = true end
        end
      end
      local x, z = nearest.ix * STEP, nearest.iz * STEP
      clusters[#clusters + 1] = { x = x, z = z, dist = Round(nearest.d), dir = compass(x - p.x, z - p.z),
        size = #members * STEP, been = been }
    end
  end
  table.sort(clusters, function (a, b) return a.dist < b.dist end)

  local fresh, stale = {}, {}
  for _, c in ipairs(clusters) do
    if c.been then stale[#stale + 1] = c else fresh[#fresh + 1] = c end
  end
  for i = #fresh, 7, -1 do fresh[i] = nil end
  for i = #stale, 4, -1 do stale[i] = nil end
  return {
    x = Round(p.x), z = Round(p.z), edges = fresh, visited_edges = stale,
    reachable_m2 = reachable * STEP * STEP,
    covered_pct = reachable > 0 and math.floor(100 * visitedReach / reachable + 0.5) or 0,
    places_visited = visited.n, truncated = truncated,
  }
end
