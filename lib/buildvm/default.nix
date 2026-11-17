// Shared constants for the build VM. Both consumers import this so there is exactly one
// place to change them:
//   * platforms/buildvm.nix  - the guest system (authorized key, hostname)
//   * platforms/ai.nix       - the host runner, the deploy gate, the Hermes ssh backend
//
// The private half of the key lives on ai at nixflakes.virtualisation.buildvm.privateKeyPath,
// outside the repo and outside anything the agent can write. setup-buildvm-storage.sh generates
// it and prints the public half to paste below.
{ hostName, lib, ... }:
{
  buildvm.publicKey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIREPLACE-WITH-KEY-PRINTED-BY-setup-buildvm-storage.sh buildvm@ai";

  # Raw partition handed straight to qemu; created by setup-buildvm-storage.sh.
  buildvm.disk = "/dev/disk/by-partlabel/buildvm";

  # qemu user-mode networking: the guest sshd is reachable from ai on this loopback port.
  buildvm.sshPort = 2224;

  # Matches the retired Docker sandbox limits (container_cpu = 12, container_memory = 8192).
  buildvm.cpus = 12;
  buildvm.memoryMiB = 8192;

  # Paths on ai.
  buildvm.stateDir = "/var/lib/buildvm";
  buildvm.gitDir = "/srv/git/nixflakes.git";
  buildvm.gitUrl = "file:///srv/git/nixflakes.git";

  # Guest-side path the agent works in.
  buildvm.workdir = "/home/builder/nixflakes";

  # Keep in sync with the user defined in platforms/buildvm.nix.
  buildvm.userName = "builder";
}
