# dos2-bridge

An MCP server that lets an AI agent explore and play **Divinity: Original Sin 2 – Definitive Edition**, by reading
game state as text and giving game-level commands (walk to a point, use an item) through the
[Script Extender](https://github.com/Norbyte/ositools). Screenshots are an occasional extra, not the main loop.

Status: **first draft, not yet run against the game.** See [docs/design.md](docs/design.md) for what is still to verify.

## Tools

| Tool | What it does |
|--|--|
| `dos2_status` | Party: positions, HP, armour, AP, combat/dialogue state |
| `dos2_look` | Nearby characters and items, nearest first, with GUIDs and tags |
| `dos2_grid` | ASCII walkability and hazard map from the game's AI grid |
| `dos2_move` | Walk to a point or object with the game's pathfinding; waits for arrival |
| `dos2_use` | Use an item: open, pull, pick up |
| `dos2_screenshot` | Capture the game window |
| `dos2_ping`, `dos2_help` | Connection check, playbook |
| `dos2_lua` | Raw Lua for debugging the bridge; only registered with `DOS2_DEV=1` |

**Fair play:** the agent only learns what a human player could see at that moment: no peeking into containers,
nothing out of line of sight, no hidden objects or unexplored map. See [PLAYBOOK.md](PLAYBOOK.md) and the leak table in
[docs/design.md](docs/design.md).

## Setup

1. Install the game and run it once. If Steam's Play button does nothing, Larian's launcher is failing for lack of the
   .NET Desktop Runtime 3.1: start the game with `scripts/launch-game.ps1` instead (it runs `DefEd\bin\EoCApp.exe`).
2. Install the Script Extender: put its `DXGI.dll` updater in the game's `DefEd\bin` folder and launch once.
3. Install the mod: `powershell -File scripts/install-mod.ps1` (packs it with LSLib's `divine.exe`; see the script),
   then enable **DOS2 Bridge** in the game's Mods menu.
4. `npm install`, then add the server to your MCP client:

```json
{ "mcpServers": { "dos2": { "command": "node", "args": ["C:/Users/batti/Projects/dos2-bridge/src/server.js"] } } }
```

Set `DOS2_DATA_DIR` if the game's `Osiris Data` folder is not under `Documents` or `OneDrive\Documents` (on this PC
it is `OneDrive\Documents`).

For screen control (character creation, dialogue until the bridge supports it), approve the game window's process,
`eocapp.exe`, not the Steam entry: the window belongs to that process.
