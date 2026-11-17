# Shared constants for the build VM. A plain attrset (not a module) so every consumer can import
# it without declaring options:
#   * platforms/buildvm.nix        - the guest system (authorized key, hostname)
#   * platforms/ai.nix             - the host runner, the deploy gate, the Hermes ssh backend
#   * platforms/buildvm-bootstrap.nix - the seed image, which is evaluated *without* the secrets
#                                       input and therefore gets no public key of its own
#
# There is one ai <-> buildvm keypair.  Its private half lives in the secrets repo as
# ai_buildvm_id_ed25519.age, decryptable with ai's host key, and ai exposes it through agenix at
# nixflakes.virtualisation.buildvm.privateKeyPath: deploy-ai, the Hermes terminal, and
# buildvm-install all use it, and buildvm-install grafts it into the guest as builder's own
# ~/.ssh/id_ed25519 so the guest authenticates outbound with the same identity.
#
# The public half is read from the same repo (`ai_buildvm_id_ed25519.pub`).  That is an eval-time
# read of a fetched flake input, not of a derivation, so it introduces no IFD; it does mean the
# lock file has to point at a revision that contains the file.
{ private ? null }:
let
  stateDir = "/var/lib/buildvm";

  # sshd takes one line per key; the committed .pub ends with a newline, which would otherwise
  # become a blank line inside authorized_keys.
  firstLine = text: builtins.elemAt (builtins.match "([^\r\n]+)[\r\n]*" text) 0;
in
rec {
  # "" when the secrets input was not passed (the seed image), which the consumers filter out.
  publicKey = if private == null then "" else firstLine (builtins.readFile "${private.secrets}/ai_buildvm_id_ed25519.pub");

  # Raw partition handed straight to qemu; created by hand (docs/buildvm-ai-setup.md section 3).
  disk = "/dev/disk/by-partlabel/buildvm";

  # qemu user-mode networking: the guest sshd is reachable from ai on this loopback port.
  sshPort = 2224;

  # Matches the retired Docker sandbox limits (container_cpu = 12, container_memory = 8192).
  cpus = 12;
  memoryMiB = 8192;

  # Paths on ai.
  inherit stateDir;

  # Private half of the keypair, as an agenix-generated path on ai (platforms/ai.nix wires it to
  # config.age.secrets."ai_buildvm_id_ed25519", mode 0640 root:hermes so the gateway units can read
  # it).  Kept as a plain default so the module stays usable without agenix.
  privateKeyPath = "${stateDir}/secrets/id_ed25519";

  # Where the agent's checkout comes from and what it works in.  Both are guest-side paths/URLs.
  # buildvm-install clones it from the repository already on ai, so neither the seed nor the switch
  # needs to reach the git host; `origin` is still the real URL so the agent can pull and push once
  # that host accepts the key it was given.
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
