{
  lib,
  python3,
  fetchFromGitHub,
  git,
  writableTmpDirAsHomeHook,
}:

let
  fastmcp = python3.pkgs.callPackage ./fastmcp.nix { };
in
python3.pkgs.buildPythonApplication rec {
  pname = "code-review-graph";
  version = "2.3.8";

  pyproject = true;

  src = fetchFromGitHub {
    owner = "tirth8205";
    repo = "code-review-graph";
    rev = "v${version}";
    hash = "sha256-NhssTYN0McUEpxAlb4bWDrdlCA6jFmXj9Cn9IxdkcUg=";
  };

  build-system = with python3.pkgs; [ hatchling ];

  nativeBuildInputs = with python3.pkgs; [ pythonRelaxDepsHook ];

  dependencies =
    with python3.pkgs;
    [
      mcp
      fastmcp
      networkx
      watchdog
      python3.pkgs."tree-sitter"
      python3.pkgs."tree-sitter-language-pack"
    ]
    ++ lib.optionals (python3.pythonOlder "3.11") [ tomli ];

  pythonRelaxDeps = [
    "tree-sitter-language-pack"
    "watchdog"
  ];

  nativeCheckInputs = with python3.pkgs; [
    pytestCheckHook
    pytest-asyncio
    writableTmpDirAsHomeHook
    git
  ];

  pythonImportsCheck = [ "code_review_graph" ];

  postInstall = ''
    install -d "$out/${python3.sitePackages}"
    cp -r docs hooks skills "$out/${python3.sitePackages}/"
    install -m 644 README.md LICENSE pyproject.toml "$out/${python3.sitePackages}/"
  '';

  meta = {
    description = "Persistent incremental knowledge graph for token-efficient, context-aware code reviews";
    homepage = "https://github.com/tirth8205/code-review-graph";
    license = lib.licenses.mit;
    mainProgram = "code-review-graph";
    platforms = lib.platforms.unix;
  };
}
