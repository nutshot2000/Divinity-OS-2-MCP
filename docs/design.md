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
- **Combat tested in a fight (2 Viscous Voidlings, won unarmed):** status, skills, cast, attack, end turn and wait
  all work. The game refuses actions silently (e.g. Bouncing Shield with no shield), so tools report "refused" when
  no AP was spent, and `dos2_skills` shows requirements (needs a shield / melee weapon) and whether they are met.
  At 0 AP the game ends the turn itself. `ObjectTurnStarted` fires several times per turn (collapsed in the log).
- **Popups:** tutorial boxes (UI 55, `fadeInModal(category, title, text)`, closed with `OkPressed`) are dismissed
  after every tool call and their text is appended to the result. Message boxes (UI 29) are read and answered with
  `dos2_msgbox` (`ButtonPressed(id)`); not yet tested on a live prompt. Names from `tutorialBox.swf` / `msgBox.swf`.
- **Combat (implementation):** `Server/Combat.lua`. Turn order from
  `Ext.Entity.GetCombat(id):GetCurrentTurnOrder()`, active turn from `CombatGetActiveEntity`, skills from
  `SkillManager.Skills` + `Ext.Stats.Get`, actions via `CharacterAttack`, `CharacterUseSkill(..., 0, 0, 0)` /
  `CharacterUseSkillAtPosition`, `EndTurn`. A small log from `SkillCast`, `CharacterDied`, `ObjectTurnStarted`,
  `CombatEnded`. Skill descriptions still show `[1]` placeholders.
- **Loot (done):** server-side; contents only for an opened container within 3 m; owned items skipped.
- **Menu mouse input:** after a restart the main menu ignored mouse clicks (keyboard worked). A global `UICall` hook
  was suspected and is now limited to the dialogue screen; not confirmed either way.

## Panels, books and stairs (second testing round)

- Panels left open: `ClientHandlers.tidy_ui` runs after every tool and closes visible panels from a list
  (containerInventory, partyInventory, characterSheet, journal, examine, uiCraft, skills, trade, book, waypoints,
  gameMenu) with their own close call. `closeUI` comes before `hideUI`: hiding only made the game treat the book
  screen as still open and ignore later reads. Containers stay lootable for 5 minutes after their window closes
  (`OpenedByUs`).
- Books and notes: the book screen (UI type 2) gets `addPage(text)`; the client keeps the pages and `dos2_use`
  returns them.
- Stairs/ladders/hatches put the server briefly out of the "Running" state; polls now retry through it and
  `dos2_use` reports the move ("now at x,z (moved N m)").

## Camera and grid safety

- The player's camera is `Ext.Client.GetCameraManager().Controllers["GameCamera_player0"]`: `TargetLookAt`,
  `TargetCameraDistance` (clamped by the game to `MaxCameraDistance`, 19) and `Rotation` are writable and the game
  eases toward them. `src/director.js` frames talks, attacks, enemy turns and looting; the server's `camera_point`
  only allows visible objects or explored, on-map ground.
- `AiGrid:GetCellInfo` / `GetHeight` crash the game for points outside the grid (pcall cannot catch it). Every
  lookup goes through `GridCell` / `GridHeight` (Util.lua), which check `OffsetX/OffsetZ`, `Width/Height` and
  `GridScale` first.

## Resolved early questions

Loading the mod (pak via `Divine.exe`, `meta.lsx` with DE `PublishVersion`), Osiris calls from Tick (allowed), the
Documents path (OneDrive here), exact Osiris signatures (checked in `story_header.div`), AI grid flags (decoded to
names by the extender; north is +z) and DX11 window capture (PrintWindow works in borderless mode) are all settled.

## Open / not built yet

- Trading (trade UI), the journal and quest markers.
- Sneaking in combat (needs AP accounting), saving from the bridge.
- Message boxes (`dos2_msgbox`) are built but not yet tested on a live prompt.
- Perception-hidden items and traps: the look filter relies on `CharacterCanSee`; untested on a hidden object.
- Skill tooltips still show `[1]` placeholders instead of damage numbers.
- The AI grid holds one height per cell, so route planning is unreliable on stacked decks (falls back to the game's
  pathing there).
