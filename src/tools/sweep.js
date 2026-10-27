// Tool: dos2_sweep, and the "what is left here" list that dos2_explore appends. Both work from dos2_look (what the
// character can see) and the memory of what has already been used or talked to (src/done.js).
import { tool, call, text, z, inCombat } from "../core.js";
import { useItem, walkTo } from "./move.js";
import { markUsed } from "../done.js";
import { isUsed, isTalked } from "../done.js";

// Things a player reads rather than opens: found by name, since the game gives no tag for them.
const READABLE = /\b(note|letter|book|tome|journal|diary|page|scroll|rhyme|requisition|map|sign|plaque|inscription)\b/i;

/** Unopened containers, unread notes and people not yet talked to, from one look around. */
export async function whatsLeft(radius = 25) {
  const r = await call("look", { radius, limit: 60 });
  const owned = (o) => o.tags.some((t) => t.startsWith("owned by"));
  const containers = (r.items ?? []).filter((o) => o.tags.includes("container") && !owned(o) && !isUsed(o.guid));
  const locked = containers.filter((o) => o.tags.includes("locked"));
  const reads = (r.items ?? []).filter((o) => !o.tags.includes("container") && READABLE.test(o.name) && !owned(o) && !isUsed(o.guid));
  const people = (r.characters ?? []).filter((c) => !c.tags.some((t) => /enemy|dead|party/.test(t)) && !isTalked(c.guid));
  const bodies = (r.characters ?? []).filter((c) => c.tags.includes("dead") && !c.tags.includes("party") && !isUsed(c.guid));
  return { containers: containers.filter((o) => !locked.includes(o)), locked, reads, people, bodies };
}

tool("dos2_sweep", "Open every container within reach and loot every dead body, taking what is not owned: a quick loot of the room. Skips owned " +
  "containers (that would be stealing) and locked ones, stops if combat or a conversation starts. Notes and books nearby are " +
  "listed, not read: use dos2_use on them. Out of combat only. Use it instead of one dos2_use per chest.",
  { radius: z.number().min(3).max(40).optional().describe("Metres around the active character (default 15)"),
    max: z.number().int().min(1).max(15).optional().describe("Most containers to open (default 8)") },
  async (a) => {
    if (await inCombat()) return text("Not sweeping: you are in combat. Call dos2_combat.");
    const left = await whatsLeft(a.radius ?? 15);
    const targets = left.containers.slice(0, a.max ?? 8);
    const out = [];
    for (const o of targets) {
      const r = await useItem({ item: o.guid, take: true, quick: true });
      const first = r.content[0].text.split("\n")[0];
      out.push(`${o.name} [${o.guid}] ${o.dist}m: ${r.content[0].text.replace(/\n+/g, " | ").slice(0, 260)}`);
      if (/interrupted|dialogue started|combat|Did not reach|Not doing that/.test(first + r.content[0].text.slice(0, 80))) { out.push("Stopped early (combat, dialogue or an unreachable container)."); break; }
    }
    // Dead bodies carry loot too (animals included: a crocodile held Gloves of Teleportation).
    for (const b of left.bodies.slice(0, 6)) {
      if (await inCombat()) { out.push("Stopped: combat started."); break; }
      try {
        const m = await walkTo({ target: b.guid });
        if (m.refused || m.hurt || !/arrived|stopped/.test(m.outcome)) { out.push(`${b.name} [${b.guid}]: could not reach it (${m.outcome})`); continue; }
        await new Promise((res) => setTimeout(res, 1500)); // let a fresh body settle before touching its items
        const t = await call("loot_take", { container: b.guid });
        markUsed(b.guid);
        out.push(`${b.name} (dead) [${b.guid}]: took ${t.taken.map((i) => i.name + (i.amount > 1 ? ` x${i.amount}` : "")).join(", ") || "nothing"}` +
          (t.skipped_owned.length ? ` (left: ${t.skipped_owned.map((i) => i.name).join(", ")})` : ""));
      } catch (e) { out.push(`${b.name} [${b.guid}]: ${String(e.message).split("\n")[0]}`); }
    }
    const rest = [];
    if (left.locked.length) rest.push(`locked (need a key or lockpicks): ${left.locked.map((o) => `${o.name} [${o.guid}]`).join(", ")}`);
    if (left.reads.length) rest.push(`to read (dos2_use): ${left.reads.map((o) => `${o.name} [${o.guid}]`).join(", ")}`);
    if (left.people.length) rest.push(`people to talk to (dos2_talk): ${left.people.map((c) => `${c.name} [${c.guid}]`).join(", ")}`);
    return text((out.join("\n") || "Nothing to open or loot in reach.") + (rest.length ? `\n\nStill to do here:\n${rest.join("\n")}` : ""));
  });
