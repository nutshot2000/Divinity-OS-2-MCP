// File transport to the in-game mod. The Script Extender has no socket, so requests and responses are JSON files in
// the game's "Osiris Data" folder (the only folder Ext.IO can read and write). One request is in flight at a time.
import { existsSync, readFileSync, renameSync, writeFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const GAME_DOCS = join("Larian Studios", "Divinity Original Sin 2 Definitive Edition", "Osiris Data");
const CANDIDATES = [
  join(homedir(), "Documents", GAME_DOCS),
  join(homedir(), "OneDrive", "Documents", GAME_DOCS),
];

/** The Osiris Data folder: DOS2_DATA_DIR, else the first candidate that exists. */
export function dataDir() {
  if (process.env.DOS2_DATA_DIR) return process.env.DOS2_DATA_DIR;
  return CANDIDATES.find((d) => existsSync(d)) ?? CANDIDATES[0];
}

// The server half of the mod reads game state and acts; the client half sees the UI (dialogue, message boxes).
const FILES = {
  server: { request: "dos2bridge_request.json", response: "dos2bridge_response.json", heartbeat: "dos2bridge_heartbeat.json" },
  client: { request: "dos2bridge_client_request.json", response: "dos2bridge_client_response.json", heartbeat: "dos2bridge_client_heartbeat.json" },
};
const HEARTBEAT_STALE_MS = 5000;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function readJson(path) {
  try { return JSON.parse(readFileSync(path, "utf8").replace(/^﻿/, "")); }
  catch { return null; } // missing, or caught half-written: the caller polls again
}

/** Last heartbeat from the mod, with its age in ms, or null if the file has never been written. */
export function heartbeat(side = "server") {
  const path = join(dataDir(), FILES[side].heartbeat);
  if (!existsSync(path)) return null;
  const beat = readJson(path) ?? {};
  return { ...beat, age_ms: Date.now() - statSync(path).mtimeMs };
}

function notRunningMessage(side = "server") {
  const beat = heartbeat(side);
  if (!beat) return `No heartbeat from the DOS2 bridge mod in ${dataDir()}. Start the game with the Script Extender, ` +
    "enable the DOS2Bridge mod, and load a save (set DOS2_DATA_DIR if Osiris Data lives elsewhere).";
  if (beat.age_ms > HEARTBEAT_STALE_MS) return `The DOS2 bridge mod last answered ${Math.round(beat.age_ms / 1000)}s ago. ` +
    "Is the game running with a save loaded (not the main menu or a loading screen)?";
  return null;
}

// Requests carry an increasing seq; the mod answers each seq once. Seeding from the clock keeps a restarted server
// from reusing a seq the mod has already answered.
let seq = Date.now();
let queue = Promise.resolve();

/** Send one command to the mod (its server or client half) and wait for its answer. Resolves to the handler's
 *  result; throws its error. */
export function call(cmd, args = {}, timeoutMs = 15000, side = "server") {
  const run = queue.then(() => send(cmd, args, timeoutMs, side));
  queue = run.catch(() => {});
  return run;
}

async function send(cmd, args, timeoutMs, side) {
  const down = notRunningMessage(side);
  if (down) throw new Error(down);
  const dir = dataDir();
  const files = FILES[side];
  const id = ++seq;
  const tmp = join(dir, files.request + ".tmp");
  writeFileSync(tmp, JSON.stringify({ seq: id, cmd, args }));
  renameSync(tmp, join(dir, files.request));
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    await sleep(50);
    const res = readJson(join(dir, files.response));
    if (res?.seq !== id) continue;
    // Lua errors arrive as '[string "?"]:204: message' plus a traceback; the message is what a tool user needs.
    if (res.error) throw new Error(String(res.error).split("\n")[0].replace(/^\[string "[^"]*"\]:\d+: /, ""));
    return res.result;
  }
  throw new Error(`No answer to "${cmd}" within ${timeoutMs / 1000}s. ` + (notRunningMessage(side) ?? "The game may be paused in a menu."));
}
