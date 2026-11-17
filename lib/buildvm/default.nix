# Shared constants for the build VM. A plain attrset (not a module) so both consumers can import
# it without declaring options:
#   * platforms/buildvm.nix  - the guest system (authorized key, hostname)
#   * platforms/ai.nix       - the host runner, the deploy gate, the Hermes ssh backend
#
# The private half of the key lives on ai at nixflakes.virtualisation.buildvm.privateKeyPath,
# outside the repo and outside anything the agent can write. docs/buildvm-ai-setup.md section 4
# generates it and prints the public half to paste below.
#
# There is deliberately no repo on ai.  The agent clones from the git host inside the guest, and
# deploy-ai is told which repo to read with a required --repo URL.
let
  stateDir = "/var/lib/buildvm";
in
rec {
  publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAvtkbKm1Q/LHKAYelr6EidEUGY3xYkQGHknRRXZkkFn buildvm@ai";

  # Raw partition handed straight to qemu; created by hand (docs/buildvm-ai-setup.md section 3).
  disk = "/dev/disk/by-partlabel/buildvm";

  # qemu user-mode networking: the guest sshd is reachable from ai on this loopback port.
  sshPort = 2224;

  # Matches the retired Docker sandbox limits (container_cpu = 12, container_memory = 8192).
  cpus = 12;
  memoryMiB = 8192;

  # Paths on ai.
  inherit stateDir;

  # Private half of the keypair on ai, generated during setup.  Mode 0640 root:hermes so the
  # gateway units can use it as the ssh sandbox key.
  privateKeyPath = "${stateDir}/secrets/id_ed25519";

  # Where the agent clones from, and what it works in. Both are guest-side paths/URLs.
  gitHost = "ssh://git@git.pleunetowne.com:2223/mitchpleune/nixflakes.git";
  workdir = "/home/builder/nixflakes";

  # Written by deploy-ai after every successful switch, outside the checkout so it never makes
  # the agent's working tree dirty.  This is the guest's only channel for "which commit is live".
  deployedCommitFile = "/home/builder/deployed-commit";

  # Scratch directory deploy-ai unpacks the candidate tree into inside the guest.
  candidateDir = "/home/builder/deploy-candidate";

  # Keep in sync with the user defined in platforms/buildvm.nix.
  userName = "builder";
}
