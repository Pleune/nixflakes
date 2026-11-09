import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";

const { setupAuthUrlCapture } = await import(pathToFileURL(path.resolve(process.argv[2])));
const root = await mkdtemp(path.join(os.tmpdir(), "pi-browser-capture-"));
const url = "https://example.invalid/non-oauth-test?one=1&two=2";

try {
  const bin = path.join(root, "bin");
  await mkdir(bin);
  const calls = path.join(root, "opener-calls.jsonl");
  const opener = path.join(bin, "xdg-open");
  // Model xdg-open's no-display BROWSER fallback, with a bound so the
  // unpatched implementation fails rather than recursing indefinitely.
  await writeFile(opener, `#!${process.execPath}
const fs = require("node:fs");
const { spawnSync } = require("node:child_process");
const depth = Number(process.env.OPENER_DEPTH || "0");
fs.appendFileSync(process.env.OPENER_CALLS, JSON.stringify({ args: process.argv.slice(2), browser: process.env.BROWSER ?? null }) + "\\n");
if (process.env.BROWSER) {
  if (depth >= 3) process.exit(91);
  const child = spawnSync("sh", [process.env.BROWSER, ...process.argv.slice(2)], {
    env: { ...process.env, OPENER_DEPTH: String(depth + 1) }, timeout: 2000,
  });
  process.exit(child.status ?? 92);
}
`, { mode: 0o755 });

  function runCapture(capture, extra = {}) {
    assert.ok(capture);
    // Invoke sh explicitly: Nix build sandboxes do not provide /usr/bin/env,
    // which is used by the upstream-generated runtime script's shebang.
    const child = spawnSync("sh", [capture.browserEnv.BROWSER, url], {
      env: { ...process.env, ...capture.browserEnv, OPENER_CALLS: calls, ...extra },
      timeout: 5000,
      encoding: "utf8",
    });
    assert.ifError(child.error);
    assert.equal(child.status, 0, child.stderr);
  }

  const discovered = setupAuthUrlCapture(path.join(root, "discovered"), { PATH: bin });
  runCapture(discovered);
  const first = (await readFile(calls, "utf8")).trim().split("\n").map(JSON.parse);
  assert.deepEqual(first, [{ args: [url], browser: null }]);
  assert.equal(await readFile(discovered.file, "utf8"), url + "\n");

  // Respect an explicitly configured real BROWSER without passing the
  // temporary capture wrapper back to it through the environment.
  const explicit = setupAuthUrlCapture(path.join(root, "explicit"), { BROWSER: opener, PATH: "" });
  runCapture(explicit);
  const both = (await readFile(calls, "utf8")).trim().split("\n").map(JSON.parse);
  assert.equal(both.length, 2);
  assert.deepEqual(both[1], { args: [url], browser: null });
  assert.equal(await readFile(explicit.file, "utf8"), url + "\n");

  // Headless/manual-copy login must still capture once and return normally.
  const headless = setupAuthUrlCapture(path.join(root, "headless"), { PATH: "" });
  runCapture(headless);
  assert.equal(await readFile(headless.file, "utf8"), url + "\n");
  console.log("PASS: discovered opener, explicit BROWSER, and manual-copy fallback; no recursive forwarding");
} finally {
  await rm(root, { recursive: true, force: true });
}
