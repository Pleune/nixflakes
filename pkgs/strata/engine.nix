# The Strata C++ inference engine (CUDA) for Qwen3.8-Flash-Next.
#
# Built against the llama.cpp/ggml checkout pinned in ./src.nix; Strata's own build expects exactly
# that commit and reads ggml from -DSTRATA_GGML_DIR rather than from its vendored copy.
#
# CUDA 13.0 on purpose: Strata's setup.py/dev shell asks for 13.0.88 (the published engine is built
# with it), and newer toolkits miscompile sm_120.  nixpkgs' default cudaPackages tracks 13.4 here,
# so the version is named instead of taken from the default set.
{
  lib,
  fetchFromGitHub,
  cmake,
  ninja,
  autoAddDriverRunpath,
  cudaPackages_13_0,
  cudaArch ? "86",
  pinCheck ? true,
}:
let
  pins = import ./src.nix { inherit fetchFromGitHub; };
  cuda = cudaPackages_13_0;
in
cuda.backendStdenv.mkDerivation (finalAttrs: {
  pname = "strata-engine";
  version = pins.version;
  src = pins.strataSrc;
  strictDeps = true;

  nativeBuildInputs = [
    cmake
    ninja
    cuda.cuda_nvcc
    autoAddDriverRunpath
  ];

  buildInputs = [ cuda.cudatoolkit ];

  # Strata vendors ggml as a pin (VERSION.txt), not as the sources it builds: a checkout of
  # llama.cpp that does not match that commit links an engine whose ggml disagrees with the
  # pack/quant formats the server expects.  Checked here rather than at eval time because
  # $src is a derivation output (reading it during evaluation would be an IFD).
  preConfigure = lib.optionalString pinCheck ''
    pin=$(cut -d' ' -f1 "$src/third_party/ggml/VERSION.txt" | tr -d '\r')
    if [ "$pin" != "${pins.ggmlPin}" ]; then
      echo "strata-engine: Strata ${finalAttrs.version} pins ggml at $pin," >&2
      echo "but pkgs/strata/src.nix fetches llama.cpp ${pins.ggmlPin}." >&2
      echo "Fix: set ggmlPin (and llamaSrc.hash) in pkgs/strata/src.nix, or run pkgs/strata/update.sh." >&2
      exit 1
    fi
  '';

  cmakeFlags = [
    "-DCMAKE_BUILD_TYPE=Release"
    "-DSTRATA_ENABLE_CUDA=ON"
    "-DSTRATA_BUILD_TESTS=OFF"
    "-DCMAKE_CUDA_ARCHITECTURES=${cudaArch}"
    "-DCMAKE_CUDA_COMPILER=${cuda.cuda_nvcc}/bin/nvcc"
    "-DSTRATA_GGML_DIR=${pins.llamaSrc}"
    # The build machine's CPU is not the target machine: keep the portable AVX2 baseline and let
    # ggml's runtime dispatch use AVX-512 where the CPU has it.
    "-DGGML_NATIVE=OFF"
    "-DGGML_AVX=ON"
    "-DGGML_AVX2=ON"
    "-DGGML_FMA=ON"
    "-DGGML_F16C=ON"
    "-DGGML_BMI2=ON"
    "-DGGML_AVX512=ON"
  ];

  env = {
    CUDAToolkit_ROOT = cuda.cudatoolkit;
    CUDAToolkit_INCLUDE_ROOT = cuda.cudatoolkit;
    CUDAToolkit_LIBRARY_ROOT = cuda.cudatoolkit;
  };

  buildFlags = [
    "--target"
    "strata"
    "--target"
    "strata-device"
  ];

  # The engine binary lands in the cmake build tree, but Strata's source also ships a shell
  # launcher called `strata` (bin/strata), so a name-only search can pick the wrong file.  Take
  # the first candidate that is actually an ELF executable.
  installPhase = ''
        runHook preInstall

        find_elf() {
          local name="$1" f
          while IFS= read -r f; do
            if readelf -h "$f" >/dev/null 2>&1; then
              printf '%s\n' "$f"
              return 0
            fi
          done < <(find "$NIX_BUILD_TOP" -maxdepth 5 -type f -name "$name")
          return 1
        }

        bin=$(find_elf strata) || {
          echo "strata: no ELF binary named 'strata' under $NIX_BUILD_TOP (cmake built nothing?)" >&2
          exit 1
        }
        dev=$(find_elf strata-device) || dev=""

        install -Dm755 "$bin" $out/bin/strata
        [[ -n "$dev" ]] && install -Dm755 "$dev" $out/bin/strata-device

        # What upstream's setup.py writes next to the engine; the server reads it to know what the
        # binary can do.  "archs" stays a bare number, as upstream writes it.
        cat > $out/bin/BUILD.json <<EOF
    {
      "version": "${finalAttrs.version}",
      "archs": [${cudaArch}],
      "ptx": false,
      "source": "nix",
      "vision": "none"
    }
    EOF

        runHook postInstall
  '';

  passthru = {
    inherit (pins) ggmlPin;
    inherit cudaArch;
  };

  meta = {
    description = "Strata inference engine for Qwen3.8-Flash-Next (125B MoE) on a single NVIDIA GPU (sm_${cudaArch})";
    homepage = "https://github.com/Niko1221/Strata";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "strata";
  };
})
