# AGENTS.md

Notes for AI coding agents working on this repository.

## Playing the game

Read [PLAYBOOK.md](PLAYBOOK.md): it is the guide the server sends as its instructions. Play fair: never teleport,
spawn or reveal anything.

## Fair play is a hard rule

The agent may only know what a human player would know and see at that moment. Every tool must pass this check:
no container contents before opening, no perception-hidden objects or undetected sneakers, nothing out of line of
sight or in unexplored (shrouded) areas, no story flags or loot tables. When unsure, leave it out. `dos2_lua` is a
debugging tool and is off unless `DOS2_DEV=1`. The playthrough is blind: the agent plays as a first-timer and does not
act on story, quest, loot or puzzle knowledge from training data (see PLAYBOOK.md, "Blind playthrough"). The bridge is built while playing a real game and keeps being
optimised for speed and watchability, but never by giving the agent extra knowledge.

## Working on the bridge

- `src/server.js` starts the MCP server; `src/core.js` holds the server instance, `tool()` registration and helpers;
  `src/bridge.js` is the file transport to the game; `src/tools/*.js` register tools by area.
- The in-game side is a Script Extender mod in `mod/Mods/DOS2Bridge_<uuid>/`. `BootstrapServer.lua` polls
  `dos2bridge_request.json` in the game's `Osiris Data` folder on `Ext.Events.Tick` and writes
  `dos2bridge_response.json`; `Server/Handlers.lua` and `Server/Grid.lua` hold `Handlers[cmd](args)`.
- [docs/design.md](docs/design.md) lists the APIs used and the assumptions still to verify in game.

## Checks before committing

- `npm run test:offline`: every tool registers with a description and schema.
- `npm test`: also pings the mod and runs the read-only tools against a running game.
- `node scripts/call.mjs <tool> '<json>'` runs one tool.
- Lua edits need the mod files reinstalled (`scripts/install-mod.ps1`) and a `reset` in the extender console (or a
  save reload). JS edits need a server restart.
