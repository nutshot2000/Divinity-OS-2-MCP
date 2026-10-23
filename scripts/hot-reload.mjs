// Dev helper: node scripts/hot-reload.mjs [file ...]
// Re-runs the mod's Server/*.lua files inside the running game through the "lua" debug command, so Lua edits apply
// without repacking the pak (which the running game keeps locked) or reloading a save. Run install-mod.ps1 later so the
// installed pak matches. Order matters: Util first, then the handler files.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { call } from "../src/bridge.js";

const LUA = fileURLToPath(new URL("../mod/Mods/DOS2Bridge_313216a1-9eda-4f4d-bb10-8a18437d473b/Story/RawFiles/Lua/Server/", import.meta.url));
const files = process.argv.slice(2).length ? process.argv.slice(2) : ["Util.lua", "Handlers.lua", "Grid.lua", "Combat.lua", "Tactics.lua", "Character.lua"];
for (const f of files) {
  // The prefix makes the file define its globals in the mod's table, not _G (load() ignores its env argument).
  await call("lua", { code: "local _ENV = Mods.DOS2Bridge\n" + readFileSync(LUA + f, "utf8") }, 10000);
  console.log(`reloaded ${f}`);
}
