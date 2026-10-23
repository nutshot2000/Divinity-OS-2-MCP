// Tools: help, connection check, raw Lua, screenshot.
import { tool, modTool, call, text, json, z, INSTRUCTIONS } from "../core.js";
import { heartbeat, dataDir } from "../bridge.js";
import { captureScreenshot } from "../screenshot.js";

tool("dos2_help", "The playbook: how to explore and play through this bridge.", {}, () => text(INSTRUCTIONS));

tool("dos2_ping", "Check the connection: where the bridge looks for the game's Osiris Data folder, the mod's last " +
  "heartbeat, and a round trip to the mod.",
  {},
  async () => {
    const beat = heartbeat();
    let round = null;
    try { round = await call("ping", {}, 5000); }
    catch (e) { round = { error: String(e.message || e) }; }
    return text(json({ data_dir: dataDir(), heartbeat: beat, ping: round }));
  });

// Raw Lua can read anything in the game, so it is for debugging the bridge only and off during play.
if (process.env.DOS2_DEV === "1") {
  tool("dos2_lua", "Debug only (DOS2_DEV=1): run Lua in the game's server context; the chunk's return value comes back " +
    "as JSON. Never use it to learn things a player could not see.",
    { code: z.string().min(1) },
    (a) => modTool("lua", a));
}

tool("dos2_screenshot", "Capture the game window as an image. Costly: use dos2_look and dos2_grid first and take a " +
  "picture only to check something they cannot show.",
  { max_width: z.number().int().min(640).max(2560).optional().describe("Default 1280") },
  async (a) => {
    const { metadata, image } = await captureScreenshot(a.max_width ?? 1280);
    return { content: [{ type: "text", text: json(metadata) }, image] };
  });

tool("dos2_camera", "Move the game camera for the watcher: point it at a visible character or item (target) or at " +
  "explored ground (x,z), zoom (metres, the game allows up to about 19), set rotation (degrees) or turn (degrees, " +
  "relative). reset=true points it back at your character. It follows your character again once they move.",
  {
    target: z.string().optional(), x: z.number().optional(), z: z.number().optional(),
    zoom: z.number().min(3).max(30).optional(), rotation: z.number().optional(), turn: z.number().optional(),
    reset: z.boolean().optional(),
  },
  async (a) => {
    const point = a.target != null || (a.x != null && a.z != null) || a.reset
      ? await call("camera_point", a.reset ? {} : { target: a.target, x: a.x, z: a.z }) : {};
    const r = await call("camera", { ...point, zoom: a.zoom, rotation: a.rotation, turn: a.turn }, 15000, "client");
    return text(`Camera looking at ${r.look_at.map((v) => Math.round(v * 10) / 10).join(",")}, zoom ${r.zoom}m, rotation ${Math.round(r.rotation)}.`);
  });
