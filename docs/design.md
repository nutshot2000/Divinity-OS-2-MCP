# dos2-bridge design

Goal: let an AI agent explore and fight in Divinity: Original Sin 2 (Definitive Edition) by reading game state as
text and issuing game-level commands (walk to X, use item Y), with screenshots only as an occasional sanity check.

Modelled on `df-bridge`: a Node MCP server (`src/`), tool groups in `src/tools/*.js`, and in-game Lua behind each
tool. The difference is the transport: DFHack has `dfhack-run.exe`, the DOS2 Script Extender has no outside channel,
so the bridge talks to the game through files.

## Pieces

```
MCP client ──stdio──> src/server.js ──files──> Osiris Data/dos2bridge_request.json ──> mod (Lua, server context)
                                    <──files── Osiris Data/dos2bridge_response.json <──
                                    <──files── Osiris Data/dos2bridge_heartbeat.json  (written ~1/s)
```

- **Mod** (`mod/Mods/DOS2Bridge_313216a1-9eda-4f4d-bb10-8a18437d473b/`): a Script Extender Lua mod. `BootstrapServer.lua`
  subscribes to `Ext.Events.Tick` (~30 Hz), and every few ticks reads the request file with `Ext.IO.LoadFile`. A new
  `seq` runs the named handler and writes the response with `Ext.IO.SaveFile`. Both functions work relative to the
  `Osiris Data` folder in the game's Documents folder.
- **Server** (`src/bridge.js`): one request at a time. Writes the request file atomically (temp file + rename), polls
  for a response with the same `seq`, times out with a clear message if the heartbeat is stale (game not running,
  mod not loaded, or the game is on the main menu).

## Script Extender API used (checked against the ositools docs, v60 annotations)

| Need | API |
|--|--|
| Tick loop | `Ext.Events.Tick:Subscribe(fn)`, `Ext.OnNextTick(fn)` |
| File IO | `Ext.IO.LoadFile(path)`, `Ext.IO.SaveFile(path, text)` (relative to `Osiris Data`) |
| JSON | `Ext.Json.Parse`, `Ext.Json.Stringify(v, opts)` |
| Objects | `Ext.Entity.GetCharacter(guid)`, `Ext.Entity.GetItem(guid)`; fields `MyGuid`, `DisplayName`, `WorldPos`, `CurrentLevel`, `Dead`, `OffStage`, `InDialog`, `Stats` |
| Nearby | `Ext.Entity.GetCharacterGuidsAroundPosition(x, y, z, dist)`, `Ext.Entity.GetItemGuidsAroundPosition(x, y, z, dist)` |
| Walkability | `Ext.Entity.GetAiGrid()` → `GetCellInfo(x, z)` `{Flags, Height, Objects}`, `GetHeight`, `GetAiFlags`, `SearchForCell(x, z, radius, flags, bias)`, `FindCellsInRect` |
| Line of sight | `Ext.Entity.GetVisionGrid():RaycastToPosition(from, to, flags)` (v59+) |
| Combat | `Ext.Entity.GetCombat(id)`, `GetCurrentTurnOrder()`, `Ext.Entity.GetTurnManager()` |
| Osiris | `Osi.CharacterGetHostCharacter()`, `Osi.DB_IsPlayer:Get(nil)`, `Osi.CharacterMoveToPosition(...)`, `Osi.CharacterMoveTo(...)`, `Osi.CharacterUseItem(...)`, `Osi.CharacterIsEnemy(a, b)`, `Osi.ItemIsContainer(i)`, `Osi.ItemIsLocked(i)` |
| Osiris events | `Ext.Osiris.RegisterListener("StoryEvent", 2, "after", fn)` (movement arrival) |

## Navigation model

1. `dos2_look` lists nearby characters and items with coordinates, distance and flags (enemy, dead, container,
   locked). Text only, sorted by distance.
2. `dos2_grid` draws an ASCII walkability map around the party from the AI grid (like `df_look`), so routes and
   hazards (fire, poison, water, oil) can be read without a screenshot.
3. `dos2_move` sends the party leader to a point or object with the engine's own pathfinding
   (`CharacterMoveToPosition` / `CharacterMoveTo` with a unique event name). The server then polls `move_status`
   until the `StoryEvent` arrival fires, the character stops moving (stuck) or a timeout passes.
4. `dos2_use` uses an item (open a chest or door, pull a lever, pick up).
5. `dos2_screenshot` captures the game window when a picture is really needed.

## Fair play: only what a human player would know

Hard rule from the user. Each tool's leaks and how they are handled:

| Tool | Possible leak | Handling |
|--|--|--|
| `look` | Objects behind walls or out of view | The engine's own `CharacterCanSee(char, target)` (story header), falling back to a `VisionGrid` raycast; objects in shrouded areas (`IsShrouded(x, z, 0.5)`) dropped. Untested. |
| `look` | Perception-hidden items, traps, sneaking/invisible characters | `CharacterCanSee` should cover sneaking/invisible characters (to confirm). Perception-hidden items/traps: still a known gap, to test with a hidden item in game. |
| `look` | Lock details a player would not see | Only "locked" (shown on hover in game); the key requirement is not reported. |
| `look` | Container contents, loot tables | Never read. Contents only after `dos2_use` opens the container (future: read the opened container's UI). |
| `grid` | Unexplored areas | Shrouded cells (`IsShrouded`) drawn as `?`. Explored terrain stays visible, like the game's own map. |
| `status` | Nothing beyond the party's own sheet | Party only. |
| `lua` | Anything | Off unless `DOS2_DEV=1`; never used for play. |

Coordinates and distances are fine: a player sees where things are on screen.

## Research findings (extender source, 2026-10-23)

Read from the ositools source (`ScriptExtender/Lua`, `ScriptExtender/Extender`, `ScriptHelpers.cpp`) and LeaderLib.

- **Osiris calls from Tick are allowed.** `LuaBinding.cpp` throws `Tick` with restriction flags `0`, and
  `Osi.*` is only blocked under `RestrictOsiris` (`ServerOsiris.inl: IsCallable`). Handlers can call Osiris directly.
- **Ext.IO root confirmed.** `GetPathForExternalIo` resolves paths under `"/Osiris Data"` in game storage and rejects
  unsafe relative paths (`..`). Flat file names in that folder are fine.
- **Debugger socket: possible, not chosen.** With `EnableLuaDebugger` (default on in developer builds/config), the
  extender listens on `127.0.0.1:9998` and speaks protobuf (`Lua/Debugger/LuaDebug.proto`). `DbgEvaluate` runs an
  expression in the server state without pausing: queued actions run from the Lua line hook, i.e. whenever any Lua
  executes (our Tick handler guarantees that). Results come back as protobuf values; returning
  `Ext.Json.Stringify(...)` gives a plain string. Costs: a protobuf client in Node, the line hook slows all Lua while
  attached, and it is a developer feature. File polling at ~10 Hz is ~100 ms per call, which is enough; keep the
  socket as a later fast path if latency matters (e.g. combat).
- **No path query.** The extender exposes no "find path / is reachable" call. Better than a stall timer for move
  outcome: `EsvCharacter.MovementMachine` (states like `EsvMSMoveTo`, with `IsPathfinding`) and
  `EsvCharacter.ActionMachine.Layers[x]` (`ASUseItem`, `ASPickUp`, `ASLockpick`, `ASDisarmTrap`, ...), so `move_status`
  and `use` can report what the character is actually doing.
- **Line of sight.** `Ext.Entity.GetVisionGrid():RaycastToPosition(from, to, Ext.Enums.VisionFlags.VisionBlock)`
  returns the flags where the ray stopped. Use it in `look` to mark objects you cannot see, and later for combat.
- **Talking to NPCs.** Osiris has `CharacterMoveToAndTalk` (LeaderLib uses its events), plus `DialogStarted`,
  `DialogEnded` and `DialogRequestFailed` events. That covers starting a conversation from the server.
- **Choosing dialogue answers is client UI.** The dialogue screen is UI type 14 (`dialog.swf`, LeaderLib
  `Data.UIType.dialog`); its text arrives through `addTextArray`. Answer selection is a Flash
  `ExternalInterface.call` whose name still has to be found: in game, dump `Ext.UI.GetByType(14):GetRoot()` from a
  `BootstrapClient.lua` while a dialogue is open, and watch calls with `Ext.RegisterUITypeCall(14, ...)`.
  Client and server talk through `Ext.Net.PostMessageToServer` / `Ext.Net.PostMessageToClient`.

## Learned in the first live session (2026-10-23)

- **Mod loading:** `meta.lsx` must use the old numeric attribute types, list `DivinityOrigins` as a dependency, and
  have a `PublishVersion` that decodes to 3.6.x (`908857753`); `1.0` makes the game call it a Classic Edition mod.
  Name the pak `<Folder>.pak`.
- **Launcher:** Steam's Play runs `bin\SupportTool.exe`, which needs .NET Desktop Runtime 3.1; `scripts/launch-game.ps1`
  starts `DefEd\bin\EoCApp.exe` directly.
- **Screen control:** exclusive fullscreen minimises on focus loss and captures black. Borderless
  (`FakeFullscreenEnabled=1`, `Fullscreen=0` in `graphicSettings.lsx`; backup kept as `.bak-before-bridge`) works.
  The app's screenshot comes back masked grey, so the bridge's own `PrintWindow` capture (now DPI-aware) is used for
  viewing; clicks go through screen control at 1456x819 = 2560x1440 scaled. Shell commands steal focus: refocus the
  game before clicking.
- **Hot reload:** the extender's restricted `load()` ignores its env argument; prefix code with
  `local _ENV = Mods.DOS2Bridge`. `scripts/hot-reload.mjs` re-runs the Server Lua files in the live game.
- **Working in game:** `ping`, `status`, `look` (line of sight, names), `grid`, `move` (arrival event fires), `say`.
- **`CharacterUseItem` does not walk to the item** and reports "used" even when nothing happens: `dos2_use` should
  `move` first. Using some items (the tutorial ladder) opens a yes/no message box (`MessageBoxYesNoClosed`), which
  blocks further use until answered.
- **Dialogue (done):** the client half (`BootstrapClient.lua`, `Client/UI.lua`) watches UI type 14 (`dialog.swf`).
  The game fills `addTextArray` (groups of 4: speaker, ?, line, ?) and `addKWAnswerArray` (groups of 3: holder,
  answer text, ?), then invokes `updateDialog`; the screen empties them once drawn, so they are snapshotted at that
  invoke. Answering = `ExternalInterfaceCall("QuestionPressed", index)`, the call a click makes. Starting a talk =
  raising the Osiris event `DialogStartRequested(npc, player)` (what a click raises; NPCs like Siwan have no
  `DB_Dialogs` row). Array names came from the strings in `Public/Game/GUI/dialog.swf` (Game.pak).
- **Combat (built, untested in a fight):** `Server/Combat.lua`. Turn order from
  `Ext.Entity.GetCombat(id):GetCurrentTurnOrder()`, active turn from `CombatGetActiveEntity`, skills from
  `SkillManager.Skills` + `Ext.Stats.Get`, actions via `CharacterAttack`, `CharacterUseSkill(..., 0, 0, 0)` /
  `CharacterUseSkillAtPosition`, `EndTurn`. A small log from `SkillCast`, `CharacterDied`, `ObjectTurnStarted`,
  `CombatEnded`. Skill descriptions still show `[1]` placeholders.
- **Loot (done):** server-side; contents only for an opened container within 3 m; owned items skipped.
- **Menu mouse input:** after a restart the main menu ignored mouse clicks (keyboard worked). A global `UICall` hook
  was suspected and is now limited to the dialogue screen; not confirmed either way.

## Must verify once the game is installed

These are the risky assumptions, in the order they block progress:

1. **Loading the mod.** The extender reads `Mods/<folder>/OsiToolsConfig.json` and `Story/RawFiles/Lua/*.lua`. A
   mod must also be in the load order. Plan A: pack the folder into a `.pak` with LSLib's `divine.exe`
   (`scripts/install-mod.ps1`), drop it into `Documents/Larian Studios/Divinity Original Sin 2 Definitive
   Edition/Mods`, enable it in the game's Mods menu. Plan B: loose files under `<game>/DefEd/Data/Mods/`. The
   `meta.lsx` is hand-written and may need fixing.
2. ~~Osiris calls from a Tick handler~~: allowed (see findings).
3. ~~Where Documents is~~: `OneDrive\Documents\Larian Studios\...` on this PC; the server already checks there.
4. ~~Exact Osiris signatures~~: checked against `story_header.div` (Patch8, the engine declarations only; no
   Origins story files read, to keep the run blind). `CharacterMoveToPosition(char, x, y, z, running, event)`,
   `CharacterMoveTo(char, target, running, event, increaseSpeed)`, `CharacterUseItem(char, item, event)`,
   `CharacterMoveToAndTalk(char, target, dialogId, isAutomated, moveId, running, timeout)` all match.
5. **AI grid cell flags.** `GetCellInfo()` returns raw `Flags` plus `AiFlags`, which the extender decodes as
   `ESurfaceFlag` names (`MovementBlock`, `Fire`, `Water`, `Door`, ...; see `ScriptExtender/Lua/Libs/AI.inl`).
   `Grid.lua` reads the names. Still to check: whether `AiFlags` arrives as a list, a map or a bitfield userdata
   (`HasFlag` handles all three), and which way is north.
6. **Screenshot of a DX11 window.** `PrintWindow` can return black for DirectX games. The capture script falls back to
   copying the window's screen area (needs the game visible, windowed or borderless).

## Later

- Dialogue: reading and choosing dialogue options goes through the client UI (`Ext.UI`, `dialog.swf`), not Osiris.
  Needs a `BootstrapClient.lua` and a second channel. Until then, dialogue is done with screenshots and clicks.
- Combat tools: turn order, AP, skills with cooldowns and ranges, `dos2_cast skill target`, `dos2_end_turn`.
- Party control: switch the active character, split the party.
- Quest log: read journal entries (client UI or Osiris quest DBs).
