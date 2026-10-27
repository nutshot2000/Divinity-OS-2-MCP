// What has already been done in this playthrough: items used, opened or read, and people talked to. Kept in a temp file
// (like the other marks) so one-shot CLI calls and restarts share it. dos2_explore and dos2_sweep use it to say what is
// left. `dos2_explore reset=true` clears it for a new playthrough.
import { readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const FILE = join(tmpdir(), "dos2-bridge-done.json");
let data = (() => { try { return JSON.parse(readFileSync(FILE, "utf8")); } catch { return { used: {}, talked: {} }; } })();
const save = () => { try { writeFileSync(FILE, JSON.stringify(data)); } catch { /* best effort */ } };
const bare = (g) => String(g ?? "").slice(-36);

export const markUsed = (guid) => { data.used[bare(guid)] = true; save(); };
export const markTalked = (guid) => { data.talked[bare(guid)] = true; save(); };
export const isUsed = (guid) => data.used[bare(guid)] === true;
export const isTalked = (guid) => data.talked[bare(guid)] === true;
export const resetDone = () => { data = { used: {}, talked: {} }; save(); };
