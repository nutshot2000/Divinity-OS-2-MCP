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
    const note = await tutorialNote();
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
