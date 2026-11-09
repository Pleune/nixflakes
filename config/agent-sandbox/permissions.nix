{ pkgs }:
combinators:
let
  jailCombinators = import ../../lib/jail/combinators.nix {
    inherit combinators pkgs;
    lib = pkgs.lib;
  };
  forwardedEnv = [
    "OPENAI_API_KEY"
    "ANTHROPIC_API_KEY"
    "GOOGLE_API_KEY"
    "MISTRAL_API_KEY"
    "DEEPSEEK_API_KEY"
    "XAI_API_KEY"
  ];
in
with combinators;
[
  (jailCombinators.ro-bind-all-in-except "/" "/" [
    "tmp"
    "proc"
    "sys"
    "dev"
    "home"
  ])
  mount-cwd
  jailCombinators.capture-host-home
  (jailCombinators.safe-path-from-var-resolved "PATH" ":")
  (jailCombinators.minimal-env "/tmp/pi-home" forwardedEnv)
  (share-ns "net")
]
