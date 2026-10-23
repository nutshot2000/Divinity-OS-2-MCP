// Windows capture of the game window only (scripts/capture-window.ps1); no desktop-wide capture or input.
import { execFile } from "node:child_process";
import { mkdirSync, readFileSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";

export async function captureScreenshot(maxWidth = 1280) {
  if (process.platform !== "win32") throw new Error("dos2_screenshot supports Windows only.");
  const dir = join(tmpdir(), "dos2-bridge", "screenshots");
  mkdirSync(dir, { recursive: true });
  const path = join(dir, `${Date.now()}-${randomUUID()}.png`);
  const script = fileURLToPath(new URL("../scripts/capture-window.ps1", import.meta.url));
  try {
    const stdout = await new Promise((resolve, reject) => {
      execFile("powershell.exe", ["-NoProfile", "-NonInteractive", "-File", script, "-OutputFile", path, "-MaxWidth", String(maxWidth)],
        { windowsHide: true, timeout: 20000, maxBuffer: 1 << 20 }, (err, out, stderr) => {
          if (err) reject(new Error(`Screenshot failed: ${(stderr || err.message).trim()}`)); else resolve(out);
        });
    });
    const metadata = JSON.parse(stdout.replace(/^﻿/, ""));
    const png = readFileSync(path);
    return { metadata: { ...metadata, path }, image: { type: "image", mimeType: "image/png", data: png.toString("base64") } };
  } catch (e) {
    try { unlinkSync(path); } catch { /* nothing to clean up */ }
    throw e;
  }
}
