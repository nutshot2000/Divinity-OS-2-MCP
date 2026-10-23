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

export function tool(name, description, shape, fn) {
  server.registerTool(name, { description, inputSchema: shape }, async (args) => {
    try {
      return await fn(args ?? {});
    } catch (e) {
      return fail(String(e.message || e));
    }
  });
}

/** Run one mod command and return its result as JSON text. */
export async function modTool(cmd, args, timeoutMs) {
  return text(json(await call(cmd, args, timeoutMs)));
}

export const coord = z.number();
export const guid = z.string().min(1).describe("Character or item GUID from dos2_look (the name prefix is optional)");
