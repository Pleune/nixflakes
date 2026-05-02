{ ... }:
{
  imports = [
    ./core/agenix.nix
    ./core/lanzaboote.nix
    ./core/nix.nix
    ./core/printing.nix
    ./core/terminal.nix
    ./core/user.nix
    ./network/mdns.nix
    ./network/networkmanager.nix
    ./network/ssl.nix
    ./services/local-gitea.nix
    ./services/incus-backup-rustic.nix
    ./services/wake-on-lan-api.nix
  ];
}
