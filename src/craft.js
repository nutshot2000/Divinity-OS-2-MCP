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
  await new Promise((res) => setTimeout(res, 150));
  const es = (await client("ui_log", { ui: CRAFT_UI, since: mark, limit: 60 })).entries.filter((e) => e.when !== "After");
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
  const all = await listRecipes();
  if (all == null) return null;
  const can = all.filter((r) => r.max > 0);
  return can.length ? `\n[Can craft now: ${can.map((r) => `${r.name} x${r.max} (dos2_craft recipe=${r.id})`).join(", ")}]` : "";
}
