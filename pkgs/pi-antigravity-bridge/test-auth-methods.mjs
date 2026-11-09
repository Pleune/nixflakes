// Offline ACP authentication regression. All state is disposable fixture data;
// the fake server never opens a browser or makes a network/model request.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { spawn } from "node:child_process";
import { registerHooks } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";

if (process.argv[2] === "--fake-descendant") {
  process.on("SIGTERM", () => setTimeout(() => {
    const file = path.join(process.env.ACP_TEST_DIR, "settings.json");
    const settings = JSON.parse(fs.readFileSync(file, "utf8"));
    settings.auth.type = "oauth-business";
    fs.writeFileSync(file, JSON.stringify(settings));
    fs.appendFileSync(process.env.ACP_TEST_LOG, '{"descendantLateWrite":true}\n');
    process.exit(0);
  }, 150));
  fs.appendFileSync(process.env.ACP_TEST_LOG, '{"descendantReady":true}\n');
  setTimeout(() => process.exit(0), 3000); // Bound fixture lifetime even on failure.
} else if (process.argv[2] === "--fake-server") {
  const dir = process.env.ACP_TEST_DIR;
  const settingsFile = path.join(dir, "settings.json");
  const readSettings = () => JSON.parse(fs.readFileSync(settingsFile, "utf8"));
  const log = (message) => fs.appendFileSync(process.env.ACP_TEST_LOG, JSON.stringify(message) + "\n");
  const reply = (id, result) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
  const fail = (id) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32000, message: "fixture: no usable license/credentials" } }) + "\n");
  const scenario = process.env.ACP_TEST_SCENARIO || "normal";
  const tokenName = (method) => method === "oauth-business" ? "acp_business_token.json" : "acp_token.json";
  let method = readSettings().auth?.type;
  log({ startup: method });
  if (scenario === "descendant-timeout") {
    spawn(process.execPath, [fileURLToPath(import.meta.url), "--fake-descendant"], { stdio: "ignore" });
    process.on("SIGTERM", () => process.exit(0));
  }
  if (["late-timeout", "hard-timeout", "driver-race"].includes(scenario)) {
    process.on("SIGTERM", () => {
      log({ term: scenario });
      if (scenario === "hard-timeout") return; // Exercise forced termination.
      setTimeout(() => {
        const settings = readSettings();
        settings.auth = { ...settings.auth, type: method };
        fs.writeFileSync(settingsFile, JSON.stringify(settings));
        log({ lateWrite: method });
        process.exit(0);
      }, 150);
    });
  }
  readline.createInterface({ input: process.stdin }).on("line", (line) => {
    const request = JSON.parse(line);
    log(request);
    const { id } = request;
    switch (request.method) {
      case "initialize":
        reply(id, { protocolVersion: 1, agentInfo: { name: "offline-auth-fixture", version: "1" }, agentCapabilities: scenario === "logout-unsupported" ? {} : { auth: { logout: {} } }, authMethods: [{ id: "oauth-personal" }, { id: "oauth-business" }] });
        break;
      case "logout": {
        if (scenario === "logout-reject") { fail(id); break; }
        // Official ACP logout selects its flavor from startup auth.type and
        // clears both token and keychain backends. Unknown means BOTH (unsafe).
        assert.ok(["oauth-personal", "oauth-business"].includes(method));
        log({ logoutMethod: method });
        fs.rmSync(path.join(dir, tokenName(method)), { force: true });
        fs.rmSync(path.join(dir, `keychain-${method}`), { force: true });
        const settings = readSettings();
        delete settings.auth.type;
        fs.writeFileSync(settingsFile, JSON.stringify(settings));
        reply(id, {});
        break;
      }
      case "authenticate": {
        if (scenario === "reject") {
          // ACP 1.2.1 fails license/onboarding before assigning its new
          // _auth_state, then clears the startup method's credentials.
          // If the bridge leaves the OLD method selected, this deletes it.
          log({ cleanup: method });
          fs.rmSync(path.join(dir, tokenName(method)), { force: true });
          fail(id);
          break;
        }
        method = request.params.methodId;
        assert.ok(["oauth-personal", "oauth-business"].includes(method));
        if (["late-timeout", "hard-timeout", "descendant-timeout"].includes(scenario)) break;
        const settings = readSettings();
        if (scenario !== "no-persist") {
          settings.auth = { ...settings.auth, type: method };
          // Model business login's license/project persistence. Rollback must
          // restore only auth.type, not overwrite a newly selected license.
          if (method === "oauth-business") settings.gcp = { project: "fixture-license", location: "us" };
          fs.writeFileSync(settingsFile, JSON.stringify(settings));
        }
        if (!["hollow", "keychain"].includes(scenario)) {
          fs.writeFileSync(path.join(dir, tokenName(method)), "dummy matching-method token fixture");
        }
        reply(id, {});
        break;
      }
      case "session/prompt":
        if (scenario !== "driver-race") reply(id, { stopReason: "end_turn" });
        break;
      case "session/new":
        if (scenario === "hollow" || (scenario !== "keychain" && !fs.existsSync(path.join(dir, tokenName(method))))) fail(id);
        else reply(id, { sessionId: "fixture-session", configOptions: [] });
        break;
      default:
        reply(id, {});
    }
  });
} else {
  // Upstream uses .js specifiers for source .ts files. Resolve those local
  // specifiers to TS for Node's native type stripping; no second Pi runtime.
  registerHooks({
    resolve(specifier, context, next) {
      if (specifier.startsWith(".") && specifier.endsWith(".js") && context.parentURL) {
        const ts = new URL(specifier.slice(0, -3) + ".ts", context.parentURL);
        if (fs.existsSync(ts)) return next(ts.href, context);
      }
      return next(specifier, context);
    },
  });
  const source = path.resolve(process.argv[2]);
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "pi-acp-methods-"));
  const savedEnv = { HOME: process.env.HOME, GEMINI_HOME: process.env.GEMINI_HOME, AGY_ACP_BIN: process.env.AGY_ACP_BIN };
  delete process.env.AGY_ACP_BIN; // Driver resolution must never reach an inherited real server.
  process.env.HOME = root;
  process.env.GEMINI_HOME = path.join(root, "gemini-home");
  const load = (file) => import(pathToFileURL(path.join(source, file)));
  try {
    const setup = await load("src/acp/setup.ts");
    const { runAcpAuth } = await load("src/acp/auth.ts");
    const { runAcpAuthCommand } = await load("src/acp/auth-command.ts");
    const { clearConflictingPiAuth } = await load("src/acp/pi-auth-reset.ts");
    const { AcpConnection, setAuthInvalidatedHook } = await load("src/acp/connection.ts");
    const { AcpDriver } = await load("src/acp/driver.ts");
    const labels = ["Personal (Antigravity subscription)", "Gemini Enterprise (licensed business account)"];
    const names = { "oauth-personal": "acp_token.json", "oauth-business": "acp_business_token.json" };
    let counter = 0;
    function fixture(type = "oauth-personal", scenario = "normal") {
      const cwd = path.join(root, `case-${++counter}`);
      const dir = path.join(cwd, "antigravity-acp");
      fs.mkdirSync(dir, { recursive: true });
      const file = path.join(dir, "settings.json");
      fs.writeFileSync(file, JSON.stringify({ auth: { type, keep: "auth-metadata" }, gcp: { project: "original-project", location: "eu" }, custom: { keep: true } }));
      const log = path.join(cwd, "requests.jsonl");
      const verified = path.join(cwd, "verified.json");
      const extraEnv = { GEMINI_HOME: cwd, ACP_TEST_DIR: dir, ACP_TEST_LOG: log, ACP_TEST_SCENARIO: scenario };
      const auth = { bin: process.execPath, binArgs: [fileURLToPath(import.meta.url), "--fake-server"], cwd, extraEnv, tokenDir: dir, authVerifiedFile: verified, tokenGraceMs: 0, timeoutMs: 2000 };
      const ready = () => setup.ensureAcpReady({ env: { ...process.env, AGY_ACP_BIN: process.execPath, GEMINI_HOME: cwd }, authVerifiedFile: verified, install: false });
      const read = () => JSON.parse(fs.readFileSync(file, "utf8"));
      const requests = () => fs.readFileSync(log, "utf8").trim().split("\n").map(JSON.parse);
      const token = (method) => fs.writeFileSync(path.join(dir, names[method]), `existing ${method} fixture`);
      return { cwd, dir, file, log, verified, auth, ready, read, requests, token };
    }

    // Both choices must reach authenticate even for an already healthy login.
    for (const [index, method] of ["oauth-personal", "oauth-business"].entries()) {
      const previous = method === "oauth-personal" ? "oauth-business" : "oauth-personal";
      const f = fixture(previous);
      f.token(previous);
      assert.equal((await f.ready()).needsLogin, false);
      const previousToken = fs.readFileSync(path.join(f.dir, names[previous]), "utf8");
      const notices = [];
      let result;
      await runAcpAuthCommand({
        select: async (_title, options) => { assert.deepEqual(options, labels); return options[index]; },
        confirm: async () => true,
        notify: (message) => notices.push(message),
      }, {
        setup: { configBin: process.execPath, env: { AGY_ACP_BIN: process.execPath, GEMINI_HOME: f.cwd }, authVerifiedFile: f.verified, install: false },
        auth: f.auth,
        onResult: (r) => { result = r; },
      });
      assert.equal(result?.ok, true);
      assert.deepEqual(f.requests().filter((r) => r.method === "authenticate").map((r) => r.params), [{ methodId: method }]);
      assert.equal(f.requests()[0].startup, method, "select the attempted method before spawn, including failed flows");
      assert.equal(f.read().auth.type, method);
      assert.equal(f.read().auth.keep, "auth-metadata");
      assert.deepEqual(f.read().custom, { keep: true });
      assert.equal(fs.readFileSync(path.join(f.dir, names[previous]), "utf8"), previousToken);
      assert.equal(setup.readAcpAuthVerified(f.verified, method), true);
      assert.equal(setup.readAcpAuthVerified(f.verified, previous), false);
      assert.equal((await f.ready()).needsLogin, false);
      assert.ok(notices.some((m) => /Restart pi or \/reload/.test(m)));
      if (method === "oauth-business") assert.deepEqual(f.read().gcp, { project: "fixture-license", location: "us" });
      else assert.deepEqual(f.read().gcp, { project: "original-project", location: "eu" });

      // A new driver process reads the chosen setting and cached matching token,
      // starts a session without authenticate, and makes no prompt/model call.
      const conn = new AcpConnection({ bin: f.auth.bin, binArgs: f.auth.binArgs, cwd: f.cwd, extraEnv: f.auth.extraEnv, log: () => {}, onUpdate: () => {}, onExit: () => {} });
      const before = f.requests().length;
      try { await conn.start(); await conn.newSession(f.cwd); }
      finally { await conn.killAndWait(); }
      const restarted = f.requests().slice(before);
      assert.equal(restarted[0].startup, method);
      assert.ok(restarted.some((r) => r.method === "session/new"));
      assert.ok(!restarted.some((r) => r.method === "authenticate" || r.method === "session/prompt"));
    }
    console.log("PASS: both chooser options, signed-in method switches, settings/credentials preserved, and restart without reauth");

    // Cancellation must precede even setup (no settings/markers/server writes).
    for (const healthy of [false, true]) {
      const f = fixture();
      if (healthy) f.token("oauth-personal");
      const before = fs.readFileSync(f.file, "utf8");
      let setupCalled = false;
      await runAcpAuthCommand({ select: async () => undefined, notify: () => {} }, {
        setup: { configBin: "/must-not-run", geminiDir: f.dir, install: false },
        onSetup: () => { setupCalled = true; },
        auth: f.auth,
      });
      assert.equal(setupCalled, false);
      assert.equal(fs.readFileSync(f.file, "utf8"), before);
      assert.equal(fs.existsSync(f.log), false);
      assert.equal(fs.existsSync(f.verified), false);
    }
    const declined = fixture();
    declined.token("oauth-personal");
    const declinedSettings = fs.readFileSync(declined.file, "utf8");
    await runAcpAuthCommand({ select: async () => labels[0], confirm: async () => false, notify: () => {} }, {
      setup: { configBin: "/must-not-run", geminiDir: declined.dir, install: false }, auth: declined.auth,
      onSetup: () => assert.fail("confirmation cancellation ran setup"),
    });
    assert.equal(fs.readFileSync(declined.file, "utf8"), declinedSettings);
    assert.equal(fs.existsSync(declined.log), false);
    assert.equal(fs.readFileSync(path.join(declined.dir, names["oauth-personal"]), "utf8"), "existing oauth-personal fixture");
    console.log("PASS: method/confirmation cancellation is side-effect free on fresh and healthy logins");

    for (const method of ["oauth-personal", "oauth-business"]) {
      const other = method === "oauth-personal" ? "oauth-business" : "oauth-personal";
      for (const scenario of ["normal", "reject", "logout-unsupported", "logout-reject"]) {
        const f = fixture(method, scenario);
        f.token(method); f.token(other);
        const keychain = path.join(f.dir, `keychain-${method}`);
        const otherKeychain = path.join(f.dir, `keychain-${other}`);
        fs.writeFileSync(keychain, "dummy selected keychain");
        fs.writeFileSync(otherKeychain, "dummy other keychain");
        setup.writeAcpAuthVerified(f.verified, method);
        const authPath = path.join(f.cwd, "pi-auth.json");
        const unrelated = { type: "api_key", key: "dummy-unrelated" };
        fs.writeFileSync(authPath, JSON.stringify({ antigravity: { type: "oauth", access: "dummy", refresh: "dummy", expires: 0 }, unrelated }));
        const events = [];
        const result = await runAcpAuth({ ...f.auth, methodId: method, resetCredentials: true,
          beforeStart: async () => { events.push("driver-stopped"); },
          beforeCredentialReset: async () => {
            assert.deepEqual(events, ["driver-stopped"]);
            await clearConflictingPiAuth(async () => ({ logout: async (id) => {
              assert.equal(id, "antigravity");
              const records = JSON.parse(fs.readFileSync(authPath, "utf8")); delete records[id];
              fs.writeFileSync(authPath, JSON.stringify(records));
            } }));
            events.push("pi-cleaned");
          },
        });
        assert.equal(fs.readFileSync(path.join(f.dir, names[other]), "utf8"), `existing ${other} fixture`);
        assert.equal(fs.readFileSync(otherKeychain, "utf8"), "dummy other keychain");
        assert.equal(f.read().auth.type, method);
        assert.deepEqual(f.read().custom, { keep: true });
        assert.equal(f.requests()[0].startup, method);
        const authRequests = f.requests().filter((r) => r.method === "authenticate");
        const logoutRequests = f.requests().filter((r) => r.method === "logout");
        if (scenario === "logout-unsupported") {
          assert.equal(result.ok, false); assert.match(result.error, /does not advertise/);
          assert.equal(logoutRequests.length, 0); assert.equal(authRequests.length, 0);
          assert.deepEqual(events, ["driver-stopped"]);
          assert.ok(JSON.parse(fs.readFileSync(authPath, "utf8")).antigravity);
          assert.equal(setup.readAcpAuthVerified(f.verified, method), true);
          assert.equal(fs.readFileSync(keychain, "utf8"), "dummy selected keychain");
        } else {
          assert.deepEqual(JSON.parse(fs.readFileSync(authPath, "utf8")), { unrelated });
          assert.equal(logoutRequests.length, 1);
          assert.equal(result.credentialsReset, true);
          if (scenario === "logout-reject") { assert.equal(result.ok, false); assert.equal(authRequests.length, 0); }
          else {
            assert.equal(f.requests().find((r) => r.logoutMethod)?.logoutMethod, method);
            assert.equal(fs.existsSync(keychain), false);
            assert.equal(authRequests.length, 1);
            assert.ok(f.requests().findIndex((r) => r.method === "logout") < f.requests().findIndex((r) => r.method === "authenticate"));
            assert.equal(result.ok, scenario === "normal");
            if (scenario === "reject") {
              assert.match(result.error, /cannot be restored/);
              assert.equal(fs.existsSync(path.join(f.dir, names[method])), false);
              assert.equal(setup.readAcpAuthVerified(f.verified, method), false);
              assert.equal((await f.ready()).needsLogin, true);
            } else assert.notEqual(fs.readFileSync(path.join(f.dir, names[method]), "utf8"), `existing ${method} fixture`);
          }
        }
      }
    }
    const partial = fixture(); partial.token("oauth-personal");
    const partialAuth = path.join(partial.cwd, "pi-auth.json");
    fs.writeFileSync(partialAuth, JSON.stringify({ antigravity: { type: "oauth", access: "dummy", refresh: "dummy", expires: 0 }, unrelated: { type: "api_key", key: "dummy-other" } }));
    const partialResult = await runAcpAuth({ ...partial.auth, resetCredentials: true, beforeCredentialReset: async () => {
      await clearConflictingPiAuth(async () => ({ logout: async (id) => {
        const records = JSON.parse(fs.readFileSync(partialAuth, "utf8")); delete records[id];
        fs.writeFileSync(partialAuth, JSON.stringify(records));
      } }));
      throw new Error("fixture: cleanup committed but registry synchronization failed");
    } });
    assert.deepEqual(JSON.parse(fs.readFileSync(partialAuth, "utf8")), { unrelated: { type: "api_key", key: "dummy-other" } });
    assert.equal(partialResult.ok, false); assert.equal(partialResult.credentialsReset, true);
    assert.match(partialResult.error, /cannot be restored/);
    assert.ok(!partial.requests().some((r) => ["logout", "authenticate"].includes(r.method)));
    assert.equal(fs.readFileSync(path.join(partial.dir, names["oauth-personal"]), "utf8"), "existing oauth-personal fixture");
    for (const method of ["oauth-personal", "oauth-business"]) {
      const other = method === "oauth-personal" ? "oauth-business" : "oauth-personal";
      const f = fixture(other); f.token(other); f.token(method);
      const tildeHome = "~/" + path.relative(root, f.cwd);
      assert.equal(setup.acpGeminiDir({ HOME: root, GEMINI_HOME: tildeHome }), f.dir);
      assert.equal((await runAcpAuth({ ...f.auth, tokenDir: undefined, extraEnv: { ...f.auth.extraEnv, GEMINI_HOME: tildeHome }, methodId: method, resetCredentials: true })).ok, true);
      assert.equal(f.requests()[0].startup, method);
      assert.equal(f.requests().find((r) => r.logoutMethod)?.logoutMethod, method);
      assert.equal(fs.readFileSync(path.join(f.dir, names[other]), "utf8"), `existing ${other} fixture`);
    }
    assert.throws(() => setup.acpGeminiDir({ HOME: root, GEMINI_HOME: "~other/gemini" }), /unsupported/);
    assert.equal(setup.acpGeminiDir({ HOME: root, GEMINI_HOME: "relative" }, root), path.join(root, "relative", "antigravity-acp"));
    console.log("PASS: confirmed scoped logout/reset, capability gating, partial-cleanup warnings, tilde alignment and opposite-login isolation");

    for (const method of ["oauth-personal", "oauth-business"]) {
      const previous = method === "oauth-personal" ? "oauth-business" : "oauth-personal";
      for (const scenario of ["reject", "hollow", "late-timeout", "hard-timeout", "descendant-timeout"]) {
        for (const previousEvidence of ["token", "keychain"]) {
          const f = fixture(previous, scenario);
          if (previousEvidence === "token") f.token(previous);
          setup.writeAcpAuthVerified(f.verified, previous);
          const marker = fs.readFileSync(f.verified, "utf8");
          // Mirror production's global runtime hook. An explicit auth
          // connection must override it with a method-scoped invalidation.
          setAuthInvalidatedHook(() => setup.clearAcpAuthVerified(f.verified));
          let result;
          try {
            result = await runAcpAuth({ ...f.auth, methodId: method, timeoutMs: scenario === "descendant-timeout" ? 400 : scenario.endsWith("timeout") ? 100 : 2000 });
          } finally { setAuthInvalidatedHook(null); }
          if (scenario === "descendant-timeout") {
            await new Promise((resolve) => setTimeout(resolve, 300));
            assert.ok(f.requests().some((r) => r.descendantReady));
            assert.ok(!f.requests().some((r) => r.descendantLateWrite), "wrapper descendants must not write after leader exit/rollback");
          }
          assert.equal(result.ok, false, `${method}: ${scenario}: ${previousEvidence}`);
          assert.equal(f.read().auth.type, previous);
          assert.deepEqual(f.read().custom, { keep: true });
          assert.equal(f.read().auth.keep, "auth-metadata");
          assert.equal(fs.readFileSync(f.verified, "utf8"), marker);
          assert.equal(fs.existsSync(path.join(f.dir, names[method])), false);
          assert.equal((await f.ready()).needsLogin, false);
          if (previousEvidence === "token") assert.equal(fs.readFileSync(path.join(f.dir, names[previous]), "utf8"), `existing ${previous} fixture`);
          if (scenario === "reject") assert.equal(f.requests().find((r) => r.cleanup).cleanup, method, "failed login may clear only the attempted method's credentials");
          if (scenario === "hollow") assert.match(result.error, /no usable credentials/);
          if (scenario === "late-timeout") assert.equal(f.requests().find((r) => r.lateWrite)?.lateWrite, method, "wait for late server writes before restoring settings");
          if (scenario === "hard-timeout") assert.equal(f.requests().find((r) => r.term)?.term, scenario);
        }
      }
      // Readiness and verification never borrow the other method's evidence.
      const f = fixture(method);
      f.token(previous);
      setup.writeAcpAuthVerified(f.verified, previous);
      assert.equal((await f.ready()).needsLogin, true);
      assert.equal(setup.hasAcpToken(f.dir, method), false);
      setup.writeAcpAuthVerified(f.verified, method);
      assert.equal((await f.ready()).needsLogin, false);
      assert.match(setup.inspectAcpSetup({ configBin: process.execPath, geminiDir: f.dir, authVerifiedFile: f.verified }).auth, /verified, no token file/);
    }
    // Closing a turn releases the run queue. A new connection can replace the
    // old one during its delayed exit; the close continuation must not orphan it.
    const race = fixture("oauth-personal", "driver-race"); race.token("oauth-personal");
    const driverLog = [];
    const driver = new AcpDriver({ bin: race.auth.bin, binArgs: race.auth.binArgs, extraEnv: race.auth.extraEnv, log: (msg, data) => driverLog.push({ msg, data }) });
    const turnRequest = { cwd: race.cwd, model: "gemini-3-8-flash", effort: "low", mode: "accept-edits", prompt: "dummy offline turn" };
    const until = async (condition) => {
      const deadline = Date.now() + 4000;
      while (!condition()) { assert.ok(Date.now() < deadline, "fixture progress timed out: " + JSON.stringify(driverLog)); await new Promise((resolve) => setTimeout(resolve, 10)); }
    };
    try {
      await driver.run(turnRequest);
      await until(() => fs.existsSync(race.log) && race.requests().some((r) => r.method === "session/prompt"));
      const queued = driver.run(turnRequest);
      const closing = driver.close("recycle", "fixture race");
      await queued;
      await until(() => race.requests().filter((r) => r.method === "session/prompt").length === 2);
      const replacementPid = driver.snapshot().pid;
      assert.ok(replacementPid);
      await closing;
      assert.equal(driver.snapshot().pid, replacementPid, "close must retain the queued replacement connection");
      await driver.close("recycle", "fixture done");
      assert.throws(() => process.kill(replacementPid, 0), /ESRCH/);
    } finally { await driver.close("shutdown", "fixture cleanup"); }
    // A failure of the SAME method must still invalidate its own marker.
    const same = fixture("oauth-personal", "reject");
    setup.writeAcpAuthVerified(same.verified, "oauth-personal");
    assert.equal((await runAcpAuth({ ...same.auth, methodId: "oauth-personal" })).ok, false);
    assert.equal(fs.existsSync(same.verified), false);

    // Ordinary driver connections continue to use production's global hook.
    const runtime = fixture();
    setup.writeAcpAuthVerified(runtime.verified, "oauth-personal");
    setAuthInvalidatedHook(() => setup.clearAcpAuthVerified(runtime.verified));
    const conn = new AcpConnection({ bin: runtime.auth.bin, binArgs: runtime.auth.binArgs, cwd: runtime.cwd, extraEnv: runtime.auth.extraEnv, log: () => {}, onUpdate: () => {}, onExit: () => {} });
    try {
      await conn.start();
      await assert.rejects(conn.newSession(runtime.cwd), /authentication required/);
      assert.equal(fs.existsSync(runtime.verified), false);
    } finally { await conn.killAndWait(); setAuthInvalidatedHook(null); }
    console.log("PASS: real-server credential cleanup, production marker hook, delayed writes and forced termination preserve previous logins; runtime invalidation remains active");

    for (const previous of [undefined, "gemini-api-key", "agent-platform"]) {
      for (const failure of ["reject", "spawn"]) {
        const f = fixture(previous, "reject");
        if (previous === undefined) {
          const settings = f.read();
          delete settings.auth.type;
          fs.writeFileSync(f.file, JSON.stringify(settings));
        }
        const result = await runAcpAuth({ ...f.auth, methodId: "oauth-business", ...(failure === "spawn" ? { bin: path.join(f.cwd, "missing-fixture-executable") } : {}) });
        assert.equal(result.ok, false);
        assert.equal(f.read().auth.type, previous);
        assert.equal(f.read().auth.keep, "auth-metadata");
        assert.deepEqual(f.read().custom, { keep: true });
      }
    }
    const concurrent = fixture("oauth-personal", "late-timeout");
    const active = runAcpAuth({ ...concurrent.auth, methodId: "oauth-business", timeoutMs: 100 });
    await Promise.resolve(); // Let the beforeStart barrier complete.
    assert.equal(concurrent.read().auth.type, "oauth-business");
    assert.match((await runAcpAuth({ ...concurrent.auth, methodId: "oauth-personal" })).error, /already running/);
    assert.equal(concurrent.read().auth.type, "oauth-business");
    assert.equal((await active).ok, false);
    assert.equal(concurrent.read().auth.type, "oauth-personal");
    console.log("PASS: unconfigured/non-OAuth selections, spawn failure rollback, and concurrent sign-in isolation");

    // Legacy marker compatibility applies only to its original personal flow.
    const legacy = fixture();
    fs.writeFileSync(legacy.verified, '{"verified":true}');
    assert.equal(setup.readAcpAuthVerified(legacy.verified, "oauth-personal"), true);
    assert.equal(setup.readAcpAuthVerified(legacy.verified, "oauth-business"), false);

    for (const method of ["oauth-personal", "oauth-business"]) {
      const f = fixture(method, "keychain");
      // Omit both tokenDir and methodId: use GEMINI_HOME + persisted selection,
      // and verify a server/keychain login without any local token file.
      const result = await runAcpAuth({ ...f.auth, tokenDir: undefined });
      assert.equal(result.ok, true);
      assert.ok(result.note);
      assert.equal(fs.existsSync(path.join(f.dir, names[method])), false);
      assert.equal(setup.readAcpAuthVerified(f.verified, method), true);
      assert.equal(f.requests().find((r) => r.method === "authenticate").params.methodId, method);
    }
    const oldServer = fixture("oauth-personal", "no-persist");
    assert.equal((await runAcpAuth({ ...oldServer.auth, methodId: "oauth-business" })).ok, true);
    assert.equal(oldServer.read().auth.type, "oauth-business");
    const inferred = fixture();
    fs.unlinkSync(inferred.file);
    inferred.token("oauth-business");
    // A cached business token alone must not silently change the default;
    // the server chooses its runtime method from settings, not token names.
    assert.equal(setup.readAuthState(inferred.dir).configured, false);
    console.log("PASS: legacy personal markers, keychain/session verification, GEMINI_HOME, configured defaults, and older-server persistence");
  } finally {
    for (const [key, value] of Object.entries(savedEnv)) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
    fs.rmSync(root, { recursive: true, force: true });
  }
}
