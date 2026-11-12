#!/usr/bin/env python3
"""Measure Strata's machine-dependent engine settings for one packaged config.json.

setup.py runs tools/calibrate.py when it installs a model ("Tuning Strata for this PC ... roughly
15-30 minutes (3 rounds of each value)"), saves what it measured under a key of this PC's hardware
(setup.py's calibration record), and writes the settings into the config it just emitted.  The
Nix package installs without setup.py, so nothing is measured: the defaults that ship are the
values measured on the machine they were developed on (setup.py names a Ryzen 5 7600 + RTX 5070 on
PCIe 5), and --pcie-frac, --spec-min-p, --pool-workers, --adapt-every/--adapt-swaps/--adapt-decay
and --prefill-pipe all depend on the card, the PCIe link and the CPU rather than on the model.
That is why the same model runs measurably slower on another PC with the defaults.

This script runs that same calibration against one config file, keeps the result beside it
(tune.json), and replays the saved settings into the config on every later start -- the service's
prefetch rewrites its config each start, so the replay has to happen after it.  It exits 0 either
way: a PC that could not be measured keeps the defaults and still serves.

  strata-tune --config /var/lib/strata/config.json [--force] [--replay] [--max-attempts 3]

Needs STRATA_SHARE (the package's share dir), like strata-prefetch.  The engine it measures is
started and stopped here, so nothing else may hold the GPU while it runs: the service calls it in
its preStart, before the server is up.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

SHARE = Path(os.environ.get("STRATA_SHARE") or "")
if not SHARE.is_dir():
    sys.exit("[strata-tune] STRATA_SHARE must point at the package's share dir")
sys.path.insert(0, str(SHARE / "tools"))
sys.path.insert(0, str(SHARE))


def say(msg: str) -> None:
    print(f"[strata-tune] {msg}", flush=True)


def fail(msg: str) -> None:
    sys.exit(f"[strata-tune] {msg}")


def arg_value(args: list[str], flag: str) -> str | None:
    return args[args.index(flag) + 1] if flag in args and args.index(flag) + 1 < len(args) else None


def write_json(path: Path, payload: dict, mode: int = 0o644) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, indent=1), encoding="utf-8")
    os.replace(tmp, path)
    os.chmod(path, mode)


def read_json(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def hardware() -> dict:
    """What this PC is, without needing a tool outside the unit's sandbox.

    The card names come from the kernel driver's own sysfs entries (nvidia-smi is not part of the
    service's PATH); a machine without the NVIDIA driver keys on its CPU and RAM alone.
    """
    cpu = ""
    try:
        for line in Path("/proc/cpuinfo").read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith("model name"):
                cpu = line.split(":", 1)[1].strip()
                break
    except OSError:
        pass
    ram_kib = 0
    try:
        for line in Path("/proc/meminfo").read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith("MemTotal"):
                ram_kib = int(line.split()[1])
                break
    except OSError:
        pass
    gpus: list[str] = []
    try:
        for entry in sorted(Path("/proc/driver/nvidia/gpus").iterdir()):
            info = (entry / "information").read_text(encoding="utf-8", errors="replace")
            gpus += [x.split(":", 1)[1].strip() for x in info.splitlines() if x.startswith("Model:")]
    except (OSError, ValueError):
        pass
    if not gpus and shutil.which("nvidia-smi"):
        try:
            out = subprocess.run(["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"],
                                 capture_output=True, text=True, timeout=60).stdout
            gpus = [x.strip() for x in out.splitlines() if x.strip()]
        except Exception:
            pass
    return {"cpu": cpu, "cores": os.cpu_count() or 0, "ram_gib": round(ram_kib / 1048576, 1),
            "gpus": sorted(gpus)}


def fingerprint(cfg: dict) -> dict:
    """The key the measurement is filed under: this PC plus the model/context it serves.

    setup.py keys its calibration record the same way (GPU name + VRAM + CPU + RAM + model +
    context + images), so a new card, a new quant, or a longer context re-measures instead of
    replaying settings measured for something else.
    """
    args = list(cfg.get("args") or [])
    return {"hw": hardware(), "model": cfg.get("model_name"),
            "context": arg_value(args, "--max-context"), "vision": "--vision" in args,
            "gpu": cfg.get("gpu"), "parallel": cfg.get("parallel")}


def apply_settings(args: list[str], settings: dict) -> list[str]:
    """`args` with each measured value set; a flag the tuning did not decide is left as it is.

    calibrate.apply() also strips the flags whose default won, which is right for setup.py but
    would delete an --extra-arg of the operator's here.  Our prefetch writes the product defaults
    (no --pcie-frac, --spec-min-p 0.5), so leaving an undecided flag alone is the same value.
    """
    out = list(args)
    for flag, value in (settings or {}).items():
        if value is None:
            continue
        if flag in out and out.index(flag) + 1 < len(out):
            out[out.index(flag) + 1] = str(value)
        else:
            out += [flag, str(value)]
    return out


def merge_env(cfg: dict, env: dict) -> dict:
    """The config's env with the calibration's env vars on top (AMD's STRATA_SH_STREAM; NVIDIA
    measures nothing into env, so this is a no-op there)."""
    out = dict(cfg.get("env") or {})
    out.update({k: str(v) for k, v in (env or {}).items()})
    return out


def replay(cfg: dict, record: dict, config: Path, keep: int) -> int:
    settings, env = record.get("settings") or {}, record.get("env") or {}
    cfg["args"] = apply_settings(list(cfg.get("args") or []), settings)
    if env:
        cfg["env"] = merge_env(cfg, env)
    write_json(config, cfg, mode=keep)
    chosen = " ".join(f"{k} {v}" for k, v in sorted(settings.items())) or "the default settings are already the fastest here"
    say(f"replayed the tuning of {record.get('date', '?')}: {chosen}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--config", required=True, help="the config.json strata-prefetch emitted")
    ap.add_argument("--record", help="where the measurement is kept (default: tune.json beside the config)")
    ap.add_argument("--force", action="store_true", help="measure again even when a matching record exists")
    ap.add_argument("--replay", action="store_true", help="only apply a saved record; never start the engine")
    ap.add_argument("--max-attempts", type=int, default=3,
                    help="how often a failed measurement is retried before the defaults are kept for good")
    a = ap.parse_args()

    config = Path(a.config)
    if not config.is_file():
        fail(f"{config} is not there yet (run strata-prefetch --emit-config first)")
    cfg = read_json(config)
    if cfg is None or not cfg.get("args"):
        fail(f"{config} has no engine args to tune")

    record_path = Path(a.record) if a.record else config.parent / "tune.json"
    failed_path = config.parent / "tune-failed.json"
    mode = config.stat().st_mode & 0o777
    fp = fingerprint(cfg)

    record = read_json(record_path)
    if record and record.get("fingerprint") == fp:
        if a.force:
            say("a matching record exists; --force measures again")
        else:
            return replay(cfg, record, config, mode)
    if a.replay:
        say("no record for this PC and model; nothing to replay")
        return 0

    failed = read_json(failed_path)
    if failed and failed.get("fingerprint") == fp and int(failed.get("attempts") or 0) >= a.max_attempts:
        say(f"the tuning failed {failed['attempts']} times ({failed.get('error')}): the default settings stay "
            f"(delete {failed_path} to try again)")
        return 0

    import calibrate   # imports serve.server lazily, inside run()

    say("Tuning Strata for this PC: the PCIe share, the draft floor, the CPU expert pool, "
        "the VRAM expert tier, and the prompt chunks of a layer split. "
        "roughly 15-30 minutes (3 rounds of each value); the engine runs here, nothing else may hold the GPU.")
    t0 = time.time()
    try:
        res = calibrate.run(cfg, say=say)
    except Exception as e:
        attempts = int((failed or {}).get("attempts") or 0) + 1
        write_json(failed_path, {"fingerprint": fp, "error": f"{type(e).__name__}: {e}",
                                 "attempts": attempts, "date": time.strftime("%Y-%m-%dT%H:%M:%S")}, mode=mode)
        say(f"the tuning did not finish ({type(e).__name__}: {e}): the default settings stay"
            + (f" ({attempts} of {a.max_attempts} attempts)" if attempts < a.max_attempts else "; it will not be retried"))
        return 0

    settings = {k: v for k, v in (res.get("settings") or {}).items() if v is not None}
    env = res.get("env") or {}
    cfg["args"] = apply_settings(list(cfg.get("args") or []), settings)
    if env:
        cfg["env"] = merge_env(cfg, env)
    write_json(config, cfg, mode=mode)
    write_json(record_path, {"fingerprint": fp, "settings": settings, "env": env,
                             "tok_s": res.get("tok_s"), "seconds": round(time.time() - t0),
                             "date": time.strftime("%Y-%m-%dT%H:%M:%S"),
                             "report": res.get("report") or {}}, mode=mode)
    failed_path.unlink(missing_ok=True)
    say("tuned for this PC: " + (" ".join(f"{k} {v}" for k, v in sorted(settings.items()))
                                or "the default settings are already the fastest here"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
