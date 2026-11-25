# cua-driver — the MCP driver Hermes' computer_use backend spawns inside the build VM guest
# (`cua-driver mcp --no-overlay` over the ssh exec channel; bot_desktop terminal placement),
# which nothing on NixOS otherwise installs.
#
# Built from source at the pinned trycua/cua release tag.  The release tarball alternative was
# rejected: it is a foreign glibc-dynamic binary needing patchelf interpreter/RPATH surgery.
# `rev` is the tag commit of `cua-driver-rs-v0.28.2`; bump it together with Hermes' own pin
# (hermes-agent `docker/sandbox-desktop.Dockerfile`, ARG CUA_DRIVER_VERSION).
#
# This derivation mirrors upstream's `nix/cua-driver/package.nix` at that tag rather than
# importing it from the fetched source: importing a fetched path at eval time is Import From
# Derivation and breaks eval-only checks (`nix flake check --no-build`).  The mirror keeps only
# the Linux-relevant half: `cargoBuildFlags` builds `-p cua-driver`, whose workspace gates the
# macOS/Windows crates behind cfg(target_os).  Unlike the flake-input variant this needs no
# `flake.lock` change, so it can reach ai through the deploy-ai gate (top-level files outside
# flake.nix are refused).
{
  lib,
  stdenv,
  fetchFromGitHub,
  rustPlatform,
  pkg-config,
  pipewire,
  libei,
  libxkbcommon,
  libx11,
  libxi,
  libxtst,
  libxext,
  zstd,
}:

rustPlatform.buildRustPackage (finalAttrs: {
  pname = "cua-driver";
  version = "0.28.2";

  src = fetchFromGitHub {
    owner = "trycua";
    repo = "cua";
    rev = "fc188250b4ca8549b8e61f937fdb1fb560770e86"; # tag cua-driver-rs-v0.28.2
    hash = "sha256-sSAHLhIPC8Hqc1u4xyIc0OfRYIcm8F5sK5Yqg7+Qi7k=";
  };

  # The crate workspace lives in the monorepo at libs/cua-driver/rust.
  sourceRoot = "source/libs/cua-driver/rust";

  # Vendor straight from the committed Cargo.lock, exactly like upstream's derivation: every
  # dependency's hash derives from the lockfile, so there is no cargoHash to hand-maintain.
  cargoLock.lockFile = "${finalAttrs.src}/libs/cua-driver/rust/Cargo.lock";

  # Upstream's build contract: the main binary crate with both portal capabilities, so the
  # PipeWire ScreenCast + libei RemoteDesktop paths compile against this package set.
  cargoBuildFlags = [ "-p" "cua-driver" "--features" "portal-input,portal-capture" ];

  nativeBuildInputs = [
    pkg-config
    # bindgen needs libclang for the libpipewire/libspa SPA-pod codegen.
    rustPlatform.bindgenHook
  ];

  # Upstream's list (X11 for the raw-Xlib multi-cursor path; PipeWire/libei/libxkbcommon for the
  # Wayland-parity portal paths) plus zstd: the `zstd-sys` crate asks pkg-config for libzstd and
  # upstream's derivation does not list it.
  buildInputs = [
    libx11
    libxi
    libxtst
    libxext
    pipewire
    libei
    libxkbcommon
    zstd
  ];

  # Tests want a live X11 display / AT-SPI bus.
  doCheck = false;

  meta = with lib; {
    description = "Cross-platform MCP server for computer-use automation";
    homepage = "https://github.com/trycua/cua";
    license = licenses.mit;
    mainProgram = "cua-driver";
    platforms = platforms.linux;
  };
})
