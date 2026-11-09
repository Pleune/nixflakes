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
nix run git+https://git.pleunetowne.com/mitchpleune/nixflakes.git#mitchvim --option substituters "https://nix.pleunetowne.com/?trusted=1"
```

## Agent sandbox

`agent-sandbox` runs an executable with Pi's shared development-sandbox policy:

```bash
agent-sandbox some-command --some-option 'an argument'
agent-sandbox bash -c 'some-command | another-command'
```

Arguments are forwarded unchanged, not interpreted as shell syntax. Aliases,
functions, pipelines, and redirections require an explicit shell. This does not
provide sudo-style privilege escalation. No command exits with status 64; a
missing executable exits with 127 and a non-executable command with 126. Sandbox
setup errors fail closed, without running the command on the host.

The prefix command is installed alongside Pi by the Home Manager configuration.
With this flake's overlay, packages can also be sandboxed at installation time:

```nix
# NixOS
environment.systemPackages = [
  pkgs.agent-sandbox
  (pkgs.agent-sandbox.wrap pkgs.some-package)
];

# Home Manager
home.packages = [ (pkgs.agent-sandbox.wrap pkgs.some-package) ];
```

The wrapped package retains every executable name in its selected `bin` output,
including executable symlink aliases. Each entry invokes the original executable
by absolute path inside the sandbox. Non-bin assets and the usual profile outputs
are projected into the wrapper; metadata such as `mainProgram` is retained.
Separate non-bin output attributes remain accessible. Packages without executable
files in the selected bin output fail the build with an explanatory error.
Use `wrapped.unwrapped` to access the original package. `wrapped.override` applies
to the original package and rewraps it; `wrapped.overrideAttrs` adjusts the wrapper
itself (customize the original before wrapping to change its build).

The policy keeps cwd writable, provides an ephemeral `/tmp/pi-home` and XDG
folders, filters PATH/environment, and shares networking. It forwards the existing
`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GOOGLE_API_KEY`, `MISTRAL_API_KEY`,
`DEEPSEEK_API_KEY`, and `XAI_API_KEY` allowlist. Pi-specific state mounts and the RTK
PATH addition are **not** added by the generic launcher. The underlying jail
builder may cache generated passwd/group files in host `~/.local/share/jail.nix`
during setup; command HOME itself remains ephemeral. Nix-profile executable
paths are resolved; PATH directories resolving inside the host home are dropped.
As with Pi, the jail builder supplies coreutils ahead of the caller's PATH.

This is a permissive development sandbox, **not a hermetic secret boundary**:
much of the host filesystem (including the Nix store) is readable, the network is
available, and starting in a home directory exposes that cwd read-write. Do not
start it in your entire home directory when you want home isolation. Desktop
entries and service launchers are not rewritten; direct original store paths
remain usable outside the sandbox. GUI programs and commands needing additional
credentials, host sockets, or persistent state may not work with this policy.

Build just the launcher without activating Home Manager:

```bash
nix build --no-link .#legacyPackages.x86_64-linux.agent-sandbox
```

The build-time layout checks and host-side runtime checks can be run separately:

```bash
nix build --no-link .#legacyPackages.x86_64-linux.agent-sandbox.tests.layout
sandbox=$(nix build --no-link --print-out-paths .#legacyPackages.x86_64-linux.agent-sandbox)
fixture=$(nix build --no-link --print-out-paths .#legacyPackages.x86_64-linux.agent-sandbox.tests.fixture)
bash=$(nix eval --raw .#legacyPackages.x86_64-linux.runtimeShell)
python3 pkgs/agent-sandbox/test.py "$sandbox" "$fixture" "$bash"
```

Runtime tests require working Bubblewrap/user namespaces and should be launched
from the repository, not from all of HOME.

## Deploy to all nix homelab components
```bash
# optional update
nix flake update

# builds and deploys to every nix host
nix develop . -c deploy
```

## Errata
`nix build --rebuild nixpkgs#gitMinimal` tests sometimes randomly fail on ZFS. higher disk priority and higher ulimit seems to help, but does not fix it.

## TODO

- Change VMs to be very swappy since most times swap will be ram-compressed-cached and very fast

# Notes

If font is broken after an update:
```bash
rm -r ~/.cache/fontconfig
fc-cache -vr
```
