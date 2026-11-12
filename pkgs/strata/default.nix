# The Strata server bundle: the OpenAI/Anthropic-compatible Python server plus the Python
# environment it runs in, the parts of the source tree it reads at runtime, and the prefetch
# script.  The engine and the vision encoder are separate derivations (./engine.nix, ./vision.nix)
# carried through passthru, so a service can point at them without reaching into the store paths.
#
# No model weights are in the store: strata-prefetch downloads them into the service's state dir.
{
  lib,
  fetchFromGitHub,
  stdenvNoCC,
  makeWrapper,
  python312,
  engine,
  vision ? null,
}:
let
  pins = import ./src.nix { inherit fetchFromGitHub; };

  py = python312.withPackages (
    ps: with ps; [
      numpy
      jinja2
      regex
      pyyaml
      tqdm
      requests
      pillow
      psutil
      # strata-chat (tools/chat.py) is a Textual TUI; serve only needs the ones above.
      rich
      textual
    ]
  );

  # server.py resolves its repo root from its own location (ROOT = parents[1]) and imports serve/,
  # tools/, strata_cli/, strata_control/ plus gguf-py from llama.cpp.  Everything the server never
  # reads at runtime is dropped so the store path stays small (~14 MB instead of ~100 MB) - except
  # data/, which the engine's own arguments point into: strata-prefetch writes --expert-profile
  # $share/data/expert-profile[-coder].bin and copies $share/data/draft_vocab.bin into the MTP dir,
  # and serve/server.py reads $share/data/settings-register.json.
  share = stdenvNoCC.mkDerivation {
    pname = "strata-share";
    version = pins.version;
    src = pins.strataSrc;
    phases = [ "installPhase" ];
    installPhase = ''
      mkdir -p $out
      cp -rL ${pins.strataSrc}/. $out/
      chmod -R u+w $out
      rm -rf \
        $out/bench $out/docs $out/ref $out/apps $out/src $out/include \
        $out/metal $out/sycl $out/spark $out/tests $out/history \
        $out/research $out/docker $out/cmake $out/packaging $out/bin \
        $out/third_party $out/.gitattributes $out/.gitignore
      rm -rf \
        $out/data/dflash2-tuned $out/data/dsv41 \
        $out/data/experimental-speed-projection $out/data/quant_quality
      mkdir -p $out/third_party/llama.cpp
      cp -rL ${pins.llamaSrc}/gguf-py $out/third_party/llama.cpp/gguf-py
    '';
  };
in
stdenvNoCC.mkDerivation {
  pname = "strata";
  version = pins.version;
  dontUnpack = true;
  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/share
    cp -rL ${share}/ $out/share/strata/
    chmod -R u+w $out/share/strata
    install -Dm644 ${./prefetch.py} $out/share/strata/prefetch.py

    makeWrapper ${py}/bin/python $out/bin/strata-serve \
      --add-flags "$out/share/strata/serve/server.py"
    makeWrapper ${py}/bin/python $out/bin/strata-chat \
      --add-flags "$out/share/strata/tools/chat.py"
    makeWrapper ${py}/bin/python $out/bin/strata-prefetch \
      --add-flags "$out/share/strata/prefetch.py" \
      --set STRATA_SHARE "$out/share/strata"
    runHook postInstall
  '';

  passthru = {
    inherit
      engine
      vision
      share
      py
      ;
    inherit (pins) version ggmlPin;
  };

  meta = {
    description = "Strata local inference server (OpenAI/Anthropic-compatible API for Qwen3.8-Flash-Next)";
    homepage = "https://github.com/Niko1221/Strata";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "strata-serve";
  };
}
