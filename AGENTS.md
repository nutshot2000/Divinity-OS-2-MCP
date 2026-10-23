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
| `dos2_move` | Walk to x,z or a GUID along a route that avoids fire, poison and other hazards; stops at once on damage; refuses if every route crosses a hazard (`allow_hazards=true` to go anyway) |
| `dos2_inventory` | List your inventory with descriptions; `dos2_use` an item to drink, eat or read it |
| `dos2_use` | Use an item: open containers and doors, pull levers, take stairs and ladders (walks there first) |
| `dos2_loot` | List an opened container or a dead body you stand next to; `take="all"` or `take=[GUIDs]` to take; owned items are left alone |
| `dos2_equip` | Equip a weapon, shield or armour from your inventory (attribute requirements checked) |
| `dos2_talk` | Walk up to a character and start a conversation |
| `dos2_dialog` | Read the open conversation: new lines and numbered answers |
| `dos2_answer` | Pick an answer by number; "(continue)" lines are stepped through automatically |
| `dos2_combat` | Turn order, whose turn, your AP, every visible combatant's HP/armour/statuses, recent events |
| `dos2_skills` | Your skills: AP, cooldown, range, area, damage type, tooltip |
| `dos2_attack` | Basic attack on a target GUID |
| `dos2_cast` | Use a memorised skill on a target GUID or on the ground at x,z |
| `dos2_end_turn` | End your turn and wait through the enemies' turns |
| `dos2_wait_turn` | Wait until it is your turn |
| `dos2_preview` | Who a skill or item (grenade, scroll) would hit at a target or spot, allies included, and if it is in range |
| `dos2_use_on` | Throw or read an inventory item at a target or spot (grenades, skill scrolls); used up only if it happens |
| `dos2_tactics` | Positioning map: squares reachable with this turn's AP, high ground, hazards, enemies, best spots |
| `dos2_msgbox` | Read a yes/no prompt ("leave the Tutorial Deck?") and press a button by id |
| `dos2_sheet` | Character sheet: level, unspent points, attributes, abilities, talents, skills, memory slots |
| `dos2_level_up` | Spend a point on an attribute, combat/civil ability or talent (talent-screen talents only; caps enforced) |
| `dos2_memorise` | Memorise or forget a learned skill (memory slots enforced) |
| `dos2_party` | List the party, pick who the tools act with, chain or unchain members |
| `dos2_sneak` | Start or stop sneaking (out of combat) |
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
`dos2_cast` or `dos2_move` (moving costs AP), and `dos2_end_turn` when out of useful AP. Position every turn:
`dos2_tactics` shows reachable squares, high ground and hazards; take high ground for ranged and spells, keep a wall
or ally at your back so you are not flanked, step out of fire and poison, and fight in chokepoints. Physical damage strips
physical armour, magic strips magic armour; knockdowns and other control effects only land once the matching armour
is gone. Watch surfaces in `dos2_grid` and allies in area skills.

**Levelling.** When a level-up notification appears, `dos2_sheet` shows the unspent points; plan a build that fits
the character and spend them with `dos2_level_up` (out of combat). New skill books: `dos2_use` the book to learn it,
then `dos2_memorise`.

**Party.** Once others join, `dos2_party` lists them; `action=select` makes the tools act as that member (in combat,
select whoever's turn it is), `chain`/`unchain` moves them together or apart.

**Saving.** The bridge cannot save. Quicksave is F5 in the game window: ask the watching player, or with screen control
run `scripts/focus-game.ps1` first and then press F5. Quickload (F8) reloads Lua from the *installed* pak, so keep it
current with `scripts/install-mod.ps1` (game closed). Never call tools in a tight loop while a save is loading.

Tutorial popups are dismissed automatically after every tool call; their text is appended to the tool's result as
`[Tutorial dismissed: ...]`. Read them: they teach mechanics.

If a skill does nothing and the tool says "refused", check its requirement in `dos2_skills` (e.g. "needs a shield:
NOT MET"). At 0 AP the game ends your turn by itself; `dos2_end_turn` then just waits.

## Things that need the screen (for now)

The bridge does not yet cover these; use screen control (screenshot + click/keys) sparingly:

- Character creation, trading, reading books and notes, the journal, saving (F5), sneaking in combat.
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
