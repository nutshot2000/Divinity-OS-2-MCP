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

## Minimap (UI type 30)

Before each full redraw the game invokes `update(false)` on the minimap after filling `map_mc.add_icons` with groups
of five numbers: the object's handle bit-cast to a double, icon type, x and y on the map, and rotation. The client
unpacks the handle (`string.pack("<d")` then `string.unpack("<i8")`, then `Ext.Utils.IntegerToHandle`) and resolves
it with `Ext.Entity.GetGameObject` for name, GUID and position. Types seen: 11 = the player, 3 = a person nearby
(drawn even behind walls), 12 = a marker with no object behind it (meaning unknown). `update(true)` sends only the
player and type 12. `add_dirs` (rim arrows) has stayed empty so far. The swf names further icon classes
(QuestMarker, ExclamationMark, Waypoint, Teleport, Enemy, Friendly, Flag, SecretMarker) whose type numbers are
still to be matched.

Unnamed minimap markers (type 12, handle 0) are stairs and other exits: the one on the tutorial ship sits on the
stairs. Their minimap x,y are screen units that rotate with the camera and change scale, always as a rotation plus a
scale with the y axis flipped. One named icon (known ground offset v, minimap offset w) fixes it: K = w / conj(v) as
complex numbers, and a marker m is on the ground at conj(m / K) from the player. `dos2_minimap` does this; it is
accurate to about 0.3 m and needs one other person on the minimap.

## Fog of war: what the game really has

`Osi.IsShrouded` takes `(x, y, z)`. The bridge called it as `(x, z, 0.5)` for a long time, which asked about the wrong
point, so `?` never appeared on `dos2_grid` and the fog filters did nothing. With the correct call it reports 0 for the
whole of Fort Joy (a sample over the full AI grid found no shrouded cell outdoors): DOS2's world view has no black fog
there; only the minimap uncovers as you walk, and that mask is not readable from Lua. So `Server/Explore.lua` keeps its
own record: the character's cell each second per level, with everything within 14 m marked seen. `Unexplored(x, z)` (not
seen, or really shrouded) now drives the `?` on `dos2_grid`, the camera's "unexplored" refusal and `dos2_explore`.
Open question: interiors with real shroud (cellars) were not tested; `Shrouded` is still checked for them.

## The journal's Map tab (UI type 22)

The map the player opens with M is the Map tab of the journal screen (journal.swf; the legend: quest marker, location,
custom marker, waypoint shrine, secret, exit). Nothing is sent to it until it is opened. Opening it sent `selectTab(3)`,
`setMapOffset`, `setMapLegendHidden` and one `setPlayerOnMap(index, ?, x, y, ?, name)` per party member (map units, not
metres), then a stream of `update()`. On Fort Joy's first area no marker was sent and `add_icons` stayed empty: markers
for quests, waypoints and exits probably arrive through `add_icons`/`addIcon` once there are some to show. The explored
outline is part of the map texture, which Lua cannot read. Not built yet: wait until a map with markers has been opened
and record `add_icons` then, as `Client/UI.lua` does for the minimap. The minimap already gives people, enemies and exits.

## Showing panels for the watcher

The I key opens two screens together: the character sheet (UI 119, equipment slots) and the party inventory
(UI 116, both bags). Neither exists until the player has opened it once in a session (`Ext.UI.GetByType` returns nil).
`Show()` on a sheet that the game has never filled in crashed the game (access violation in a memcpy in the sheet's
own data code, VCRUNTIME140+0x1e250 from EoCApp+0x10343eb), so `show_inventory` in `Client/UI.lua` shows the sheet only
once its data has arrived (`updateItems` in the UI log), and the inventory screen whenever it exists. Both are hidden
again with `hideUI`: `closeUI` seems to destroy them (the screens vanished from the UI list and the I key stopped
working until a restart). Do not press hotbar buttons through `hotbarBtnPressed` either: it left the game with the I
button stuck on, nothing drawn, and eventually unresponsive.

Tabs: the sheet's own tab-button handler is `Ext.UI.GetByType(119):GetRoot().stats_mc.ClickTab(n)` (0 attributes, 1 combat
abilities, 2 civil abilities, 3 talents, 4 traits). `selectTab(n)` only changes the title and tab highlight, not the panel.
`show_sheet` in `Client/UI.lua` uses ClickTab; `dos2_level_up` shows the matching tab while it spends points.

## Crash: guessing close-call names (2026-10-26)

`tidy_ui` used to try `closeUI`, `requestCloseUI`, `closePressed`, `cancelPressed`, `closeMe`, `hideUI` through
`ExternalInterfaceCall` until a panel disappeared. One of those calls on a panel that does not define it crashed the game
(Script Extender crash dialog: `UIObjectFunctionCallCapture` from `UIObject::LuaExternalInterfaceCall`, Lua frame
`Client/UI.lua` in the tidy loop). It now calls only `closeUI` (known to work on books) and falls back to the engine's
`ui:Hide()`; the loot window, inventory and character sheet are only ever hidden with `Hide()`.

## Crash: ItemToInventory while looting a fresh corpse (2026-10-26)

Taking the items of an enemy (Narin) seconds after he died crashed the game inside `Osi.ItemToInventory`
(`Handlers.loot_take`). Other bodies had always been fine. Unknown which item; `loot_take` now iterates a copy of the
container's item list, asks for no pickup notification, uses an amount of at least 1, and `dos2_loot` waits 1.5 s first.

Follow-up: the culprit was one item on Narin named "Unidentified [1]" (a name that never resolved); the other seven items
transferred fine. `loot_take` now leaves any item whose name starts with "Unidentified [" and lists it as left alone.

## Crash: ui:Hide() on the character sheet (2026-10-26)

Third tidy-up crash: after `tidy_ui` switched to the engine's `ui:Hide()` for the loot window, inventory and character sheet, the
game crashed (access violation in a memcpy in the character sheet's own code, VCRUNTIME140+0x1e250 from EoCApp+0x10343eb,
the same trace as forcing the sheet open) when a panel the player had opened was hidden. Those three panels are hidden with
`ExternalInterfaceCall("hideUI")` again; others with `closeUI`; `Hide()` and guessed close names are not used.

## Teleportation skills (2026-10-27)

The Teleportation skill (SkillType `Teleportation`, e.g. `Teleportation_FreeFall` from Gloves of Teleportation) takes two
clicks in the game: the character or item to move, then the landing spot. It cannot move its caster. Osiris aims a
skill at one thing only: `CharacterUseSkillAtPosition` alone starts the cast, spends the cooldown and moves nothing.
The server skill state `esv::SkillStateTeleportation` (from `CharacterSkillManager.CurrentSkillState`, readable one tick
after the cast) has `SourceHandle`/`SourcePosition` (what moves) and `TargetPosition` (where). Setting all three while
the state is `Preparing` makes the real skill do the move. Setting only the source sent Beast to 0,0 (the landing
position was empty), so `Combat.lua` always sets them together and sets `RequestExit` if that fails. Entity objects
must be fetched again each tick (held ones expire). A party member landing took no damage.

## Picking things up and long routes (2026-10-27)

- `CharacterUseItem` on a loose bottle lying on the ground drank it. A click in the game picks loose items up, so
  `Handlers.use` now moves items that can be carried (`CanBePickedUp`) and are not containers into the inventory with
  `ItemToInventory`; containers, doors, levers and ladders are still used.
- `safe_path` searched a box 12 m around start and goal only, so a 188 m detour round a cliff read as "every route
  crosses a hazard". It now widens the box (12, 45, then 90 m) before giving up.
- `dos2_explore` lists seen ground no walk reaches but a 13 m Teleportation hop does, with where to stand and land.

## Identifying, carried to-dos (2026-10-27)

- The Identifying Glass's template use action is `Identify` (`IdentifyActionData`, `Consume = false`). `dos2_identify`
  sets `item.Stats.IsIdentified = 1` on carried items when the acting character has the glass; the inventory then shows
  the real stats.
- Carried books, notes, skill books, bags and unidentified items were never listed anywhere, so they sat unread.
  `carried_todo` reads each carried item's use actions (`Book`, `Recipe`, `SkillBook`) and containers; `dos2_explore`
  and `dos2_sweep` list the ones not dealt with yet. Bags the party carries report the world origin as their position,
  so `openContainer` treats them as always in reach.

## Trade window (2026-10-27)

The trade screen (`trade.swf`) opens by itself after a trader's "what do you sell" answer, then a dialogue answer
("Sure thing", continue) and is closed by `tidy_ui` on the next tool call. Holding it open while an extra `UICall`
subscriber (filtered to `trade.swf` and `uiCraft.swf`, reading `e.UI.Path` on every call) recorded its calls crashed the
whole game (the process was gone). Do not subscribe to UICall for the trade screen; the crafting screen's calls were
recorded fine without it open at the same time as a dialogue. Next try: read the screen's own arrays (`addItem`,
`setGoldValues`) from the invoke log and press its buttons by name from a one-shot call, with a quicksave first.
- Second crash (2026-10-28): the dialogue screen's `TradeButtonPressed` reopened the trade window (UI 46) while a
  `UIInvoke` subscriber read `root.item_array` / `root.gold_array` on its `updateItems` (Before). The game died within
  seconds, as with the `UICall` recorder. Two crashes with the trade window open and the bridge touching it: leave
  that window alone. Nebora's stock is readable server-side from her inventory, and `ItemGetGoldValue(item)` gives the
  game's value of a stack (not the barter-adjusted price).
- `dos2_trade` (2026-10-28) buys without the window: stock = the trader's carried, unequipped items; price =
  `ItemGetGoldValue` per unit (at least 1); the item moves with `ItemToInventory`, gold with `PartyAddGold(me, -price)`
  and `CharacterAddGold(trader, price)` (Nebora's purse went 428 -> 448 for 20 gold of goods). Needs the trader within
  6 m, alive, not hostile, not in the party. Selling is not done: the game's sell price is not known.
- tidy_ui closed the crafting window with closeUI, which destroyed it: the screen was gone from Ext.UI and K no longer
  opened it until a restart. It also closed the trade window under a running trade, the likely real cause of the two
  trade crashes. tidy_ui now closes only what the bridge's own actions leave open (loot window, book, pause menu, and
  the inventory or sheet it showed); the player's crafting, trade, journal, skills, examine and waypoint windows stay.
- Crafting (2026-10-28): recorded from a hand-made Knife On A Stick. The crafting screen (UI 102) answers
  `selectRecipe(n)` with `setRecipeResult(name)`, `setRecipeMaxCraftAmount(n)` and `setIngredient(slot, ?, name, have, ...)`;
  numbers with no recipe answer nothing, so probing is safe. Combine sends `craftRecipe(n, amount)`. `dos2_craft` uses
  `ui_call` for both and reads the invoke log. It crafts for the character the screen shows (`nextCharacter()` switches).
  The game's recipe table (`ItemCombos.txt` in the paks) matches ingredients by stats id or `ComboCategory`: a
  Magister's dagger (`_FTJ_Magister_Melee_Dagger`) has no category and does not count as "Any Dagger"; `WPN_Dagger` does.
- New-recipe notices (2026-10-28): `dos2_use` on a book whose use action is `Recipe` adds "new recipe learned" and the
  recipes now makeable; `dos2_loot` (when it took something), `dos2_sweep` and `dos2_trade` add "[Can craft now: ...]"
  when a known recipe's count is above 0 (`src/craft.js`, about 5 s: one `selectRecipe` per recipe number).
- The crafting screen only recounts and crafts while it is on screen. Closed (hidden) it still answers selectRecipe
  with the name and the craftable amount from when it was last open, sends no ingredients, and `craftRecipe` does
  nothing (Shell + Long Branch in the pack, Improvised Staff not made). So `dos2_craft` and the "can craft now" notes
  only work with the window open (G in game, or the story call OpenCraftUI). Doing it without the screen would mean consuming ingredients and creating the
  result from the recipe table (`ItemCombos.txt`, result stats -> `RootTemplate`).
- Trader stock: a trader's goods are created when their trade window first opens (Doctor Leste carried nothing).
  `trade_list` calls `GenerateItems(player, trader)` once per trader per session, which filled her stock.
- Opening crafting by script (2026-10-28): the story call `OpenCraftUI(character, item)` shows the crafting window
  (the one anvils use); after `setCurrentTab(0)` the Recipes tab recounts, and `craftRecipe` made an Improvised Staff
  from a Long Branch and a Shell. It only shows a crafting screen that exists: `closeUI` by script destroyed the screen
  again, after which neither `OpenCraftUI` nor the G key brought it back until a restart. The bridge never closes it.
- "Can craft now" notes count ingredients server-side (`craft_counts`) from data/recipes.json (built per machine by
  `scripts/build-recipes.mjs` from the paks; it is game data, so not committed), limited to recipe names the crafting
  window last listed for the character. Recipes needing a crafting station are left out.
- Resurrection Scroll (2026-10-28): its skill `Teleportation_ResurrectScroll` is a teleport-type skill (6 AP, 13 m,
  ground only): the body is the thing moved, x,z is where it stands up. `use_item` now routes teleport-type item skills
  through the same skill-state path as the gloves (with ignoreHasSkill), and `dos2_use_on` counts it as used once the
  target is at the spot (no cast event was logged out of combat, so the first scroll went unconsumed and was removed by
  hand).
- Party alerts: Beast died in poison after a fight while the bridge looted and changed gear, and no tool said so.
  `post` now returns `party_alerts` (dead; standing in fire, poison, lava, deathfog or electrified ground; poisoned,
  burning or bleeding; under 35% health) and every tool result ends with "[!! PARTY: ...]" until it is dealt with.
- Camera vs selection (2026-10-28): the game camera follows the character the player has selected and pulls back to
  it within about a second of any TargetLookAt change. `dos2_party select` only changes who the bridge acts as, so after
  a reload (the game selected Beast) the camera followed Beast while the bridge walked Sebille. The portraits screen
  (playerInfo.swf, UI 38) receives `selectPlayer(handle)`; calling its `charSel` with `Ext.UI.HandleToDouble(handle)`
  did nothing. Open: how to change the game's selection from script. Until then the player clicks the portrait.
- Camera fix: `ecl::GameCamera.CharacterHandle` (who it follows) is read-only. The game re-centres only when the
  selected character moves, so walks by anyone else and the bridge's close-ups left the camera parked ("not following
  anyone"). Now walks push TargetLookAt to the walker every poll, and every tool out of combat ends with the camera back
  on the acting character. When the acting character is not the one the player selected, the game still pulls the
  camera to the selected one whenever that one moves.
