// Reading recipes from the game's crafting screen (UI 102), shared by dos2_craft and the tools that bring in new items.
// selectRecipe(n) makes the screen show recipe n (name, ingredients with counts, how many can be made); numbers with no
// recipe answer nothing. Recorded from a hand-made Knife On A Stick (2026-10-28). The screen exists once the player has
// pressed K after loading.
import { call } from "./core.js";

export const CRAFT_UI = 102;
export const client = (cmd, args = {}) => call(cmd, args, 15000, "client");

/** Recipe n as the screen shows it, or null if there is no such recipe. */
export async function readRecipe(id) {
  const mark = (await client("ping")).log;
  await client("ui_call", { ui: CRAFT_UI, fn: "selectRecipe", args: [id] });
  // The screen answers with the name, the craftable amount and setStation; only while it is on screen does it also send
  // the five ingredient slots (0-4). Wait for whichever comes last, not a fixed time.
  let es = [];
  for (let i = 0; i < 10; i++) {
    await new Promise((res) => setTimeout(res, 100));
    es = (await client("ui_log", { ui: CRAFT_UI, since: mark, limit: 60 })).entries.filter((e) => e.when !== "After");
    const station = es.some((e) => e.fn === "setStation");
    const slots = es.some((e) => e.fn === "setIngredient");
    if (station && (!slots || es.some((e) => e.fn === "setIngredient" && e.args[0] === 4))) break;
    if (i >= 2 && !es.some((e) => e.fn === "setRecipeResult")) break; // no such recipe
  }
  const name = es.find((e) => e.fn === "setRecipeResult");
  if (!name) return null;
  const max = es.find((e) => e.fn === "setRecipeMaxCraftAmount");
  const ingredients = es.filter((e) => e.fn === "setIngredient" && e.args[2] !== "Select an ingredient")
    .map((e) => `${e.args[2]} (${e.args[3]})`);
  return { id, name: name.args[0], max: max ? Number(max.args[0]) : 0, ingredients };
}

/** Every known recipe, or null when the crafting screen does not exist yet. */
export async function listRecipes() {
  try { await client("ui_call", { ui: CRAFT_UI, fn: "selectRecipe", args: [0] }); } catch { return null; }
  const out = [];
  for (let id = 0, misses = 0; id <= 80 && misses < 5; id++) {
    const r = await readRecipe(id);
    if (!r) { misses++; continue; }
    misses = 0;
    out.push(r);
  }
  return out;
}

/** A short note naming the recipes that can be made right now ("" if none; null if the screen is not available). */
export async function craftableNow() {
  // One recipe first: a closed window answers without ingredients, so stop before reading the rest (about 8 s).
  try {
    const first = await readRecipe(0);
    if (!first || !first.ingredients.length) return null;
  } catch { return null; }
  const all = await listRecipes();
  // With the window closed the screen sends no ingredients and keeps old counts: nothing reliable to say.
  if (all == null || !all.some((r) => r.ingredients.length)) return null;
  const can = all.filter((r) => r.max > 0);
  return can.length ? `\n[Can craft now: ${can.map((r) => `${r.name} x${r.max} (dos2_craft recipe=${r.id})`).join(", ")}]` : "";
}
