// Crafting through the game's crafting screen (UI 102), shared by dos2_craft and the tools that bring in new items.
// selectRecipe(n) makes the screen show recipe n (name, ingredients with counts, how many can be made); numbers with no
// recipe answer nothing. craftRecipe(n, amount) is the Combine button (recorded from a hand-made Knife On A Stick,
// 2026-10-28). The screen only recounts and crafts while it is on screen, so the bridge opens it with the story's own
// OpenCraftUI and leaves it open: closing it by script destroyed it until the game was restarted.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { call } from "./core.js";

export const CRAFT_UI = 102;
export const client = (cmd, args = {}) => call(cmd, args, 15000, "client");
const sleep = (ms) => new Promise((res) => setTimeout(res, ms));

// Names of the recipes the character knows, as the crafting screen last listed them (kept for the "can craft now" notes).
const KNOWN = join(tmpdir(), "dos2-bridge-recipes-known.json");
const RECIPES = join(dirname(fileURLToPath(import.meta.url)), "..", "data", "recipes.json");

/** Show the crafting window on its Recipes tab. False if the game has no crafting screen (restart needed). */
export async function openCraft() {
  await call("open_craft");
  await sleep(800);
  try { await client("ui_call", { ui: CRAFT_UI, fn: "setCurrentTab", args: [0] }); } catch { return false; }
  await sleep(300);
  return true;
}

/** Recipe n as the screen shows it, or null if there is no such recipe. */
export async function readRecipe(id) {
  const mark = (await client("ping")).log;
  await client("ui_call", { ui: CRAFT_UI, fn: "selectRecipe", args: [id] });
  // The screen answers with the name, the craftable amount and setStation; while on screen it also sends the five
  // ingredient slots (0-4). Wait for whichever comes last, not a fixed time.
  let es = [];
  for (let i = 0; i < 10; i++) {
    await sleep(100);
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

/** Every known recipe from the open screen (opening it first), or null when there is no crafting screen. */
export async function listRecipes() {
  if (!(await openCraft())) return null;
  const out = [];
  for (let id = 0, misses = 0; id <= 80 && misses < 5; id++) {
    const r = await readRecipe(id);
    if (!r) { misses++; continue; }
    misses = 0;
    out.push(r);
  }
  try { writeFileSync(KNOWN, JSON.stringify([...new Set(out.map((r) => r.name))])); } catch { /* best effort */ }
  return out;
}

/** "[Can craft now: ...]" for known recipes the acting character has every ingredient for, counted from the game's
 *  recipe table without opening any window; "" if none, null if the recipe table or the known list is missing. */
export async function craftableNow() {
  if (!existsSync(RECIPES) || !existsSync(KNOWN)) return null;
  const known = new Set(JSON.parse(readFileSync(KNOWN, "utf8")));
  const all = JSON.parse(readFileSync(RECIPES, "utf8")).filter((c) => !c.station);
  const r = await call("craft_counts", { recipes: all.map((c) => ({ id: c.id, ingredients: c.ingredients, name: c.name, result: c.results[0].stats })) });
  const can = r.makeable.filter((m) => known.has(m.name));
  if (!can.length) return "";
  const names = [...new Map(can.map((m) => [m.name, m])).values()];
  return `\n[Can craft now: ${names.map((m) => `${m.name} x${m.count}`).join(", ")} (dos2_craft lists them by number)]`;
}
