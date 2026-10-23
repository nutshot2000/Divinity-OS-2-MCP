#!/usr/bin/env node
// MCP server: play Divinity: Original Sin 2 through the Script Extender. Tool groups register themselves on import.
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { server } from "./core.js";
import "./tools/observe.js";
import "./tools/move.js";
import "./tools/loot.js";
import "./tools/dialog.js";
import "./tools/misc.js";

const transport = new StdioServerTransport();
await server.connect(transport);
