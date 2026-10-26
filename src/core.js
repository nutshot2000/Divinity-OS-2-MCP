// Shared plumbing for the DOS2 MCP server: the server instance, tool registration and helpers.
// Tool groups live in src/tools/*.js.
import fs from "node:fs";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { call } from "./bridge.js";
export { z, call };

// The playbook: sent as the server's instructions, returned by dos2_help.
export const INSTRUCTIONS = (() => {
  try { return fs.readFileSync(new URL("../PLAYBOOK.md", import.meta.url), "utf8"); }
  catch { return "You are playing Divinity: Original Sin 2 through the Script Extender. Call dos2_help."; }
})();

export const VERSION = JSON.parse(fs.readFileSync(new URL("../package.json", import.meta.url), "utf8")).version;

export const server = new McpServer({ name: "dos2", version: VERSION }, { instructions: INSTRUCTIONS });

export const text = (s) => ({ content: [{ type: "text", text: s }] });
export const fail = (s) => ({ content: [{ type: "text", text: s }], isError: true });
export const json = (v) => JSON.stringify(v, null, 1);

/** True while the acting character is in combat (false when the game cannot be asked). */
export async function inCombat() {
  try { return (await call("move_status", { event: "" }, 5000)).in_combat === true; } catch { return false; }
}

// Tools that already show the fight themselves: no banner needed after them.
const SHOWS_COMBAT = new Set(["dos2_combat", "dos2_attack", "dos2_cast", "dos2_end_turn", "dos2_wait_turn", "dos2_use_on"]);
const COMBAT_BANNER = "\n\n[!! IN COMBAT !! Stop exploring, looting and talking. Call dos2_combat now, and play EVERY turn: " +
  "dos2_tactics for position, dos2_attack / dos2_cast, then dos2_end_turn. Every action outside the fight gives the " +
  "enemies free turns, and wandering off or opening containers mid-fight is how characters die. If it looks " +
  "unwinnable, say so and tell the player.]";

// XP gains and level-ups are announced after tool calls (nothing else tells the player). The last XP seen is kept in a temp
// file too, because one-shot CLI calls start a fresh server each time.
import { readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
const XP_MARK = join(tmpdir(), "dos2-bridge-xp-mark.json");
let lastXp = (() => { try { return JSON.parse(readFileSync(XP_MARK, "utf8")); } catch { return {}; } })();
async function progressNote() {
  let party;
  try { party = await call("progress", {}, 5000); } catch { return ""; }
  let note = "";
  const now = {};
  for (const m of party) {
    now[m.guid] = m.xp;
    const before = lastXp[m.guid];
    if (before != null && m.xp > before) note += `
[+${m.xp - before} XP for ${m.name} (now ${m.xp}).]`;
  }
  const spend = party.filter((m) => m.points > 0);
  if (spend.length) note += `
[LEVEL UP: ${spend.map((m) => `${m.name} has ${m.points} point${m.points > 1 ? "s" : ""} to spend`).join("; ")}. ` +
    "Out of combat, use dos2_sheet and dos2_level_up (attributes, abilities, talents) and dos2_memorise for new skills.]";
  lastXp = now;
  try { writeFileSync(XP_MARK, JSON.stringify(now)); } catch { /* best effort */ }
  return note;
}

/** After every tool: dismiss tutorial popups (they block play) and report their text, and close panels left open on
 *  screen (loot windows from opening containers, inventory, journal, ...), so nothing piles up while playing. */
async function tutorialNote() {
  let note = "";
  try {
    const shown = await call("tutorials", {}, 5000, "client");
    note += shown.map((t) => `\n\n[Tutorial dismissed: ${t.title} — ${String(t.text).replace(/<[^>]*>/g, "")}]`).join("");
  } catch { /* client half not running (main menu, loading): nothing to dismiss */ }
  try {
    const closed = await call("tidy_ui", {}, 5000, "client");
    if (closed.length) note += `\n[Closed on screen: ${closed.join(", ")}]`;
  } catch { /* same */ }
  return note;
}

export function tool(name, description, shape, fn) {
  server.registerTool(name, { description, inputSchema: shape }, async (args) => {
    let result;
    try {
      result = await fn(args ?? {});
    } catch (e) {
      result = fail(String(e.message || e));
    }
    let note = await tutorialNote();
    note += await progressNote();
    if (!SHOWS_COMBAT.has(name) && await inCombat()) note += COMBAT_BANNER;
    if (note) {
      const first = result.content.find((c) => c.type === "text");
      if (first) first.text += note; else result.content.push({ type: "text", text: note.trim() });
    }
    return result;
  });
}

/** Run one mod command and return its result as JSON text. */
export async function modTool(cmd, args, timeoutMs) {
  return text(json(await call(cmd, args, timeoutMs)));
}

export const coord = z.number();
export const guid = z.string().min(1).describe("Character or item GUID from dos2_look (the name prefix is optional)");
