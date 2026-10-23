// Dev helper: node scripts/client.mjs <command> [json-args]
// Calls the client half of the mod directly (ui_log, ui_open, ui_call, lua), for working out how a UI screen works.
import { call } from "../src/bridge.js";

const [cmd = "ping", raw = "{}"] = process.argv.slice(2);
console.log(JSON.stringify(await call(cmd, JSON.parse(raw), 15000, "client"), null, 1));
