{
  lib,
  buildPythonPackage,
  fetchFromGitHub,
  pythonRelaxDepsHook,

  hatchling,
  uv-dynamic-versioning,

  authlib,
  cyclopts,
  exceptiongroup,
  griffelib,
  httpx,
  jsonref,
  jsonschema-path,
  mcp,
  openapi-pydantic,
  opentelemetry-api,
  packaging,
  platformdirs,
  py-key-value-aio,
  pydantic,
  pyperclip,
  python-dotenv,
  pyyaml,
  rich,
  uncalled-for,
  uvicorn,
  watchfiles,
  websockets,
}:

buildPythonPackage rec {
  pname = "fastmcp";
  version = "3.2.4";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "jlowin";
    repo = "fastmcp";
    tag = "v${version}";
    hash = "sha256-rJpxPvqAaa6/vXhG1+R9dI32cY/54e6I+F/zyBVoqBM=";
  };

  nativeBuildInputs = [ pythonRelaxDepsHook ];

  build-system = [
    hatchling
    uv-dynamic-versioning
  ];

  pythonRelaxDeps = [ "py-key-value-aio" ];

  dependencies = [
    authlib
    cyclopts
    exceptiongroup
    griffelib
    httpx
    jsonref
    jsonschema-path
    mcp
    openapi-pydantic
    opentelemetry-api
    packaging
    platformdirs
    py-key-value-aio
    pydantic
    pyperclip
    python-dotenv
    pyyaml
    rich
    uncalled-for
    uvicorn
    watchfiles
    websockets
  ]
  ++ py-key-value-aio.optional-dependencies.filetree
  ++ py-key-value-aio.optional-dependencies.keyring
  ++ py-key-value-aio.optional-dependencies.memory
  ++ pydantic.optional-dependencies.email;

  pythonImportsCheck = [ "fastmcp" ];

  # Upstream fastmcp's test suite is large and flaky in nixpkgs sandboxes.
  # This repo already disables checks on the nixpkgs-packaged fastmcp override.
  doCheck = false;

  meta = {
    description = "Fast, Pythonic way to build MCP servers and clients";
    homepage = "https://github.com/jlowin/fastmcp";
    license = lib.licenses.asl20;
    platforms = lib.platforms.unix;
  };
}
