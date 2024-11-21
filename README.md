## Setting up with Lanzaboote (secure-boot)

1. Disable secure boot and install NixOS
2. Install system from this flake e.g. `sudo nixos-rebuild switch --flake .#surface`
3. Generate secure boot keys with `sudo sbctl create-keys`
4. Enroll the keys with `sudo sbctl enroll-keys`
5. Reboot

## Bootstrap fresh system (WSL)

```bash
nix shell nixpkgs#git --extra-experimental-features "nix-command flakes"
git clone https://git.pleunetowne.com/mitchpleune/nixflakes.git && cd nixflakes
sudo nixos-rebuild switch --flake .#wsl
```

Then from a new tab, confirm that NixOS still works with `nixos -d nixos -u mitch`. If so, restart WSL

```powershell
wsl --shutdown
```

Then Re-open your nix tab, and transfer the repo over to the new user directory

```bash
sudo mv /home/nixos/nixflakes .
sudo chown -R $USER:users nixflakes/
sudo rm -rf /home/nixos
```

## Running custom Neovim
```bash
nix run git+https://git.pleunetowne.com/mitchpleune/nixflakes.git#mitchvim
```

## Deploy to all nix homelab components
```bash
# optional update
nix flake update

# builds and deploys to every nix host
nix develop . -c deploy
```
