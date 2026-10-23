// Tools: character sheet, levelling, memorised skills and party control.
import { tool, call, text, z, guid } from "../core.js";

const who = { character: guid.optional().describe("Party member GUID (default: the acting character)") };

tool("dos2_sheet", "Character sheet: level, experience, unspent attribute/combat/civil/talent points, attributes " +
  "(base and with gear), combat and civil abilities, talents, learned skills (memorised or not) and free memory slots. " +
  "talents=true also lists the talents you could pick.",
  { ...who, talents: z.boolean().optional() },
  async (a) => {
    const s = await call("sheet", a);
    const attrs = Object.entries(s.attributes).map(([k, v]) => `${k} ${v.base}${v.total !== v.base ? ` (${v.total})` : ""}`).join(", ");
    const nonZero = (o) => Object.entries(o).filter(([, v]) => v > 0).map(([k, v]) => `${k} ${v}`).join(", ") || "none";
    const pts = s.points;
    return text(`${s.name}, level ${s.level} (${s.experience} XP)\n` +
      `unspent: ${pts.attribute} attribute, ${pts.combat} combat, ${pts.civil} civil, ${pts.talent} talent ` +
      `(caps: attribute ${s.caps.attribute}, combat ${s.caps.combat}, civil ${s.caps.civil})\n` +
      `attributes: ${attrs}\ncombat abilities: ${nonZero(s.combat)}\ncivil abilities: ${nonZero(s.civil)}\n` +
      `talents: ${s.talents.join(", ") || "none"}\n` +
      `skills (${s.free_memory_slots} free memory slots):\n` +
      s.skills.map((k) => `  ${k.id} "${k.name}" ${k.memorised ? "memorised" : "not memorised"}, memory ${k.memory_cost}`).join("\n") +
      (s.pickable_talents ? `\npickable talents: ${s.pickable_talents.join(", ")}` : "") +
      `\nall combat abilities: ${Object.keys(s.combat).join(", ")}\nall civil abilities: ${Object.keys(s.civil).join(", ")}`);
  });

tool("dos2_level_up", "Spend one unspent point, like a + button on the character sheet (out of combat only): " +
  "kind attribute (Strength, Finesse, Intelligence, Constitution, Memory, Wits), combat or civil (ability names from " +
  "dos2_sheet), or talent (from dos2_sheet talents=true). Respects the game's caps.",
  { ...who, kind: z.enum(["attribute", "combat", "civil", "talent"]), name: z.string(),
    times: z.number().int().min(1).max(10).optional().describe("Spend this many points on it (default 1)") },
  async (a) => {
    let done = 0;
    try {
      for (let i = 0; i < (a.times ?? 1); i++) { await call("level_up", a); done++; }
    } catch (e) {
      if (!done) throw e;
      return text(`Spent ${done} on ${a.name}, then: ${e.message}`);
    }
    return text(`Spent ${done} ${a.kind} point${done > 1 ? "s" : ""} on ${a.name}.`);
  });

tool("dos2_memorise", "Memorise a learned skill (uses memory slots) or forget=true to unmemorise it, out of combat. " +
  "Only memorised skills can be used.",
  { ...who, skill: z.string(), forget: z.boolean().optional() },
  async (a) => {
    const r = await call("memorise", a);
    // Free slots are recomputed by the game on a later tick; dos2_sheet shows the settled number.
    return text(`${r.skill} ${r.memorised ? "memorised" : "forgotten"}.`);
  });

tool("dos2_party", "The party: each member's level, HP, position, whether they are the one the tools act with, " +
  "chained to them, or sneaking. action=select picks who acts (moves, attacks, skills, talking, looting); " +
  "action=chain / unchain links a member to the acting character or lets them move alone.",
  { action: z.enum(["list", "select", "chain", "unchain"]).optional(), character: guid.optional() },
  async (a) => {
    if (a.action === "select") return text(`Now acting as ${(await call("party_select", a)).acting}.`);
    if (a.action === "chain" || a.action === "unchain") {
      const r = await call("party_chain", { character: a.character, chain: a.action === "chain" });
      return text(`${r.character} ${r.chained ? "chained" : "unchained"}.`);
    }
    const p = await call("party");
    return text(p.map((m) => `  ${m.acting ? "*" : " "} ${m.name} [${m.guid}] level ${m.level}, ${m.hp}/${m.max_hp} HP at ${m.x},${m.z}` +
      (m.dead ? " (dead)" : "") + (m.chained ? " (chained)" : "") + (m.sneaking ? " (sneaking)" : "")).join("\n") +
      "\n(* = acting character)");
  });

tool("dos2_sneak", "Start (on=true) or stop sneaking with the acting character, out of combat. Sneaking characters " +
  "are harder to spot but move slowly.",
  { on: z.boolean() },
  async (a) => text(`${(await call("sneak", a)).character} ${a.on ? "is sneaking" : "stopped sneaking"}.`));
