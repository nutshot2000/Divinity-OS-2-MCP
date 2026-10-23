// Tools: turn-based combat. Actions go through the game's own attack/skill/end-turn commands with all rule checks on;
// the tools then wait for the action (or the enemies' turns) to play out and report the new state.
import { readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { tool, call, text, z, guid } from "../core.js";
import { focus, focusBetween, wide, MEDIUM } from "../director.js";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// Combat log entries already shown; in a temp file too, like the dialogue mark, for one-shot CLI calls.
const MARK = join(tmpdir(), "dos2-bridge-combat-mark.txt");
let logUpTo = (() => { try { return Number(readFileSync(MARK, "utf8")) || 0; } catch { return 0; } })();

const hpText = (f) => `${f.hp}/${f.max_hp} HP` + (f.armor ? `, ${f.armor} armour` : "") + (f.magic_armor ? `, ${f.magic_armor} magic armour` : "");

function show(s) {
  // The engine raises ObjectTurnStarted repeatedly; keep casts and deaths, and only the latest turn line.
  // A level change reports every dead creature in the area at once: keep a handful and count the rest.
  let deaths = 0;
  s.log = s.log.filter((e) => e.event !== "died" || ++deaths <= 6);
  const lastTurn = s.log.map((e) => e.event).lastIndexOf("turn");
  const extra = deaths > 6 ? `(${deaths - 6} more died; many at once usually means a new area loaded)\n` : "";
  const log = extra + s.log.filter((e, i) => e.event !== "turn" || i === lastTurn).map((e) => e.event === "cast" ? `${e.who} cast ${e.skill}` : e.event === "died" ? `${e.who} died`
    : e.event === "turn" ? `-- ${e.who}'s turn` : e.event).join("\n");
  if (!s.in_combat) return (log ? `${log}\n\n` : "") + "Not in combat.";
  const fighters = s.fighters.map((f) => `  ${f.order}. ${f.name} [${f.guid}] ${hpText(f)}, ${f.ap} AP, ${f.dist}m at ${f.x},${f.z}` +
    (f.hit_chance != null && f.tags.includes("enemy") ? `, ${f.hit_chance}% to hit` : "") +
    (f.tags.length ? ` (${f.tags.join(", ")})` : "") + (f.statuses.length ? ` statuses: ${f.statuses.join(", ")}` : ""));
  return (log ? `${log}\n\n` : "") +
    `${s.my_turn ? "YOUR TURN" : `${s.active}'s turn`}: ${s.me.name} ${hpText(s.me)}, ${s.me.ap} AP at ${s.me.x},${s.me.z}\n` +
    `turn order:\n${fighters.join("\n")}`;
}

// The mod's log restarts at 0 after a game restart; a stale mark would hide everything, so it is reset then.
// Every poll moves the mark forward, so each log entry is returned exactly once (polling loops used to fetch the same
// entries again on every poll).
const state = async () => {
  let s = await call("combat", { since: logUpTo });
  if (s.log_last < logUpTo) s = await call("combat", { since: 0 });
  logUpTo = s.log_last;
  try { writeFileSync(MARK, String(logUpTo)); } catch { /* best effort */ }
  return s;
};

/** After an action: wait until AP drops, the turn passes or the fight ends (max ~12 s). */
async function afterAction(apBefore) {
  const log = [];
  for (let i = 0; i < 30; i++) {
    await sleep(400);
    const s = await state();
    log.push(...s.log);
    if (!s.in_combat || !s.my_turn || s.me.ap < apBefore) break;
  }
  await sleep(800); // let the animation and damage land
  const final = await state();
  // The game refuses actions silently (requirement not met, out of range, blocked): nothing changes at all.
  final.refused = final.in_combat && final.my_turn && final.me.ap >= apBefore;
  final.log = [...log, ...final.log];
  return final;
}

/** Wait until it is the active character's turn again or combat ends (max ~50 s, under client timeouts). */
async function waitForTurn() {
  const log = [];
  let s, watching = null;
  for (let i = 0; i < 100; i++) {
    s = await state();
    log.push(...s.log);
    if (!s.in_combat || s.my_turn) break;
    // Camera: follow whoever is acting (only if visible; the director checks).
    if (s.active_guid && s.active_guid !== watching) { watching = s.active_guid; await focus(watching, MEDIUM); }
    await sleep(500);
  }
  if (!s.in_combat) await wide(); else await focus(null, MEDIUM);
  s.log = log;
  return s;
}

tool("dos2_combat", "Combat status: whose turn it is, your HP/armour/AP, and the turn order with every combatant you " +
  "can see (HP, armour, AP, distance, statuses), plus what happened since the last call.",
  {}, async () => text(show(await state())));

tool("dos2_skills", "Your character's skills as the hotbar shows them: id, name, AP cost, cooldown (and turns left), " +
  "range, area, damage type, what it can target, and its tooltip text. Only memorised skills can be used.",
  { all: z.boolean().optional().describe("Include learned but not memorised skills") },
  async (a) => {
    const skills = (await call("skills")).filter((s) => a.all || s.memorised);
    return text(skills.map((s) => `${s.id} "${s.name}": ${s.ap} AP, cooldown ${s.cooldown_turns}` +
      (s.cooldown_left ? ` (${s.cooldown_left} turns left)` : "") + (s.range ? `, range ${s.range}m` : "") +
      (s.area ? `, area ${s.area}m` : "") + (s.damage_type ? `, ${s.damage_type}` : "") +
      ` [${Object.entries(s.targets).filter(([, v]) => v).map(([k]) => k).join("/") || "self"}]` +
      (s.memorised ? "" : " (not memorised)") + (s.granted ? " (granted by gear or status)" : "") +
      (s.requirement ? ` (${s.requirement.text}${s.requirement.met ? "" : ": NOT MET"})` : "") + (s.description ? `\n    ${s.description.replace(/<[^>]*>/g, "")}` : ""))
      .join("\n") || "No skills.");
  });

tool("dos2_attack", "Basic weapon attack on a target (walks into range if needed, costs AP). Waits for the hit, then " +
  "returns the combat status.",
  { target: guid },
  async (a) => {
    await focusBetween(a.target, MEDIUM);
    const r = await call("attack", a);
    return text(`Attacking ${r.attacking}\n` + show(await afterAction(r.ap_before)));
  });

tool("dos2_cast", "Use a memorised skill (id from dos2_skills) on a target GUID, or on the ground at x,z. The game " +
  "checks AP, cooldown and range. Waits for it to land, then returns the combat status.",
  { skill: z.string(), target: guid.optional(), x: z.number().optional(), z: z.number().optional() },
  async (a) => {
    if (a.target == null && (a.x == null || a.z == null)) throw new Error("Give a target GUID, or x and z");
    if (a.target) await focusBetween(a.target, MEDIUM);
    const r = await call("cast", a);
    return text(`Casting ${r.casting}\n` + show(await afterAction(r.ap_before)));
  });

tool("dos2_end_turn", "End your turn, then wait while the other combatants act (up to ~50 s) and return the combat " +
  "status when it is your turn again or the fight is over. Call again if it is still someone else's turn.",
  {}, async () => {
    // At 0 AP the game ends the turn itself; then there is nothing to end, only waiting to do.
    try { await call("end_turn"); } catch (e) { if (!/Not .*turn/.test(String(e.message))) throw e; }
    // The turn does not pass at once: wait for it to leave us first, or waitForTurn would return immediately.
    for (let i = 0; i < 20; i++) {
      await sleep(250);
      const s = await state();
      if (!s.in_combat || !s.my_turn) break;
    }
    return text(show(await waitForTurn()));
  });

tool("dos2_wait_turn", "Wait (up to ~50 s) until it is your turn or combat ends, then return the combat status.",
  {}, async () => text(show(await waitForTurn())));

tool("dos2_tactics", "Positioning map for combat: which squares this turn's AP can actually walk to (around walls), " +
  "high and low ground, hazards, and visible enemies (E) and allies (A), plus the best reachable spots (high ground, " +
  "no hazard, not flanked). Legend: @ you, . reachable, , beyond this turn, ^ reachable high ground (' beyond), " +
  "v reachable low ground (; beyond), # blocked, ? unexplored, f fire, p poison, o oil, e electrified, i ice, x web, ! lava.",
  { radius: z.number().int().min(5).max(20).optional().describe("Metres (default 12)") },
  async (a) => {
    const t = await call("tactics", a);
    const spots = t.high_ground.map((s) => `  ${s.x},${s.z}: ${s.ap} AP, height ${s.height >= 0 ? "+" : ""}${s.height}m` +
      (s.nearest_enemy != null ? `, nearest enemy ${s.nearest_enemy}m` : "") + (s.flanked ? " (flanked there)" : ""));
    const enemies = t.enemies.map((e) => `  ${e.name} ${e.dist}m at ${e.x},${e.z}, height ${e.height >= 0 ? "+" : ""}${e.height}m`);
    return text(`${t.ap} AP x ${t.metres_per_ap} m/AP = ${t.reach} m of walking this turn. Rows are z (north up), columns x.\n` +
      t.rows.join("\n") + `\n\nenemies in sight:\n${enemies.join("\n") || "  none"}\n\nbest reachable spots:\n${spots.join("\n") || "  none (no AP, or nowhere better)"}`);
  });


tool("dos2_preview", "Before casting or throwing: who a skill (id from dos2_skills) or an item (GUID, e.g. a grenade " +
  "or scroll) would hit if aimed at a target GUID or the ground at x,z - allies included - and whether it is in range.",
  { skill: z.string().optional(), item: guid.optional(), target: guid.optional(), x: z.number().optional(), z: z.number().optional() },
  async (a) => {
    if (a.skill == null && a.item == null) throw new Error("Give a skill id or an item GUID");
    const p = await call("skill_preview", a);
    const hits = p.hits.map((h) => `  ${h.name}${h.tags.length ? ` (${h.tags.join(", ")})` : ""}`).join("\n");
    return text(`${p.skill}: ${p.ap} AP, range ${p.range}m, ` + (p.cone ? `cone` : p.area ? `area ${p.area}m` : "single target") +
      `. Aim point ${p.aim_dist}m away: ${p.in_range ? "in range" : "OUT OF RANGE"}.\nwould hit:\n${hits || "  nobody visible"}`);
  });

tool("dos2_use_on", "Throw or read an item from your inventory at a target GUID or the ground at x,z: grenades " +
  "(e.g. Bottled Inferno), skill scrolls (e.g. Fireball Scroll). Costs the item's skill AP; one item is used up only " +
  "if the throw or cast actually happens. Check dos2_preview first so allies are not caught in it.",
  { item: guid, target: guid.optional(), x: z.number().optional(), z: z.number().optional() },
  async (a) => {
    const before = await state();
    if (a.target) await focusBetween(a.target, MEDIUM);
    const r = await call("use_item", a);
    const s = await afterAction(r.ap_before);
    const cast = s.log.some((e) => e.event === "cast" && e.skill === r.skill) ||
      (await call("combat", { since: before.log_last })).log.some((e) => e.event === "cast" && e.skill === r.skill);
    if (!cast) return text(`The game did not use ${r.using} (nothing spent): out of range, no line of sight or not enough AP?\n` + show(s));
    await call("consume_item", { template: r.template });
    return text(`Used ${r.using} (${r.skill}).\n` + show(s));
  });
