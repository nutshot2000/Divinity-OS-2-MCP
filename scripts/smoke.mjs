// Smoke test: node scripts/smoke.mjs [--offline]
// Starts the server and checks every tool registers with a description and schema. Without --offline it also runs
// the read-only tools against the running game. Nothing here moves the party or changes the game.
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { fileURLToPath } from "node:url";

const dev = process.env.DOS2_DEV === "1";
const EXPECTED = ["dos2_status", "dos2_look", "dos2_grid", "dos2_move", "dos2_use", "dos2_say", "dos2_loot", "dos2_dialog", "dos2_answer", "dos2_talk", "dos2_help", "dos2_ping",
  "dos2_screenshot", ...(dev ? ["dos2_lua"] : [])];
const READ_ONLY = [["dos2_ping", {}], ["dos2_status", {}], ["dos2_look", { radius: 10, limit: 5 }],
  ["dos2_grid", { radius: 6 }], ...(dev ? [["dos2_lua", { code: "return { ok = true }" }]] : [])];

const server = fileURLToPath(new URL("../src/server.js", import.meta.url));
const client = new Client({ name: "dos2-bridge-smoke", version: "0" });
await client.connect(new StdioClientTransport({ command: process.execPath, args: [server], env: { ...process.env } }));
let failures = 0;
const tools = (await client.listTools()).tools;
for (const name of EXPECTED) {
  const t = tools.find((x) => x.name === name);
  if (!t || !t.description || !t.inputSchema) { console.log(`FAIL ${name}: not registered with description and schema`); failures++; }
}
console.log(`${tools.length} tools registered`);
if (!process.argv.includes("--offline")) {
  for (const [name, args] of READ_ONLY) {
    const res = await client.callTool({ name, arguments: args }, undefined, { timeout: 60000 });
    const out = res.content.map((c) => c.text ?? "").join("\n");
    console.log(`${res.isError ? "FAIL" : "ok  "} ${name}: ${out.split("\n")[0].slice(0, 120)}`);
    if (res.isError) failures++;
  }
}
await client.close();
process.exitCode = failures ? 1 : 0;
