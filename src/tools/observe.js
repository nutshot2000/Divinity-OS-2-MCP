// Tools: observe.
import { tool, modTool, call, text, json, z, inCombat } from "../core.js";
import { whatsLeft } from "./sweep.js";
import { resetDone } from "../done.js";

tool("dos2_status", "Party overview: level (map), active character, each party member's position, HP, armour, AP, " +
  "level, and whether they are in combat, in dialogue or dead.",
  {}, () => modTool("status"));

tool("dos2_look", "What the active character can see, nearest first: characters (enemy/ally/neutral, dead) and items " +
  "(containers, locked) with GUID, position and distance. Only objects in line of sight; never container contents.",
  {
    radius: z.number().min(1).max(60).optional().describe("Metres around the active character (default 20)"),
    kind: z.enum(["all", "characters", "items"]).optional(),
    limit: z.number().int().min(1).max(200).optional().describe("Max entries per kind (default 40)"),
  },
  async (a) => {
    const r = await call("look", a);
    const line = (o) => `  ${o.name} [${o.guid}] ${o.x},${o.z} ${o.dist}m` + (o.tags.length ? ` (${o.tags.join(", ")})` : "");
    return text(`${r.level}: ${r.from.name} at ${r.from.x},${r.from.z} (y ${r.from.y}), radius ${r.radius}m\n` +
      (r.warning ? `WARNING: ${r.warning}\n` : "") +
      (r.characters ? `characters:\n${r.characters.map(line).join("\n") || "  none"}\n` : "") +
      (r.items ? `items:\n${r.items.map(line).join("\n") || "  none"}\n` : "") +
      (r.truncated ? `(more beyond the limit; raise limit or lower radius)\n` : ""));
  });

tool("dos2_grid", "ASCII walkability map from the game's AI grid around the active character (or x,z). " +
  "@ you, P party, . walkable, # blocked, ~ deep water, w water, f fire, p poison, o oil, b blood, e electrified, " +
  "i ice, x web, d door, ! lava/deathfog, ? not seen yet (further than about 14 m from anywhere you have stood). Rows " +
  "are z (north at top), columns x; rulers mark every 10 m. To find where to go next, use dos2_explore.",
  {
    x: z.number().optional(), z: z.number().optional(),
    radius: z.number().min(4).max(40).optional().describe("Metres (default 15)"),
    step: z.number().min(0.5).max(4).optional().describe("Metres per character (default 1)"),
  },
  async (a) => {
    const r = await call("grid", a);
    return text(`${r.level} centre ${r.x},${r.z} step ${r.step}m  x ${r.x1}..${r.x2}  z ${r.z2}..${r.z1} (top to bottom)\n` +
      r.rows.join("\n"));
  });

tool("dos2_explore", "Where to go next in a big area. Lists the nearest edges of the explored map (walkable ground that " +
  "touches fog of war) by walking distance and direction, skipping edges you have already stood next to, and says how " +
  "much of the reachable area you have covered. Use it whenever you are unsure where to go, or notice you are walking " +
  "in circles: take the nearest edge with dos2_move, look, loot, repeat. When no edges are left the area is done.",
  { radius: z.number().min(10).max(90).optional().describe("Metres to search (default 60)"),
    reset: z.boolean().optional().describe("Forget everywhere visited on this level (a new playthrough)") },
  async (a) => {
    if (await inCombat()) return text("Not exploring: you are in combat. Call dos2_combat and play the fight (dos2_tactics, " +
      "dos2_attack, dos2_cast, dos2_end_turn). Explore again when the fight is over.");
    if (a.reset) resetDone();
    const r = await call("explore", a);
    const line = (e) => `  ${e.dist}m ${e.dir}: dos2_move x=${e.x} z=${e.z}  (a ${e.size}m stretch of unexplored edge)`;
    const out = [`At ${r.x},${r.z}. Reachable explored ground: about ${r.reachable_m2} m2, ${r.covered_pct}% of it stood on ` +
      `(${r.places_visited} places visited on this level).`];
    if (r.edges.length) out.push(`Unexplored edges, nearest first:\n${r.edges.map(line).join("\n")}`);
    else out.push("No unexplored edge is reachable from here: this part is finished. The way on is a door, stairs or " +
      "ladder you have not used yet, a locked or hazard-blocked route, or somewhere further than the search radius.");
    if (r.visited_edges.length) out.push(`Edges you already stood beside (dark rock or sea, not a way on):\n${r.visited_edges.map(line).join("\n")}`);
    if (r.truncated) out.push("The search hit its size limit: this is the nearest part of a very large area.");
    // What is left to do right here, so nothing is skipped on the way to the next edge.
    try {
      const left = await whatsLeft(25);
      const todo = [
        ...left.containers.map((o) => `  open: ${o.name} ${o.dist}m: dos2_use item=${o.guid} take=true`),
        ...left.reads.map((o) => `  read: ${o.name} ${o.dist}m: dos2_use item=${o.guid}`),
        ...left.people.map((c) => `  talk: ${c.name} ${c.dist}m: dos2_talk target=${c.guid}`),
        ...left.locked.map((o) => `  locked: ${o.name} ${o.dist}m (needs a key or lockpicks)`),
      ];
      if (todo.length) out.push(`Still to do within sight (finish these before moving on; dos2_sweep opens the containers in one go):\n${todo.slice(0, 14).join("\n")}`);
    } catch { /* not essential */ }
    return text(out.join("\n"));
  });
