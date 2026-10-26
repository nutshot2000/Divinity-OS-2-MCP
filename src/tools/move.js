// Tools: movement and interaction.
import { tool, call, text, json, z, guid } from "../core.js";
import { focus, wide, CLOSE } from "../director.js";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// How long books/notes (base seconds, plus ~1 s per 40 characters, up to 12 s) and loot windows stay on screen for the
// watcher before they are closed. 0 closes them at once (faster, for unwatched runs).
const READ_SECONDS = Number(process.env.DOS2_READ_SECONDS ?? 3);
const LOOT_SECONDS = Number(process.env.DOS2_LOOT_SECONDS ?? 3);

/** A status call during polling. Stairs, ladders and doors that change area make the game briefly "not running"
 *  (and calls time out): that is part of the action succeeding, so wait and retry instead of reporting an error. */
async function poll(cmd, args, maxWaitMs = 20000) {
  const deadline = Date.now() + maxWaitMs;
  for (;;) {
    try { return await call(cmd, args, 5000); }
    catch (e) {
      if (Date.now() > deadline || !/loading|not running|No answer|last answered/.test(String(e.message))) throw e;
      await sleep(1000);
    }
  }
}

/** Poll the mod until the move with this event finishes, stalls or times out. Stops early when the character starts
 *  taking damage (walking into fire, a trap, an attack), so a bad route costs as little as possible. */
async function waitForMove(event, timeoutMs, startHp, startedInCombat = false, startStatuses = []) {
  const deadline = Date.now() + timeoutMs;
  let last = null, stillSince = Date.now();
  while (Date.now() < deadline) {
    await sleep(400);
    const s = await poll("move_status", { event });
    // Stop for fresh harm (a new status such as BURNING, or a real hit), not for poison or bleeding that was already
    // ticking before the move started.
    const newStatus = s.statuses.some((st) => !startStatuses.includes(st) && /BURNING|POISONED|BLEEDING|ACID|ELECTRIFIED|SHOCKED|FROZEN|NECROFIRE|SUFFOCATING|HIT/.test(st));
    if (startHp != null && s.hp < startHp && (newStatus || startHp - s.hp >= 5)) {
      await call("move", { x: s.x, z: s.z, run: false }); // stand still where we are
      return { outcome: `stopped: took ${startHp - s.hp} damage on the way (${s.statuses.join(", ")})`, hurt: true, ...s };
    }
    if (s.arrived) return { outcome: "arrived", ...s };
    if (s.in_combat && !startedInCombat) return { outcome: "combat started", ...s };
    if (s.in_dialog) return { outcome: "dialogue started", ...s };
    const moved = !last || Math.hypot(s.x - last.x, s.z - last.z) > 0.2;
    if (moved) { last = s; stillSince = Date.now(); }
    else if (Date.now() - stillSince > 2500) return { outcome: "stopped (blocked, unreachable or interrupted)", ...s };
  }
  return { outcome: "still walking at timeout", ...(last ?? {}) };
}

/** Walk to x,z (or an object) along a route that avoids fire, poison and other hazards. The game's own pathfinding
 *  walks straight through burning decks, so this follows waypoints from the mod's safe_path search. With
 *  allowHazards, or when no safe route can be planned (e.g. stairs that link to another level), it falls back to the
 *  game's pathfinding but still stops on damage. */
export async function walkTo({ x, z, target, run = true, timeoutMs = 30000, allowHazards = false }) {
  if (target != null) ({ x, z } = await call("object_pos", { guid: target }));
  const before = await call("move_status", { event: "" });
  const startHp = before.hp;
  let route = null;
  if (!allowHazards) {
    route = await call("safe_path", { x, z }).catch((e) => ({ error: String(e.message) }));
    // A person or object often stands on a cell the grid marks blocked: walk to it with the game's own pathing
    // (still stopping on damage). Only a hazard on every route is a reason to refuse.
    const blockedTarget = target != null && /blocked/.test(route.error ?? "") && !/hazard|fire|poison/.test(route.error);
    if (route.error && (/Too far|multi-level/.test(route.error) || blockedTarget)) route = null;
    else if (route.error) return { outcome: `not moving: ${route.error}. Pass allow_hazards=true to go anyway.`, refused: true };
  }
  const deadline = Date.now() + timeoutMs;
  const legs = route?.waypoints ?? [{ x, z, direct: true }];
  if (legs.length === 0) return { outcome: "arrived", ...before }; // already standing on the goal cell
  let r = null;
  for (const w of legs) {
    const { event } = target != null && (w === legs[legs.length - 1]) && route == null
      ? await call("move", { target, run })
      : await call("move", { x: w.x, z: w.z, run });
    r = await waitForMove(event, Math.max(2000, deadline - Date.now()), startHp, before.in_combat, before.statuses);
    if (r.outcome !== "arrived") break;
  }
  return r;
}

tool("dos2_move", "Walk the active character (the party follows) to a point or an object along a route that avoids " +
  "fire, poison and other hazards. Waits until it arrives, stops, or combat/dialogue starts, and stops at once if the " +
  "character takes damage. Refuses when every route crosses a hazard unless allow_hazards=true. In combat, moving " +
  "costs AP. Give x,z (y is read from the ground) or target.",
  {
    x: z.number().optional(), z: z.number().optional(),
    target: guid.optional(),
    run: z.boolean().optional().describe("Run instead of walk (default true)"),
    allow_hazards: z.boolean().optional().describe("Walk through hazards if needed (default false)"),
    timeout: z.number().min(2).max(55).optional().describe("Seconds to wait (default 30)"),
  },
  async (a) => {
    if (a.target == null && (a.x == null || a.z == null)) throw new Error("Give x and z, or a target GUID");
    const r = await walkTo({ x: a.x, z: a.z, target: a.target, run: a.run ?? true, allowHazards: a.allow_hazards,
      timeoutMs: (a.timeout ?? 30) * 1000 });
    if (r.refused) return text(r.outcome);
    call("party_gather", {}).catch(() => {}); // the rest of the party follows (out of combat)
    return text(`${r.outcome}: now at ${r.x},${r.z}` + (r.dist_to_goal != null ? `, ${r.dist_to_goal}m from the goal` : "") +
      (r.hp != null ? `, ${r.hp} HP` : ""));
  });

tool("dos2_use", "Use an item with the active character: open a container or door, pull a lever, pick something up. " +
  "The character walks there first.",
  { item: guid, timeout: z.number().min(2).max(55).optional().describe("Seconds to wait (default 20)") },
  async (a) => {
    // CharacterUseItem does not walk there (and still reports success), so get within reach first.
    const near = await call("use_status", { item: a.item });
    if (!near.carried && (near.dist == null || near.dist > 2)) {
      const m = await walkTo({ target: a.item });
      if (m.refused || m.hurt || !/arrived|stopped/.test(m.outcome)) return text(`Did not reach the item: ${m.outcome}`);
    }
    const before = await call("move_status", { event: "" });
    await call("book_text", {}, 5000, "client").catch(() => []); // forget pages read earlier
    // Using an item straight after a walk crashed the game four times (a null write in the client's item-action code;
    // the mod also purges queued tasks first). Let the character come to a stop (up to ~3 s): same spot twice running.
    // The camera close-up comes once the item is open, not before.
    for (let i = 0, last = before; i < 10; i++) {
      await sleep(300);
      const now = await call("move_status", { event: "" });
      if (Math.hypot(now.x - last.x, now.z - last.z) < 0.05) break;
      last = now;
    }
    const started = await call("use", { item: a.item });
    const deadline = Date.now() + (a.timeout ?? 20) * 1000;
    let s = {};
    while (Date.now() < deadline) {
      await sleep(400);
      s = await poll("use_status", { item: started.guid });
      if (s.in_combat || s.in_dialog) break;
      // A container reports "used" before its loot window is open; give it a moment to open.
      if (s.result && (!started.tags.includes("container") || s.opened || s.result === "failed")) break;
    }
    const outcome = s.result === "used" ? "used" : s.result === "failed" ? "failed (out of reach, locked or not usable)"
      : s.in_combat ? "interrupted: combat started" : s.in_dialog ? "interrupted: dialogue started" : "no result yet (still walking?)";
    // Notes and books: give the text, as the book screen showed it.
    await sleep(500);
    const pages = await call("book_text", {}, 5000, "client").catch(() => []);
    if ((pages.length || s.opened) && !near.carried) await focus(a.item, CLOSE); // a closer look at what was opened
    if (pages.length) {
      const body = pages.map((p) => String(p).replace(/<br\s*\/?>/gi, "\n").replace(/<[^>]*>/g, "").trim()).join("\n\n");
      // Leave the book on screen long enough for the watcher to read some of it (panels close after the tool returns).
      await sleep(Math.min(12, READ_SECONDS + body.length / 40) * 1000 * (READ_SECONDS > 0 ? 1 : 0));
      await wide();
      return text(`${started.using} reads:\n${body}`);
    }
    // Same for a loot window: show what is inside for a moment.
    if (s.opened && LOOT_SECONDS > 0) await sleep(LOOT_SECONDS * 1000);
    await wide();
    // Stairs, ladders and hatches move the character: say where to, instead of a distance to the item left behind.
    const after = await poll("move_status", { event: "" });
    const moved = Math.hypot(after.x - before.x, after.z - before.z);
    if (moved > 3) return text(`${started.using}: used - now at ${after.x},${after.z} (moved ${Math.round(moved)}m). Look around with dos2_look.`);
    // An opened container: say what the loot window showed, so taking it is one dos2_loot call.
    let contents = "";
    if (s.opened) {
      const r = await call("loot_list", { container: started.guid }).catch(() => null);
      if (r) contents = `\ninside:\n${r.items.map((i) => `  ${i.name}${i.amount > 1 ? ` x${i.amount}` : ""} [${i.guid}]` +
        (i.owned_by ? ` (owned by ${i.owned_by})` : "")).join("\n") || "  nothing"}` +
        (r.items.length ? `\nTake with dos2_loot container=${started.guid} take="all".` : "");
    }
    return text(`${started.using}: ${outcome}` + (s.opened ? ", now open" : "") +
      (s.dist != null ? ` (${s.dist}m away)` : "") + contents);
  });

tool("dos2_say", "Narrate: show a short line of overhead text on the active character so the watching player knows " +
  "what you are about to do and why. Keep it under ~80 characters.",
  { text: z.string().min(1).max(160) },
  async (a) => text(json(await call("say", a))));
