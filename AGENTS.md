# AGENTS.md

How any AI agent (Claude, Codex, OpenCode, Gemini, ...) plays **Divinity: Original Sin 2 – Definitive Edition**
through this bridge, and how to work on the bridge itself. Read the rules first: they are not optional.

## The rules

**Fair play.** Know only what a human player would know and see at that moment.

- Learn what is in a chest, barrel or body by opening it, never before.
- Only what is in sight counts. Things behind walls, under fog of war or hidden by perception are not yours to know.
  The tools filter for this; never work around them.
- No teleporting, spawning items, editing stats or reading story flags. `dos2_lua` is for debugging the bridge, is
  off unless `DOS2_DEV=1`, and is never used for play.
- If a tool shows something a player could not see, say so, ignore it, and report it as a bridge bug.

**Blind playthrough.** Play as a first-timer. You probably know DOS2 from training data; do not act on it.

- Allowed: general mechanics and anything the game shows or teaches (fire and oil explode, armour must break before
  control effects land, tooltips).
- Not allowed: knowing where quests lead, who lies or betrays, where secrets or loot are, puzzle solutions, which
  dialogue options pay off, or what is round the next corner.
- Decide from what the characters have seen, heard and read in this game. If you catch yourself using outside
  knowledge, say so out loud and choose as a first-timer would.

**Watchability.** A person is usually watching. Narrate decisions with `dos2_say` (a short line over your
character's head), keep the pace up, and prefer the text tools over screenshots.

## Setup (once per machine)

1. Install the game (Steam). If Larian's launcher asks for the .NET Desktop Runtime 3.1, install it, or start the game
   with `scripts/launch-game.ps1`, which skips the launcher.
2. Install the Script Extender: copy `dxgi.dll` from its updater
   ([Norbyte/ositools releases](https://github.com/Norbyte/ositools/releases)) into the game's `DefEd\bin` folder.
   The main menu then shows "Script Extender v60" (or newer) in the corner.
3. `npm install`, then pack and install the mod: `powershell -File scripts/install-mod.ps1` (needs LSLib's
   `Divine.exe` in `tools/lslib/...` or `DIVINE_EXE`). The game must be closed: it locks the pak.
4. In the game's main menu: Mods → tick **DOS2 Bridge** → Confirm (accept the achievements warning).
5. Add the MCP server to your client, then start or load a game:

```json
{ "mcpServers": { "dos2": { "command": "node", "args": ["<path>/dos2-bridge/src/server.js"] } } }
```

6. Check the connection with `dos2_ping`. Set `DOS2_DATA_DIR` if the game's `Osiris Data` folder is not under
   `Documents` or `OneDrive\Documents`.

## The tools

| Tool | Use it to |
|--|--|
| `dos2_status` | See the party: position, HP, armour, AP, level, in combat/dialogue |
| `dos2_look` | List characters and items in sight, nearest first, with GUIDs and tags (enemy, container, locked, ...) |
| `dos2_grid` | Draw an ASCII map: `#` blocked, `.` walkable, `d` door, `f` fire, `p` poison, `o` oil, `w`/`~` water, `?` unexplored |
| `dos2_move` | Walk to x,z or to a GUID with the game's pathfinding; waits for arrival, a stop, combat or dialogue |
| `dos2_use` | Use an item: open containers and doors, pull levers, take stairs and ladders (walks there first) |
| `dos2_loot` | List an opened container you stand next to; `take="all"` or `take=[GUIDs]` to take; owned items are left alone |
| `dos2_talk` | Walk up to a character and start a conversation |
| `dos2_dialog` | Read the open conversation: new lines and numbered answers |
| `dos2_answer` | Pick an answer by number; "(continue)" lines are stepped through automatically |
| `dos2_combat` | Turn order, whose turn, your AP, every visible combatant's HP/armour/statuses, recent events |
| `dos2_skills` | Your skills: AP, cooldown, range, area, damage type, tooltip |
| `dos2_attack` | Basic attack on a target GUID |
| `dos2_cast` | Use a memorised skill on a target GUID or on the ground at x,z |
| `dos2_end_turn` | End your turn and wait through the enemies' turns |
| `dos2_wait_turn` | Wait until it is your turn |
| `dos2_say` | Narrate: overhead text for the watcher |
| `dos2_screenshot` | Capture the game window. Expensive: only when the text tools cannot show what you need |
| `dos2_help` | The playbook ([PLAYBOOK.md](PLAYBOOK.md)) |

Coordinates are metres on the ground plane: `x` and `z`. Height `y` is read from the ground for you.

## How to play

**Exploring.** Loop: `dos2_status` → `dos2_look` (and `dos2_grid` when the route matters) → ONE action → read the
result. "stopped" from `dos2_move` means blocked or unreachable: look again and pick another route or a closer point.
Use `dos2_say` to share what you are thinking before you act.

**Talking.** `dos2_talk` a character, then `dos2_answer` until the conversation ends. Conversations also start on
their own (someone calls out, a skull speaks to an undead): if a move reports "dialogue started", call `dos2_dialog`.
Role-play the character you were given; read their background from what the game shows.

**Containers.** `dos2_use` opens a container (it reports "now open"), `dos2_loot` lists it, `dos2_loot take="all"`
empties it. Owned items show "(owned by ...)" and are never taken: that would be stealing.

**Combat.** Turn-based. `dos2_combat` at the start of each of your turns, `dos2_skills` to plan, then `dos2_attack`,
`dos2_cast` or `dos2_move` (moving costs AP), and `dos2_end_turn` when out of useful AP. Physical damage strips
physical armour, magic strips magic armour; knockdowns and other control effects only land once the matching armour
is gone. Watch surfaces in `dos2_grid` and allies in area skills.

**Saving.** Quicksave (F5) before risky moments and after milestones; it needs the game window focused (screen control).

## Things that need the screen (for now)

The bridge does not yet cover these; use screen control (screenshot + click/keys) sparingly:

- Yes/no message boxes some actions raise (e.g. "leave the Tutorial Deck?"). Until answered, the character is stuck.
- Character creation, the character sheet and levelling up, trading, reading books and notes, inventory management.
- Main-menu navigation. If the mouse is ignored there, the keyboard (arrows, Enter) works.

Screen-control tips on Windows: run the game in borderless window mode (fullscreen minimises when it loses focus and
captures black). The app's own screenshots may come back masked; `dos2_screenshot` captures the game window directly.
Shell commands can take focus away from the game: bring it back to the foreground before clicking or pressing keys.

## Working on the bridge

- `src/server.js` starts the MCP server; `src/core.js` holds the server instance, `tool()` registration and helpers;
  `src/bridge.js` is the file transport; `src/tools/*.js` register tools by area (observe, move, loot, dialog,
  combat, misc).
- The in-game side is a Script Extender mod in `mod/Mods/DOS2Bridge_<uuid>/`:
  - Server half: `BootstrapServer.lua` polls `dos2bridge_request.json` in `Osiris Data` on `Ext.Events.Tick` and
    writes `dos2bridge_response.json`; handlers live in `Server/Handlers.lua`, `Grid.lua`, `Combat.lua`.
  - Client half: `BootstrapClient.lua` does the same with `dos2bridge_client_*.json` and watches the Flash UI
    (dialogue is UI type 14) in `Client/UI.lua`.
- Every new tool needs a fair-play check (line of sight, fog of war, perception, what the UI would show). When unsure,
  leave it out.
- [docs/design.md](docs/design.md) lists the engine APIs used, what was learned in live sessions and open questions.

## Checks before committing

- `npm run test:offline`: every tool registers with a description and schema.
- `npm test`: also pings the mod and runs the read-only tools against a running game.
- `node scripts/call.mjs <tool> '<json>'` runs one tool; `node scripts/client.mjs <cmd> '<json>'` calls the mod's
  client half directly.
- Lua edits: `node scripts/hot-reload.mjs` loads the server Lua into the running game; run `scripts/install-mod.ps1`
  once the game is closed so the installed pak matches. Client Lua and new bootstrap files need the pak reinstalled and
  the game restarted. JS edits need an MCP server restart.
