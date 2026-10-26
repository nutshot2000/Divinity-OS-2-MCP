// Camera director: frames the action for the person watching, without the playing model having to think about it.
// Talking zooms in on both speakers, attacks and casts frame attacker and target, enemy turns follow whoever acts,
// opening or reading something takes a closer look. Every move goes through the server's fair-play check (only
// visible objects), and a camera problem never fails the tool that asked for it. DOS2_CINEMATIC=0 turns it off.
import { call } from "./bridge.js";

const ENABLED = process.env.DOS2_CINEMATIC !== "0";
export const WIDE = 19;    // the game's maximum zoom-out: normal exploring view
export const MEDIUM = 13;  // combat actions
export const CLOSE = 9;    // conversations, looting, reading

async function cameraAt(point, zoom) {
  await call("camera", { ...point, zoom }, 5000, "client");
}

/** Frame one visible object (or the acting character when no target is given). */
export async function focus(target, zoom = MEDIUM) {
  if (!ENABLED) return;
  try { await cameraAt(await call("camera_point", target ? { target } : {}, 5000), zoom); } catch { /* cosmetic */ }
}

/** Frame the acting character and a visible target together: the point halfway between them. */
export async function focusBetween(target, zoom = MEDIUM) {
  if (!ENABLED || !target) return;
  try {
    const me = await call("camera_point", {}, 5000);
    const them = await call("camera_point", { target }, 5000);
    // Pull out a little for targets far away, so both stay on screen.
    const dist = Math.hypot(them.x - me.x, them.z - me.z);
    await cameraAt({ x: (me.x + them.x) / 2, y: (me.y + them.y) / 2, z: (me.z + them.z) / 2 },
      Math.min(WIDE, Math.max(zoom, dist * 0.9 + 4)));
  } catch { /* cosmetic */ }
}

/** Back to the normal exploring view, centred on the acting character. */
export async function wide() {
  if (!ENABLED) return;
  try { await cameraAt(await call("camera_point", {}, 5000), WIDE); } catch { /* cosmetic */ }
}

// Item handling is shown on screen for the watcher: the inventory panel opens before the action and stays up for a few
// seconds after it (DOS2_INV_SECONDS, default 3; 0 turns it off). The mod shows the character sheet too, but only once the game has
// filled it in (forcing it open earlier crashed the game).
export const INV_SECONDS = Number(process.env.DOS2_INV_SECONDS ?? 3);
let inventoryHinted = false;
/** Opens the inventory screen for the watcher. Returns "" or, once per run, a hint when the game has not created that
 *  screen yet (it only does so the first time a player opens it: pressing I once is enough). */
export async function showInventory() {
  if (!(INV_SECONDS > 0)) return "";
  try { await call("show_inventory", {}, 5000, "client"); }
  catch (e) {
    if (/No inventory screen/.test(String(e.message)) && !inventoryHinted) {
      inventoryHinted = true;
      return "\n[The inventory is not shown on screen: press I once in the game, and from then on it opens by itself.]";
    }
    return "";
  }
  await new Promise((r) => setTimeout(r, 1200)); // let it appear before anything changes
  return "";
}
export const holdInventory = () => INV_SECONDS > 0 ? new Promise((r) => setTimeout(r, INV_SECONDS * 1000)) : Promise.resolve();

/** Show the character sheet on a tab (0 attributes, 1 combat abilities, 2 civil, 3 talents) while points are spent. Returns
 *  "" or, once per run, a hint that the player has to open the sheet once (press I) before the bridge can. */
let sheetHinted = false;
export async function showSheet(tab = 0) {
  if (!(INV_SECONDS > 0)) return "";
  try { await call("show_sheet", { tab }, 5000, "client"); }
  catch (e) {
    if (/No character sheet/.test(String(e.message)) && !sheetHinted) {
      sheetHinted = true;
      return "\n[The character sheet is not shown on screen: press I once in the game, and from then on it opens by itself.]";
    }
    return "";
  }
  await new Promise((r) => setTimeout(r, 1200));
  return "";
}

/** A short caption over the acting character so the watcher knows what changed (overhead text; cosmetic, never fails). */
export async function caption(text) {
  if (process.env.DOS2_CAPTIONS === "0") return; // DOS2_CAPTIONS=0 turns all on-screen captions off
  try { await call("say", { text }, 5000); } catch { /* cosmetic */ }
}
