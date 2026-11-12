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
  # GPU access: DRI render nodes, NVIDIA/AMD device nodes, and a read-only
  # sysfs device view. Guarded, so GPU-less hosts are unaffected.
  gpu
  mount-cwd
  jailCombinators.capture-host-home
  (jailCombinators.safe-path-from-var-resolved "PATH" ":")
  (jailCombinators.minimal-env "/tmp/pi-home" forwardedEnv)
  # Share the host git identity and ignore/attributes files read-only. Home
  # Manager installs the config at ~/.config/git; the legacy ~/.gitconfig
  # location is covered for hosts that use it instead.
  (jailCombinators.ro-bind-host-home-path ".config/git" ".config/git")
  (jailCombinators.ro-bind-host-home-path ".gitconfig" ".gitconfig")
  (share-ns "net")
]
