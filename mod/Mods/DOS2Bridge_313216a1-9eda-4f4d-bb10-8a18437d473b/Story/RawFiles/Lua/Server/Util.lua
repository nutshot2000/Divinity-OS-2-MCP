-- Shared helpers. Globals here live in the mod table (Mods.DOS2Bridge) and are visible to the other bridge files.

Arrivals = {}  -- event name -> true once the StoryEvent for that move has fired
Moves = {}     -- event name -> goal of that move, for move_status
Uses = {}      -- item GUID -> "used" | "failed", from the CharacterUsedItem(Failed) events

--- Call an Osiris function or query by name; nil instead of an error when it fails or does not exist.
function Osiq(name, ...)
  local ok, a, b, c = pcall(Osi[name], ...)
  if ok then return a, b, c end
  return nil
end

--- Fog of war: true if the point is still shrouded (unexplored). Unknown counts as not shrouded.
function Shrouded(x, z)
  return Osiq("IsShrouded", x, z, 0.5) == 1
end

function Round(v, places)
  local m = 10 ^ (places or 1)
  return math.floor(v * m + 0.5) / m
end

--- GUIDs from Osiris look like "S_Name_<uuid>" or "Name_<uuid>"; engine lookups want the bare uuid.
function BareGuid(g)
  if type(g) ~= "string" then return g end
  return g:match("(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)$") or g
end

function GetChar(g)
  local ok, c = pcall(Ext.Entity.GetCharacter, BareGuid(g))
  if ok then return c end
end

function GetItem(g)
  local ok, i = pcall(Ext.Entity.GetItem, BareGuid(g))
  if ok then return i end
end

function Pos(obj)
  local p = obj.WorldPos
  return { x = Round(p[1]), y = Round(p[2]), z = Round(p[3]) }
end

function Dist(a, b)
  return Round(math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2))
end

--- The name the game shows on hover, or nil for unnamed scenery (no tooltip in game either).
function NameOf(obj)
  local n = obj.DisplayName
  if n ~= nil and n ~= "" then return n end
  if obj.StatsId ~= nil and obj.StatsId ~= "" then return obj.StatsId end
  return nil
end

function CurrentLevelName()
  local host = Osiq("CharacterGetHostCharacter")
  local c = host and GetChar(host)
  return c and c.CurrentLevel or nil
end

--- Party members, from the story's player database.
function PartyGuids()
  local out = {}
  local rows = Osi.DB_IsPlayer:Get(nil) or {}
  for _, row in ipairs(rows) do out[#out + 1] = row[1] end
  return out
end

--- The character the tools act with: the party member picked with dos2_party select (ActingGuid), else the one the
--- player is controlling: _C() (extender helper) if it works here, else the host character.
function ActiveChar()
  if ActingGuid ~= nil then
    local picked = GetChar(ActingGuid)
    if picked ~= nil and not picked.Dead and Osiq("CharacterIsPartyMember", picked.MyGuid) == 1 then return picked end
    ActingGuid = nil
  end
  if _C ~= nil then
    local ok, c = pcall(_C)
    if ok and c ~= nil then return c end
  end
  local host = Osiq("CharacterGetHostCharacter")
  local c = host and GetChar(host)
  if c == nil then error("No active character. Load a save first.") end
  return c
end

--- True if an engine flag set (list of names, name->bool table or bitfield userdata) contains name.
function HasFlag(flags, name)
  if flags == nil then return false end
  if type(flags) == "table" then
    if flags[name] then return true end
    for _, v in ipairs(flags) do if v == name then return true end end
    return false
  end
  local ok, v = pcall(function () return flags[name] end)
  return ok and v == true
end
