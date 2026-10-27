// Tools: dialogue. The client half of the mod snapshots what the dialogue screen is given (lines and answers) at the
// moment it is drawn; answering makes the same QuestionPressed call a click on an answer makes.
import { readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { tool, call, text, z, guid } from "../core.js";
import { walkTo } from "./move.js";
import { focusBetween, wide, CLOSE, caption } from "../director.js";
import { markTalked } from "../done.js";

const DIALOG_UI = 14;
const client = (cmd, args = {}) => call(cmd, args, 15000, "client");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const plain = (s) => String(s ?? "").replace(/<[^>]*>/g, "").replace(/&quot;/g, '"').replace(/&amp;/g, "&").trim();

// Dialogue log position already shown to the agent. Kept in a temp file too, so one-shot CLI calls
// (scripts/call.mjs starts a fresh server each time) do not repeat old lines.
const MARK = join(tmpdir(), "dos2-bridge-dialog-mark.txt");
let readUpTo = (() => { try { return Number(readFileSync(MARK, "utf8")) || 0; } catch { return 0; } })();
const saveMark = () => { try { writeFileSync(MARK, String(readUpTo)); } catch { /* best effort */ } };

/** Lines and answers from snapshots: text groups of 4 (speaker, ?, line, ?), answers groups of 3 (holder, text, ?). */
function parse(snapshots) {
  const lines = [];
  let answers = [];
  for (const s of snapshots) {
    for (let i = 0; i + 2 < s.text.length; i += 4) lines.push({ speaker: plain(s.text[i]), line: plain(s.text[i + 2]) });
    const kw = [];
    for (let i = 0; i + 1 < s.keywords.length; i += 3) kw.push(plain(s.keywords[i + 1]));
    if (kw.length) answers = kw;
  }
  return { lines, answers };
}

async function readDialog() {
  const r = await client("dialog_log", { since: readUpTo });
  const { lines, answers } = parse(r.snapshots);
  // The client's log restarts at 0 after a game restart: never wait for a position it will not reach.
  readUpTo = r.last < readUpTo - 1 ? 0 : r.last + 1;
  saveMark();
  return { open: r.open, lines, answers };
}

function show(d) {
  if (!d.open && !d.lines.length) return "No dialogue open.";
  // Lines without a speaker are game notes, e.g. "Attitude Odasto +2".
  return d.lines.map((l) => l.speaker ? `${l.speaker}: ${l.line}` : `[${l.line.replace(/^:\s*/, "")}]`).join("\n") +
    (d.open ? `\n\nanswers:\n${d.answers.map((a, i) => `  ${i}. ${a}`).join("\n") || "  (none yet)"}` : "\n\n(dialogue ended)");
}

/** Wait for the screen to update after an action, then read it. The next line can take a few seconds (voice,
 *  animation), so keep checking until new lines arrive or the dialogue closes. */
async function settle() {
  await sleep(1200);
  let d = await readDialog();
  for (let i = 0; i < 6 && d.open && !d.lines.length && !d.answers.length; i++) {
    await sleep(700);
    const more = await readDialog();
    d = { open: more.open, lines: more.lines, answers: more.answers };
  }
  return d;
}

tool("dos2_dialog", "Read the open dialogue: lines spoken since the last read and the numbered answers you can give.",
  {}, async () => {
    let d = await readDialog();
    // Read right after a conversation starts, the screen often has nothing yet: give it a moment.
    if (d.open && !d.lines.length && !d.answers.length) d = await settle();
    return text(show(d));
  });

const onlyContinue = (d) => d.open && d.answers.length === 1 && /^\(continue\)$/i.test(d.answers[0]);

tool("dos2_answer", "Choose a dialogue answer by its number from dos2_dialog. Read all answers and pick the one that " +
  "fits your character - do not default to 0. Lines with nothing to choose but " +
  "(continue) are stepped through automatically (each still shows in game for a moment). Returns what is said and " +
  "the next real choice.",
  { answer: z.number().int().min(0), auto_continue: z.boolean().optional().describe("Default true") },
  async (a) => {
    // Show which answer is being given, in the player's words, over the character.
    try {
      // The answers on screen are in the latest snapshots, which were already read: look back a few, not the whole log.
      const { answers } = parse((await client("dialog_log", { since: Math.max(0, readUpTo - 60) })).snapshots);
      if (answers[a.answer]) await caption(`"${answers[a.answer].slice(0, 90)}"`);
    } catch { /* cosmetic */ }
    await client("ui_call", { ui: DIALOG_UI, fn: "QuestionPressed", args: [a.answer] });
    let d = await settle();
    const all = { ...d, lines: [...d.lines] };
    for (let i = 0; i < 15 && (a.auto_continue ?? true) && onlyContinue(d); i++) {
      await sleep(1500); // let the line be read on screen before moving on
      await client("ui_call", { ui: DIALOG_UI, fn: "QuestionPressed", args: [0] });
      d = await settle();
      all.lines.push(...d.lines);
      all.open = d.open;
      all.answers = d.answers;
    }
    if (!all.open) await wide(); // conversation over: back to the exploring view
    // Choosing "(end)" closes the dialogue with nothing more said.
    if (!all.open && !all.lines.length) return text("The conversation is over.");
    return text(show(all));
  });

/** A message box is built from invokes: text via setPopupType/showPopup/setText-style calls, buttons via
 *  addButton/addYesButton/addNoButton/addBlueButton(id, label). Pull out whatever strings and buttons they carry. */
function parseMsgBox(calls) {
  const texts = [], buttons = [];
  for (const c of calls) {
    if (/^add(Yes|No|Blue)?Button$/.test(c.fn)) {
      const id = c.args.find((a) => typeof a === "number");
      const label = c.args.find((a) => typeof a === "string");
      buttons.push({ id, label: plain(label ?? (c.fn.replace(/^add|Button$/g, "") || "OK")) });
    } else {
      for (const a of c.args) if (typeof a === "string" && a.trim() && !/^[\d.]+$/.test(a)) texts.push(plain(a));
    }
  }
  return { texts: [...new Set(texts)], buttons };
}

tool("dos2_msgbox", "Read the open message box (yes/no prompts such as 'Are you sure you want to leave?') and its " +
  "buttons. Pass button=<id> to press one. The character cannot act until it is answered.",
  { button: z.number().int().optional() },
  async (a) => {
    if (a.button != null) {
      await client("msgbox_press", { id: a.button });
      return text(`Pressed button ${a.button}.`);
    }
    const r = await client("msgbox");
    if (!r.open) return text("No message box open.");
    const m = parseMsgBox(r.calls);
    return text(`${m.texts.join("\n") || "(no text)"}\n\nbuttons:\n` +
      (m.buttons.map((b) => `  ${b.id}. ${b.label}`).join("\n") || "  (none found; raw calls: " + JSON.stringify(r.calls).slice(0, 400) + ")"));
  });

tool("dos2_talk", "Walk up to a character and start talking, as clicking on them would. Returns the opening lines " +
  "and answers.",
  { target: guid },
  async (a) => {
    await readDialog(); // drop anything older
    const m = await walkTo({ target: a.target });
    if (m.refused || m.hurt) return text(`Did not reach them: ${m.outcome}`);
    await focusBetween(a.target, CLOSE); // close-up on both speakers
    const r = await call("talk", { target: a.target });
    markTalked(a.target);
    await caption(`Talking to ${r.talking_to}`);
    const d = await settle();
    if (!d.open && !d.lines.length) await wide();
    if (!d.open && !d.lines.length) return text(`${r.talking_to} did not start a conversation (nothing to say, or busy).`);
    return text(show(d));
  });
