-- dos2_grid: an ASCII walkability map from the AI grid. GetCellInfo(x, z).AiFlags is decoded by the extender into
-- ESurfaceFlag names (MovementBlock, Fire, Water, ...), so the legend reads names rather than raw bits.

-- First match wins: blocking first, then the most dangerous surfaces.
local LEGEND = {
  { "MovementBlock", "#" }, { "Lava", "!" }, { "Deepwater", "~" }, { "Fire", "f" }, { "Poison", "p" },
  { "Electrified", "e" }, { "Oil", "o" }, { "Frozen", "i" }, { "Water", "w" }, { "Blood", "b" },
  { "Web", "x" }, { "Door", "d" }, { "Deathfog", "!" }, { "FireCloud", "f" }, { "PoisonCloud", "p" },
}

local function cellChar(grid, x, z)
  if Shrouded(x, z) then return "?" end  -- fog of war: the player has not seen it
  local info = grid:GetCellInfo(x, z)
  if info == nil then return " " end
  for _, entry in ipairs(LEGEND) do
    if HasFlag(info.AiFlags, entry[1]) then return entry[2] end
  end
  return "."
end

function Handlers.grid(args)
  local grid = Ext.Entity.GetAiGrid()
  if grid == nil then error("No AI grid: is a level loaded?") end
  local me = ActiveChar()
  local p = Pos(me)
  -- Whole-metre centre so rows and columns line up with the 10 m ruler.
  local cx, cz = math.floor((args.x or p.x) + 0.5), math.floor((args.z or p.z) + 0.5)
  local r, step = args.radius or 15, args.step or 1
  local x1, x2, z1, z2 = cx - r, cx + r, cz - r, cz + r

  local people = {}
  for _, g in ipairs(PartyGuids()) do
    local c = GetChar(g)
    if c and not c.Dead then
      local cp = Pos(c)
      people[#people + 1] = { x = cp.x, z = cp.z, ch = (c.MyGuid == me.MyGuid) and "@" or "P" }
    end
  end

  local rows = {}
  local ruler = "       "
  for x = x1, x2, step do ruler = ruler .. ((x % 10 == 0) and "|" or " ") end
  rows[1] = ruler
  -- North (higher z, to be confirmed in game) at the top.
  for z = z2, z1, -step do
    local line = {}
    for x = x1, x2, step do
      local ch = cellChar(grid, x, z)
      for _, person in ipairs(people) do
        if math.abs(person.x - x) <= step / 2 and math.abs(person.z - z) <= step / 2 then ch = person.ch end
      end
      line[#line + 1] = ch
    end
    rows[#rows + 1] = string.format("%6s ", Round(z)) .. table.concat(line)
  end
  return { level = me.CurrentLevel, x = cx, z = cz, x1 = x1, x2 = x2, z1 = z1, z2 = z2, step = step, rows = rows,
    legend_unverified = true }
end
