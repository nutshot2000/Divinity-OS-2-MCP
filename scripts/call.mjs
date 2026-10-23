// Dev helper: node scripts/call.mjs <tool> [json-args]  (or "list")
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { fileURLToPath } from "node:url";

const server = fileURLToPath(new URL("../src/server.js", import.meta.url));
const client = new Client({ name: "dos2-bridge-cli", version: "0" });
await client.connect(new StdioClientTransport({ command: process.execPath, args: [server], env: { ...process.env } }));
const [name = "list", raw = "{}"] = process.argv.slice(2);
if (name === "list") {
  for (const t of (await client.listTools()).tools) console.log(t.name);
} else {
  const res = await client.callTool({ name, arguments: JSON.parse(raw) }, undefined, { timeout: 120000 });
  for (const c of res.content) {
    if (c.type === "text") console.log(c.text);
    else if (c.type === "image") console.log(`[${c.mimeType} image returned]`);
  }
  if (res.isError) process.exitCode = 1;
}
await client.close();
