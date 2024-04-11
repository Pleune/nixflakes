## Setting up with lanzaboote (secure-boot)

1. Disable secure boot and install nixos
2. Install system from this flake e.g. `sudo nixos-rebuild switch --flake .#surface`
3. Generate secure boot keys with `sudo sbctl create-keys`
4. Enroll the keys with `sudo sbctl enroll-keys`
5. Reboot
