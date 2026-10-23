// Tools: observe.
import { tool, modTool, call, text, json, z } from "../core.js";

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
  "i ice, x web, d door, ! lava/deathfog, ? unexplored (fog of war). Rows are z (north at top), columns x; rulers " +
  "mark every 10 m.",
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
