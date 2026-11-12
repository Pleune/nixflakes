# Source pins shared by pkgs/strata/{default.nix,engine.nix,vision.nix}.
# Kept in sync by pkgs/strata/update.sh.
#
# Both sources are fetched here rather than carried as flake inputs: the packages own their own
# hashes, and reading Strata's third_party/ggml/VERSION.txt at eval time would be an
# import-from-derivation (AGENTS.md forbids that: `nix flake check --no-build` must pass).  The
# check that the two sources agree therefore runs inside the build - see pinCheck in engine.nix.
{ fetchFromGitHub }:
rec {
  version = "0.2.13";

  # The llama.cpp/ggml commit named by Strata's third_party/ggml/VERSION.txt at this tag.  The
  # engine builds ggml out of this checkout and strata-vision builds llama.cpp's mtmd out of the
  # same commit, so the pin and its hash move together with `version`.
  ggmlPin = "3cf03257f219afbe7334045ff7c6a06ac68c627d";

  strataSrc = fetchFromGitHub {
    owner = "Niko1221";
    repo = "Strata";
    rev = "v${version}";
    hash = "sha256-ygLtDYyrwfRKez46xKnPkO7BtY0Q4uMwxlvh3JyUHbE=";
  };

  llamaSrc = fetchFromGitHub {
    owner = "ggml-org";
    repo = "llama.cpp";
    rev = ggmlPin;
    hash = "sha256-SRGoXa+4ACBCB3eaG9XFYhMN1i0FyPEy9Rrer+dFGYI=";
  };
}
