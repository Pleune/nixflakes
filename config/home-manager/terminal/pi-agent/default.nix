{ lib, pkgs, ... }:
{
  config.nixflakes.programs.pi-agent.profile = lib.mkDefault (import ../../../pi-agent/profile.nix { inherit pkgs; });
}
