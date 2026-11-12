# strata

Nix packaging and a NixOS service for [Strata](https://github.com/Niko1221/Strata) — a local
inference engine for Qwen3.8-Flash-Next (a 125B MoE) that answers over an OpenAI-compatible `/v1`
API (and an Anthropic-shaped one). Strata ships an AppImage, a
desktop app and its own installer (`setup.py`, which compiles the engine and downloads a model);
this package does neither: the engine is built from source by Nix, and the model is fetched into a
service state directory at start instead of into the store.

Upstream references this packaging follows:

- Engine + server + CLI: <https://github.com/Niko1221/Strata> (pinned tag in [`src.nix`](./src.nix)),
  releases: <https://github.com/Niko1221/Strata/releases>
- The ggml checkout the engine builds against, named by Strata's `third_party/ggml/VERSION.txt`:
  <https://github.com/ggml-org/llama.cpp>
- Model files, downloaded at run time from Hugging Face: [agentionai's Gyro
  quants](https://huggingface.co/agentionai/Qwen3.8-Flash-Next-Gyro-GGUF) and
  [ISTA's GSQ-RCO quants](https://huggingface.co/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF),
  which also carries the picture-reader mmproj every family shares.  Their revisions and sha256s are
  pinned in [`prefetch.py`](./prefetch.py), copied from upstream `setup.py`.
- Packaging and module ported from <https://github.com/Yunor743/strata.nix>, then adapted to this
  repo's conventions (`nixflakes.services.strata`, `pkgs/strata/`, checks in `checks`, `update.sh`).

## Files

| File | What it is |
|------|------------|
| [`src.nix`](./src.nix) | The two source pins (`version`, `ggmlPin`, `strataSrc`, `llamaSrc`) shared by the other files. Fetched here, not as flake inputs, so reading `VERSION.txt` never happens at eval time (AGENTS.md forbids import-from-derivation; `nix flake check --no-build` has to pass). |
| [`engine.nix`](./engine.nix) | `strata-engine`: the CUDA engine (`strata`, `strata-device`), built with `cudaPackages_13_0`'s `backendStdenv` for `cudaArch` (default `"86"`). A real pre-configure check compares the `llama.cpp` pin with `third_party/ggml/VERSION.txt`, so a drifted pin fails the build instead of silently building the wrong ggml. |
| [`vision.nix`](./vision.nix) | `strata-vision`: the image encoder, built out of the same `llama.cpp` commit plus Strata's `tools/vision`. `postFixup` prepends `/run/opengl-driver/lib` to its RUNPATH, otherwise it dlopens the CUDA toolkit's stub `libcuda.so.1` and reports "CUDA driver is a stub library". |
| [`default.nix`](./default.nix) | `strata`: the Python bundle — `strata-serve`, `strata-chat`, `strata-prefetch` over a pruned copy of the repo (`serve/ tools/ strata_cli/ strata_control/ data/` + `gguf-py`), ~12 MB instead of ~100 MB. Carries `passthru.engine` and `passthru.vision`. |
| [`prefetch.py`](./prefetch.py) | Vendored downloader/packer: resolves the family+quant, verifies each file's size and sha256 against the pins from upstream `setup.py`, builds the pack (`iq_pack.py`), fetches the MTP draft, and emits the engine's config JSON. |
| [`checks/`](./checks/) | `strata-serve-smoke` (mock engine over HTTP), `strata-prefetch-vision`, `strata-prefetch-gyro`, `strata-module-{vision,parallel,extra-args,gyro,hosts}` (evaluate the module against stub packages, no build), `strata-vm` (a NixOS test). |
| [`update.sh`](./update.sh) | Bumps Strata to a release tag, re-derives the `llama.cpp` pin, refreshes both hashes, and syncs the Gyro pins out of the new `setup.py`. |

The service itself lives in [`../../modules/nixos/strata/default.nix`](../../modules/nixos/strata/default.nix)
as `nixflakes.services.strata`, and the packages are exposed by [`../../overlay.nix`](../../overlay.nix):
`strata-engine`, `strata-vision`, `strata` (bundle). Model weights are never in the store.

## Packages

```bash
nix build --no-link .#packages.x86_64-linux.strata        # server + prefetch + engine + encoder
nix build --no-link .#packages.x86_64-linux.strata-engine  # just the CUDA engine
nix build --no-link .#packages.x86_64-linux.strata-vision  # just the image encoder
```

`cudaArch` is a plain number (`"86"` Ampere, `"120"` Blackwell) and a build-time parameter on both
`strata-engine` and `strata-vision` — `pkgs.strata-engine.override { cudaArch = "120"; }` for a
Blackwell card, which is what the module's `cudaArch` option does for you.  Changing it rebuilds the
engine, and `nvcc` compiling ggml's CUDA kernels in parallel is heavy enough that the build belongs
on the GPU machine rather than a small box.

## Service

The unit is `strata.service`. Its `preStart` runs `strata-prefetch` (download + pack + write
`config.json`), then `ExecStart` runs `strata-serve --config %S/strata/config.json`. State lives in
`/var/lib/strata` (`StateDirectory`), the service is `DynamicUser` with `PrivateTmp` and the usual
hardening, and `TimeoutStartSec = 0` so systemd does not kill the first start (a ~92 GB download).

| Option | Default | Notes |
|--------|---------|-------|
| `enable` | `false` | |
| `cudaArch` | `"86"` | Compiled into `package`; changing it rebuilds the engine. |
| `package` | `pkgs.strata` with `cudaArch` engines | Bundle; `passthru.engine` / `passthru.vision` are what the unit execs. |
| `family` | `"swift"` | `qwen`, `swift`, `abliterated`, `coder`, `gyro`. |
| `model` | `"IQ2_XS"` | `Q2_0`, `IQ2_XS`, `IQ3_XXS`, `IQ3_S` (qwen only), `IQ1_M` (coder only), `Gyro-S`, `Gyro-M` (gyro only — Gyro publishes sizes, not quants). |
| `context` | `32768` | One of 8192…1048576. Past 262144 prefetch turns yarn on itself. |
| `kv` | `null` | `int8`, `q4_0`, `k8v4`, `fp16`. `int8` halves the KV footprint; same as `extraEngineArgs = [ "--kv" "int8" ]`. |
| `host` | `"127.0.0.1"` | `0.0.0.0` serves the LAN. |
| `port` | `8080` | |
| `apiKeyFile` | `null` | Read through a systemd credential, never put in the unit. |
| `allowUnauthenticated` | `false` | Explicit opt-in to serve a non-loopback host with no key. |
| `allowedHosts` | `[ ]` | Extra `Host:` names the server answers. See "Exposure" below. |
| `openFirewall` | `false` | Adds `port` to `networking.firewall.allowedTCPPorts`. |
| `gpus` | `[ ]` | CUDA device numbers; empty lets the engine pick the biggest card, several means layer split. |
| `vision` | `"auto"` | `off`, `auto` (GPU encoder on a ≥24 GB card, else CPU), `cpu`, `gpu`. |
| `parallel` | `null` | 1–8 replicas on one card. |
| `lowRam` | `null` | Expert streaming; prefetch decides by default. |
| `sampling` / `mcpServers` | `{ }` | Passed through into the served config. |
| `extraEngineArgs` | `[ ]` | Anything the module does not model, forwarded via `--extra-arg`. |
| `mockEngine` | `false` | Serves canned text without the CUDA engine — for tests and CI. |
| `prefetchOnStart` | `true` | Turn off once the pack exists, so restarts do not re-verify 92 GB. |
| `hfTokenFile` | `null` | Only needed if Hugging Face rate-limits the download. |

Family and quant are cross-checked (`IQ3_S` is qwen-only, `IQ1_M` is coder-only, the Gyro sizes are
gyro-only), a non-loopback host needs `apiKeyFile` or `allowUnauthenticated`, `mockEngine` implies
no prefetch and no vision, and `vision` on needs a bundle carrying `passthru.vision`.

### Example (the `ai` host)

[`../../platforms/ai.nix`](../../platforms/ai.nix) runs Gyro-M on GPU 0 at 128K context, unserved-key
LAN access for the `llm` host:

```nix
nixflakes.services.strata = {
  enable = true;
  cudaArch = "86";            # RTX card on ai
  family = "gyro";
  model = "Gyro-M";
  context = 131072;
  kv = "int8";
  port = 8080;
  vision = "cpu";
  gpus = [ "0" ];

  host = "0.0.0.0";
  allowUnauthenticated = true;
  openFirewall = true;
  allowedHosts = [ "ai.home.pleunetowne.com" ];
};
```

## Exposure

The server answers only `Host:` names it knows. Out of the box that is `localhost`, the bind host,
the machine's hostname plus `.local`, `host.docker.internal`, and its own LAN addresses — so a
client that calls a domain the host does not know gets HTTP **403**, not a connection error.
`allowedHosts` is what adds names to that list; the module renders it as `STRATA_ALLOWED_HOSTS` on
the unit, and prefetch merges it into `config.json`. Requests by IP address are always accepted.

`apiKeyFile` is the usual way to serve the LAN; `allowUnauthenticated` is the deliberate opt-out for
a network you control (here, PleuneNET). Both need `networking.firewall.enable = true` to mean
anything, since a bare `openFirewall` on a host with the firewall off does nothing.

## Validating

Cheap and CUDA-free (this box has no NVIDIA GPU, so everything GPU-side is validated on `ai`):

```bash
# eval-only, no build, no GPU
nix eval --option eval-cache false .#packages.x86_64-linux.strata.drvPath

# module wiring: evaluates the unit against stub packages, builds nothing
nix build --no-link .#checks.x86_64-linux.strata-module-hosts

# the mock engine over HTTP: /health, /v1/chat/completions, /v1/models, /metrics
nix build --no-link .#checks.x86_64-linux.strata-serve-smoke

# download plan + sha256s, without downloading (~80 MB of GGUF headers only)
nix build --no-link .#checks.x86_64-linux.strata-prefetch-gyro
```

`strata-vm` is the real NixOS test and pulls a VM image — leave it for a machine with spare RAM.
`nix flake check --no-build` needs the `private` input (agenix secrets), so it can only run where
that repo is reachable; the strata checks above do not.

## Updating

```bash
./update.sh            # latest release
./update.sh v0.2.14    # a specific tag
```

It rewrites `version`, `ggmlPin` and both hashes in [`src.nix`](./src.nix), and re-extracts the Gyro
Hub revision plus the two sha256/size pairs from `setup.py` at the new tag into
[`prefetch.py`](./prefetch.py) — the two copies of those pins would otherwise drift silently and
prefetch would reject a model upstream has since re-quantized. Then:

```bash
git diff
nix build --no-link .#packages.x86_64-linux.strata
nix build --no-link .#checks.x86_64-linux.strata-serve-smoke
nix build --no-link .#checks.x86_64-linux.strata-prefetch-gyro
```

## Notes

- CUDA 13.0 specifically: Strata's own dev shell pins `cudaPackages_13_0` because its engine was
  built against 13.0.88 and toolkit 13.2 miscompiles `sm_120`. The engine links cuBLAS/cuDNN from
  the pinned toolkit; the driver comes from `/run/opengl-driver` (NixOS), and `autoAddDriverRunpath`
  makes it resolvable — no `lib_dirs` equivalent of the installer's pip wheels.
- `data/` is deliberately kept in the bundle: `prefetch.py` needs `data/draft_vocab.bin` and the
  per-family `expert-profile*.bin` to build a pack. Pruning it breaks every real start, while the
  mock engine and dry-run checks still pass — which is how that bug got past the tests once.
- First start needs room: ~92 GB of downloads for Gyro-M plus the built pack, and `Gyro-M` wants
  about 35 GB spread across VRAM and system RAM (`ram_gb` in `prefetch.py` counts both together).
`ai` runs without swap, so check free disk and free memory before the first switch.
- The image encoder runs on CPU by default on `ai` (`vision = "cpu"`): the GPU is already at its
  memory limit serving experts.
