{ lib, buildGoModule, git, fetchFromGitHub, buildNpmPackage }:

let

  version = "0.23.0";
  src = fetchFromGitHub {
    owner = "icereed";
    repo = "paperless-gpt";
    rev = "v${version}";
    hash = "sha256-4YjmXqFXoZbz64goF6VBe0a1UNVvVQWKoWkIZ+Tz4Oc=";
  };

  frontend = buildNpmPackage {
    pname = "paperless-gpt-frontend";
    inherit version;
    src = src + "/web-app";
    npmDepsHash = "sha256-hZ/8dy2xFYEFQolOkCTCOw3WKPMdeJtr1tD81VEz5z0=";

    installPhase = ''
      mkdir -p $out
      cp -r dist $out/dist
    '';

    meta = with lib; {
      description = "Frontend assets (Vite) for paperless-gpt";
      homepage = "https://github.com/icereed/paperless-gpt";
      license = licenses.mit;
      maintainers = with maintainers; [ ];
      platforms = platforms.unix;
    };
  };

in

buildGoModule rec {
  pname = "paperless-gpt";
  inherit src version;
  vendorHash = "sha256-TPN0bgowRsRB22OCgaPTujndsvet/pAZCPqt16o6Ep8=";

  preBuild = ''
    # go:embed needs the files to exist in the project folder structure, so copy from frontend
    # https://github.com/icereed/paperless-gpt/blob/6172b47c0c945c8fdd5e0a80cc21f7cd3e21766b/embedded_assets.go#L14
    cp -r ${frontend}/dist web-app/dist
  '';

  postInstall = ''
    install -d "$out/default_prompts"          # create the target directory
    install -m 644 default_prompts/* "$out/default_prompts/"
  '';

  checkFlags =
    let
      # Skip tests that require network access
      skippedTests = [
        "TestPromptTokenLimits"
        "TestTokenLimitInCorrespondentGeneration"
        "TestTokenLimitInCreatedDateGeneration"
        "TestTokenLimitInTagGeneration"
        "TestTokenLimitInTitleGeneration"
        "TestTokenLimitIntegration"
      ];
    in
    [ "-skip=^${builtins.concatStringsSep "$|^" skippedTests}$" ];

  # Minimal meta information
  meta = with lib; {
    description = "Backend (Go) for paperless-gpt - provides API and serves frontend assets";
    homepage = "https://github.com/icereed/paperless-gpt";
    license = licenses.mit;
    maintainers = with maintainers; [ ];
    platforms = platforms.unix;
  };

  passthru = {
    inherit frontend;
  };
}
