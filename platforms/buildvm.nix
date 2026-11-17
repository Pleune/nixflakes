# The Hermes agent's execution host: a NixOS guest on ai, reachable over ssh.
# It is also the build machine for ai's own system, so its store holds most of the closure and
# ai's root filesystem stays small.
{ config, lib, pkgs, ... }:
with lib;
let
  buildvm = import ../../lib/buildvm { hostName = "buildvm"; inherit lib; };
in
{
  imports = [ ../../modules/nixos ];

  networking.hostName = "buildvm";

  # No physical install: qemu boots this config with -kernel/-initrd/-append, so there is
  # nothing for a bootloader to do and switch-to-configuration must not look for one.
  boot.loader.grub.enable = false;
  boot.loader.efi.canTouchEfiVariables = false;

  # The image is a bare ext4 filesystem written onto the host partition (/dev/vda in the guest),
  # so stage 1 needs virtio and ext4 before it can mount root.
  boot.initrd.kernelModules = [ "virtio_pci" "virtio_blk" "ext4" ];

  # Skip the repo's default user: no password login, no home-manager in a build VM.
  nixflakes.makeUser = false;

  users.users.${buildvm.userName} = {
    isNormalUser = true;
    shell = pkgs.bash;
    home = "/home/${buildvm.userName}";
    # Not in wheel: the agent builds and pushes; it activates nothing on ai.
    extraGroups = [ ];
    openssh.authorizedKeys.keys = [ buildvm.publicKey ];
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  options.nixflakes.buildvm.desktop = mkOption {
    type = types.bool;
    default = true;
    description = ''
      Install Xvnc + Xfce + a browser.  bot_desktop runs inside this guest
      (services.hermes-agent.settings.bot_desktop.placement = "auto" on ai) and Hermes cannot
      install anything on NixOS: it only checks for these binaries, and its package map covers
      apt/dnf/pacman only (hermes tools/bot_desktop/runtime.py REQUIRED_BINARIES).
    '';
  };

  environment.systemPackages = with pkgs; [
    git
    openssh
    nixVersions.latest
    deploy-rs
    jq
  ] ++ optionals config.nixflakes.buildvm.desktop (with pkgs; [
    tigervnc # Xvnc
    xfwm4
    xfce4-panel
    xfdesktop
    xfce4-settings # xfsettingsd
    xfce4-terminal
    dbus # dbus-run-session
    xauth
    xdpyinfo
    setxkbmap
    xprop
    chromium
    dejavu_fonts
  ]);

  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 14d";
  };

  # Keep build logs from filling the guest disk.
  services.journald.extraConfig = ''
    SystemMaxUse=512M
    RuntimeMaxUse=128M
  '';

  systemd.services.nix-daemon.serviceConfig.LimitNOFILE = 65536;

  system.stateVersion = "25.05";
}
