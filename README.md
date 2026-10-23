# dos2-bridge

An MCP server that lets an AI agent play **Divinity: Original Sin 2 – Definitive Edition**: explore, talk, loot,
fight turn-based battles, level up and manage the party. It reads game state as text and issues game-level commands
through the [Script Extender](https://github.com/Norbyte/ositools), so screenshots are rarely needed.

The agent only learns what a human player could see (no peeking into containers, nothing out of sight or unexplored)
and plays blind (no story or puzzle knowledge from training data). See [PLAYBOOK.md](PLAYBOOK.md).

- **Playing with an AI?** The server sends [PLAYBOOK.md](PLAYBOOK.md) as its instructions automatically.
- **An AI working on this repo?** Read [AGENTS.md](AGENTS.md).
- **How it works / engine notes:** [docs/design.md](docs/design.md).

## Setup (Windows)

1. Install the game on Steam and run it once. If Larian's launcher asks for the .NET Desktop Runtime 3.1, install it,
   or start the game with `scripts/launch-game.ps1`, which skips the launcher.
2. Install the Script Extender: copy `dxgi.dll` from the updater zip
   ([Norbyte/ositools releases](https://github.com/Norbyte/ositools/releases)) into
   `...\Divinity Original Sin 2\DefEd\bin`. The main menu then shows "Script Extender v60" in the corner.
3. Get LSLib ([Norbyte/lslib releases](https://github.com/Norbyte/lslib/releases)) and unzip it into `tools/lslib`
   (so `tools/lslib/Packed/Tools/Divine.exe` exists), or set `DIVINE_EXE` to its `Divine.exe`.
4. In this folder: `npm install`.
5. **With the game closed**, install the mod: `powershell -File scripts/install-mod.ps1`
   (re-run this after every update – the running game locks the file).
6. Start the game: main menu → **Mods** → tick **DOS2 Bridge** → Confirm (accept the achievements warning).
7. Add the server to your MCP client and load a save:

```json
{ "mcpServers": { "dos2": { "command": "node", "args": ["C:/path/to/dos2-bridge/src/server.js"] } } }
```

8. Ask the AI to call `dos2_ping`; it should report a heartbeat and the level name.

Tips: use **borderless window** mode (fullscreen minimises when it loses focus). Set `DOS2_DATA_DIR` if the game's
`Osiris Data` folder is not under `Documents` or `OneDrive\Documents`.

## Tools (30)

| Area | Tools |
|--|--|
| Status and senses | `dos2_ping`, `dos2_status`, `dos2_look`, `dos2_grid`, `dos2_screenshot` |
| Moving and using | `dos2_move` (avoids fire/poison, stops on damage), `dos2_use`, `dos2_msgbox`, `dos2_say` |
| Talking | `dos2_talk`, `dos2_dialog`, `dos2_answer` |
| Items | `dos2_loot` (containers and bodies), `dos2_inventory`, `dos2_equip` |
| Combat | `dos2_combat`, `dos2_tactics`, `dos2_skills`, `dos2_attack`, `dos2_cast`, `dos2_preview`, `dos2_use_on`, `dos2_end_turn`, `dos2_wait_turn` |
| Character and party | `dos2_sheet`, `dos2_level_up`, `dos2_memorise`, `dos2_party`, `dos2_sneak` |
| Help | `dos2_help` (returns the playbook) |

`dos2_lua` (raw Lua) is a debugging tool, only registered with `DOS2_DEV=1`, and never used for play.

## Not supported yet

Trading, reading books and notes, the journal, character creation, saving (ask the player to press F5), and sneaking
in combat. Use screen control for these if needed.

## Helper scripts

| Script | Does |
|--|--|
| `scripts/install-mod.ps1` | Packs `mod/` and copies it to the game's Mods folder (game must be closed) |
| `scripts/launch-game.ps1` | Starts the game, skipping Larian's launcher |
| `scripts/focus-game.ps1` | Brings the game window to the front (for screen-control keys like F5) |
| `scripts/hot-reload.mjs` | Loads changed server Lua into the running game without restarting |
| `scripts/call.mjs` | Runs one tool from the command line: `node scripts/call.mjs dos2_status` |
| `scripts/client.mjs` | Calls the mod's client (UI) half directly, for debugging |
| `scripts/smoke.mjs` | `npm run test:offline` (tools register) / `npm test` (read-only tools against the game) |
| `scripts/capture-window.ps1` | Used by `dos2_screenshot` |
