# Strata's picture reader: llama.cpp's mtmd (the Qwen3.8-Flash-Next vision tower) built out of
# Strata's tools/vision CMake against the pinned llama.cpp checkout in ./src.nix.
#
# Same CUDA 13.0 pin as ./engine.nix, for the same reason.
{
  lib,
  fetchFromGitHub,
  cmake,
  ninja,
  patchelf,
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
  pname = "strata-vision";
  version = pins.version;
  strictDeps = true;

  # The sources built are llama.cpp; Strata only contributes the tools/vision CMake project.
  src = pins.llamaSrc;

  nativeBuildInputs = [
    cmake
    ninja
    patchelf
    cuda.cuda_nvcc
    autoAddDriverRunpath
  ];

  buildInputs = [ cuda.cudatoolkit ];

  # The pinned llama.cpp checkout is copied to a writable folder (some of its CMake glue wants to
  # write next to the sources); the build itself stays out of source.  No patch is applied: Strata's
  # tools/vision builds llama.cpp's mtmd at the same pinned commit the engine's ggml uses, as it is.
  # The CPU side keeps the portable AVX2 baseline (the CMakeLists' default): GGML_NATIVE=OFF with
  # AVX2, FMA, F16C and BMI2 on, so the binary runs on any x86-64 CPU and ggml's runtime dispatch
  # picks AVX-512 where the CPU has it.  STRATA_PORTABLE=OFF (the native build upstream's setup
  # uses) would bake the build machine's -march into the binary, which has no place in the nix
  # store.
  # fixupPhase matters here: without it the CMake CUDA glue leaves the toolkit's stub
  # `libcuda.so.1` (cuda-merged/lib/stubs) in the binary's RUNPATH with nothing ahead of it, so
  # ggml's dlopen("libcuda.so.1") resolves the stub and CUDA init fails ("CUDA driver is a stub
  # library").  postFixup then makes the real driver's path the first RUNPATH entry for sure.
  phases = [
    "unpackPhase"
    "patchPhase"
    "configurePhase"
    "buildPhase"
    "installPhase"
    "fixupPhase"
  ];

  # The encoder must sit on the same ggml commit the engine links, or the two halves disagree
  # about the mmproj format.  Build-time check: ${pins.strataSrc} is realized for the build, not
  # read at eval time (which would be an IFD).
  preConfigure = lib.optionalString pinCheck ''
    pin=$(cut -d' ' -f1 "${pins.strataSrc}/third_party/ggml/VERSION.txt" | tr -d '\r')
    if [ "$pin" != "${pins.ggmlPin}" ]; then
      echo "strata-vision: Strata ${pins.version} pins ggml at $pin," >&2
      echo "but pkgs/strata/src.nix fetches llama.cpp ${pins.ggmlPin}." >&2
      echo "Fix: set ggmlPin (and llamaSrc.hash) in pkgs/strata/src.nix, or run pkgs/strata/update.sh." >&2
      exit 1
    fi
  '';

  unpackPhase = ''
    runHook preUnpack
    cp -rL ${pins.llamaSrc} "$NIX_BUILD_TOP/llama"
    chmod -R u+w "$NIX_BUILD_TOP/llama"
    runHook postUnpack
  '';

  configurePhase = ''
    runHook preConfigure
    cd "$NIX_BUILD_TOP"
    cmake -S ${pins.strataSrc}/tools/vision -B build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DLLAMA_DIR=$NIX_BUILD_TOP/llama \
      -DSTRATA_VISION_CUDA=ON \
      -DCMAKE_CUDA_ARCHITECTURES=${cudaArch} \
      -DCMAKE_CUDA_COMPILER=${cuda.cuda_nvcc}/bin/nvcc
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    ninja -j "$NIX_BUILD_CORES" -C "$NIX_BUILD_TOP/build" strata-vision
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 "$NIX_BUILD_TOP/build/bin/strata-vision" $out/bin/strata-vision
    runHook postInstall
  '';

  postFixup = ''
    for f in $out/bin/*; do
      rpath=$(patchelf --print-rpath "$f" || true)
      case ":$rpath:" in
        *":/run/opengl-driver/lib:"*) ;;
        *) patchelf --set-rpath "/run/opengl-driver/lib''${rpath:+:$rpath}" "$f" ;;
      esac
    done
  '';

  env = {
    CUDAToolkit_ROOT = cuda.cudatoolkit;
    CUDAToolkit_INCLUDE_ROOT = cuda.cudatoolkit;
    CUDAToolkit_LIBRARY_ROOT = cuda.cudatoolkit;
  };

  passthru = {
    inherit (pins) ggmlPin;
    inherit cudaArch;
  };

  meta = {
    description = "Strata image encoder (llama.cpp's mtmd with the Qwen3.8-Flash-Next vision tower, sm_${cudaArch})";
    homepage = "https://github.com/Niko1221/Strata";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "strata-vision";
  };
})
