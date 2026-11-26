# The Hermes agent's execution host: a NixOS guest on ai, reachable over ssh.
# It is also the build machine for ai's own system, so its store holds most of the closure and
# ai's root filesystem stays small.
{ config, inputs, lib, pkgs, ... }:
with lib;
let
  # The guest's outbound identity is the single ai <-> buildvm keypair, grafted into ~builder/.ssh by
  # buildvm-install (modules/nixos/virtualisation/buildvm/default.nix), so the guest authenticates to the
  # git host with the identity ai holds the private half of.  Only the public half belongs in this
  # closure: `private` is a plain flake input, so reading the `.pub` reads a fetched path rather than a
  # derivation and adds no IFD.  platforms/ai.nix spells the same value, and the lock file must point at
  # a revision that contains the file.
  firstLine = text: builtins.elemAt (builtins.match "([^\r\n]+)[\r\n]*" text) 0;
  publicKey = firstLine (builtins.readFile "${inputs.private.secrets}/ai_buildvm_id_ed25519.pub");

  # Must match the name the seed image creates in platforms/buildvm-bootstrap.nix: buildvm-install only
  # grafts the guest's ssh files once that user exists.
  userName = "builder";
in
{
  options = {
    nixflakes.buildvm.diskImage = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Bootable raw disk image (GPT partition table + systemd-boot on its ESP) for the guest
        partition, for reseeding it by hand.  ai installs the seed image instead
        (platforms/buildvm-bootstrap.nix), and the guest grows its own root partition on boot, so
        nothing resizes this image on the host.
      '';
    };

    nixflakes.buildvm.desktop = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Install Xvnc + Xfce + a browser.  bot_desktop runs inside this guest
        (services.hermes-agent.settings.bot_desktop.placement = "auto" on ai) and Hermes cannot
        install anything on NixOS: it only checks for these binaries, and its package map covers
        apt/dnf/pacman only (hermes tools/bot_desktop/runtime.py REQUIRED_BINARIES).
      '';
    };
  };

  config = {
    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

    networking.hostName = "buildvm";

    # ── Build memory ────────────────────────────────────────────────────────────────────
    # The VM is ai's build machine, and a hermes-agent dependency build (node, ffmpeg,
    # onnxruntime) OOM-killed the builder at 7.7 GiB RAM with no swap.  zram gives compressed
    # in-RAM swap (~3x effective capacity on this workload), and limiting jobs caps how many
    # compilers run concurrently, which is what actually blew past the limit.
    # (Re-applied: this block fell out of main during a history rewrite once; `checks`'s
    # buildvm-guest-boot asserts it so it cannot silently vanish again.)
    zramSwap.enable = true;
    nix.settings.max-jobs = 2;
    nix.settings.cores = 2;

    # ── Networking: static addressing on qemu's NAT ────────────────────────────────────
    # `buildvm.service` gives the guest a virtio NIC on qemu's user-mode network and pins the subnet it
    # NATs (`net=10.0.2.0/24`, `host=10.0.2.2`, `dns=10.0.2.3`, `dhcpstart=10.0.2.15`).  The guest is
    # configured to match rather than left to DHCP: this qemu's defaults hand out 240.0.0.1/24 with no
    # default route and no resolver, and a guest with no route cannot fetch nixpkgs or the git host.
    # Change the qemu arguments in modules/nixos/virtualisation/buildvm and these values together.
    #
    # Static addresses need a manager.  With `useNetworkd = false` this falls to nixpkgs' scripted path
    # and `useDHCP = false` means nothing runs at all: the interface comes up with no address, and
    # `ssh -p 2224` hangs after `Connection established` because libslirp forwards to a guest nobody can
    # reach.
    networking.useNetworkd = true;
    networking.useDHCP = false;

    # Matched by MAC on purpose: predictable interface names are not stable across generations of this VM
    # (`ens3` one boot, `enp0s3` the next) and a name-based unit that stops matching fails silently --
    # card `state DOWN`, no address, while `nc -z 127.0.0.1 2224` still reports the port open.
    # Mirrors `nixflakes.virtualisation.buildvm.netGuestMac`, which qemu pins.
    systemd.network.networks."40-buildvm-nat" = {
      matchConfig.MACAddress = "52:54:00:12:34:56";

      networkConfig = {
        DHCP = "no";
        # qemu's NAT gateway and its built-in resolver, which forwards to ai's resolver.  Both are set here
        # rather than through `networking.defaultGateway`/`networking.nameservers` because those are
        # keyed on interface *names*, which is exactly what cannot be relied on.
        Gateway = "10.0.2.2";
        DNS = "10.0.2.3";
      };

      # qemu hands this address out over DHCP; taking it statically does not depend on libslirp's pool.
      address = [ "10.0.2.15/24" ];
    };

    # The guest boots its own disk: qemu gets no -kernel/-initrd/-append, so the loader has to live
    # in the image and `nixos-rebuild switch` inside the guest has to be able to reinstall it.
    system.switch.enable = true;
    # The kernel's EFI stub is what OVMF boots, and systemd-boot is the loader on the ESP.
    boot.loader.grub.enable = false;
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;
    boot.loader.systemd-boot.configurationLimit = 4;

    # The image's root partition is a few GiB; the disk it lands on is 1.82 TiB.  `boot.growPartition`
    # only grows the *partition* (it installs `systemd.services.growpart`, which runs growpart on
    # root's device).  The filesystem is grown by `systemd-growfs-root.service`, and that unit exists
    # only when the fstab entry carries `x-systemd.growfs`, which `autoResize` below is what adds.
    # Without it the partition reaches 1.82 TiB while ext4 stays at the image's few GiB and the guest
    # dies mid-build with `error: write of N bytes: No space left on device`.
    boot.growPartition = true;

    # Serial console because qemu runs -nographic; rd.shell=1 so a boot failure reaches this console
    # instead of timing out a device job in silence.
    boot.kernelParams = [ "console=ttyS0" "rd.shell=1" "panic=0" ];

    # The initrd must have virtio and ext4 before it can mount root.  The ESP is vfat but it is not
    # needed for boot, so systemd mounts /boot after switch root, where modprobe can load vfat from
    # the store.
    boot.initrd.kernelModules = [ "virtio_pci" "virtio_blk" "ext4" ];

    # Name root by the ext4 label make-disk-image writes (mkfs.ext4 -L buildvm) rather than
    # /dev/vda: systemd-fstab-generator writes sysroot.mount from the kernel root= line *before* it
    # reads the initrd fstab, so a second definition of the same node makes the generator fail with
    # "Failed to create unit file ... as it already exists" and the guest drops into Emergency Mode.
    fileSystems."/" = {
      device = "/dev/disk/by-label/buildvm";
      fsType = "ext4";
      # Grows ext4 into the partition boot.growPartition enlarged.  ext4 is resizable, so the
      # `autoResize = true is not supported for this fsType` assertion cannot fire here.
      autoResize = true;
    };

    # The ESP systemd-boot lives on, labelled ESP by make-disk-image.
    fileSystems."/boot" = { device = "/dev/disk/by-label/ESP"; fsType = "vfat"; noCheck = true; };

    # Skip the repo's default user: no password login, no home-manager in a build VM.
    nixflakes.makeUser = false;

    users.users.${userName} = {
      isNormalUser = true;
      # The user manager must run without a login: switch-to-configuration reloads user units for
      # every user with /run/user/<uid>, and a dead manager fails the whole guest switch with
      # status 4 (NOPERMISSION).  Lingering also keeps desktop units alive across ssh churn.
      linger = true;
      shell = pkgs.bash;
      home = "/home/${userName}";
      # In wheel for nix trust only: `config/nixos/core/nix` makes @wheel a nix trusted user, which the
      # in-guest flake switch needs.  There is deliberately no sudo here (see below), so this group
      # grants no privileges beyond nix.
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keys = lib.optionals (publicKey != "") [ publicKey ];
    };

    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        # Key-only root login.  buildvm-install grafts the provisioning key into /root/.ssh, and the
        # switch that makes this guest what it is arrives as root over ssh
        # (modules/nixos/virtualisation/buildvm -> buildvm-provision.service).
        PermitRootLogin = "prohibit-password";
      };
    };

    # The guest user has no sudo: it has no password, so nixpkgs' wheel rule fails rather than falling
    # back to the password-less `%wheel` rule.  Root work arrives over ssh as root, which keeps one
    # auditable path instead of a passwordless root shell for the builder user.
    security.sudo.extraConfig = ''
      Defaults !lecture
    '';

    nixflakes.buildvm.diskImage = import "${inputs.nixpkgs}/nixos/lib/make-disk-image.nix" {
      inherit pkgs config lib;
      name = "buildvm-disk";
      label = "buildvm";
      format = "raw";
      # GPT with an ESP and an ext4 root, matching the loader above; root is the partition
      # boot.growPartition grows.
      partitionTableType = "efi";
      touchEFIVars = true;
      fsType = "ext4";
      # The partition is ~1.7 TiB; the image only needs the store plus headroom, and the guest
      # grows into the rest on its first boot.
      diskSize = "auto";
      additionalSpace = "4G";
      bootSize = "512M";
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
      # computer_use's MCP driver: Hermes spawns `cua-driver mcp` *inside this guest* over the
      # ssh exec channel (`bot_desktop.placement = "auto"` + ssh backend resolves to terminal
      # placement, hermes services/bot_desktop/placement.py), so the binary has to be on the
      # guest's PATH.  Its absence was the whole computer_use failure: the spawn died with a
      # FileNotFoundError wrapped by the MCP client's TaskGroup into "unhandled errors in a
      # TaskGroup (1 sub-exception)".
      #
      # callPackage'd here rather than overlaid: overlay.nix is outside the deploy-ai gate's
      # allowlist, and only the guest needs this package.
      (callPackage ../pkgs/cua-driver { })
    ]);

    nix.gc = {
      automatic = true;
      dates = "daily";
      options = "--delete-older-than 14d";
    };

    # /tmp here is disk-backed, so scratch state survives a reboot while everything that wrote it
    # (Xvnc :20, browsers, Hermes' bot-desktop screen env) died with the old boot.  The one that
    # bit us: sandbox_host.start() *adopts* a published /tmp/hermes-bot-desktop/<profile>/env
    # DISPLAY without probing that an X server answers it, so after every reboot computer_use
    # spawned cua-driver against a dead display ("no DISPLAY is set").  Wiping /tmp wholesale at
    # boot (systemd's `D! /tmp` rule) makes start() always bring a fresh screen up and takes every
    # other boot-stale scratch file with it.  Runtime /tmp use is untouched — the wipe is boot-only.
    # (The gateway restart case is unaffected: no reboot, the live screen is adopted as designed.)
    boot.tmp.cleanOnBoot = true;

    # Keep build logs from filling the guest disk.
    services.journald.settings.Journal = {
      SystemMaxUse = "512M";
      RuntimeMaxUse = "128M";
    };

    # NixOS VM tests share this host's /nix/store over virtiofs.  virtiofsd is started by the
    # test VM's run script with the fd limits it inherits from the build, but the tests wrap
    # virtiofsd with `--inode-file-handles` so its held-fd count stays far below the default
    # pool no matter how large the store is -- no LimitNOFILE bump is needed here.
    # (Do NOT raise the daemon's LimitNOFILE instead: virtiofsd would then hold one O_PATH fd
    # per shared inode until FUSE FORGET, parking ~100k fds for a single nixpkgs eval.)

    # Hermes' sandbox browser probe (tools/bot_desktop/sandbox_host.py `_CHROMIUM_PROBE`) only
    # accepts a Playwright folder layout ($PLAYWRIGHT_BROWSERS_PATH / /opt/playwright /
    # ~/.cache/ms-playwright), which NixOS never ships.  Pointing that layout at the system
    # Chromium declaratively means the probe passes from first boot — no runtime shim that a guest
    # rebuild would erase — and it runs as any user since /opt is world-readable.
    systemd.tmpfiles.rules = lib.optionals config.nixflakes.buildvm.desktop [
      "d /opt/playwright/chromium-1/chrome-linux64 0755 root root -"
      "L /opt/playwright/chromium-1/chrome-linux64/chrome - - - - ${pkgs.chromium}/bin/chromium"
    ];

    # A browser the agent can drive: browser_exec on ai attaches over CDP to the Chromium here.
    # The bot-desktop display (:20) belongs to the gateway and appears and disappears with its
    # session, so this browser gets its own Xvnc on :21 (VNC viewers reach it through ai at
    # 127.0.0.1:5921; nothing listens on the LAN).  The debug port needs a dedicated user-data-dir:
    # Chrome 136+ silently ignores --remote-debugging-port on the default profile.
    systemd.services.bot-xvnc = lib.optionalAttrs config.nixflakes.buildvm.desktop {
      description = "Xvnc :21 for the agent-driven browser";
      wantedBy = [ "multi-user.target" ];
      # Restart=always loops until Xvnc is up; with the default start-limit a unit that once hit
      # start-limit-hit stays refused until reset-failed, which nothing here ever calls.
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = {
        Type = "simple";
        User = userName;
        # Xvnc binds its VNC socket and writes Xauthority under /run, so the runtime dir is the
        # one it needs; StateDirectory would only create /var/lib/bot-browser.
        RuntimeDirectory = "bot-browser";
        ExecStart = ''
          ${pkgs.tigervnc}/bin/Xvnc :21 -geometry 1440x900 -depth 24 \
            -rfbport 5921 -rfbunixpath /run/bot-browser/vnc.sock -rfbunixmode 0600 \
            -SecurityTypes None -AlwaysShared -AcceptSetDesktopSize \
            -desktop agent-browser -auth /run/bot-browser/Xauthority -nolisten tcp
        '';
        Restart = "always";
      };
    };

    systemd.services.chromium-cdp = lib.optionalAttrs config.nixflakes.buildvm.desktop {
      description = "Chromium on :21 with CDP on 9222 (forwarded to ai at 127.0.0.1:9225)";
      wantedBy = [ "multi-user.target" ];
      after = [ "bot-xvnc.service" ];
      unitConfig.StartLimitIntervalSec = 0;  # same reasoning as bot-xvnc
      serviceConfig = {
        Type = "simple";
        User = userName;
        StateDirectory = "bot-browser";  # --user-data-dir lives under /var/lib/bot-browser
        Environment = "DISPLAY=:21 XAUTHORITY=/run/bot-browser/Xauthority";
        # The guest kernel keeps user namespaces unprivileged-off, so the wrapper needs --no-sandbox
        # (the bot-desktop launches the same way).
        ExecStart = ''
          ${pkgs.chromium}/bin/chromium --no-sandbox --new-window \
            --remote-debugging-port=9222 --user-data-dir=/var/lib/bot-browser/profile \
            --no-first-run --no-default-browser-check
        '';
        Restart = "always";
      };
    };

    # Chrome binds DevTools to 127.0.0.1 only (the --remote-debugging-address flag is ignored by
    # modern builds), but qemu's `hostfwd=tcp:127.0.0.1:9225-:9222` dials the guest's real IP
    # (10.0.2.15), where nothing listens -- the host's 9225 therefore accepts the TCP handshake and
    # hangs, and browser_exec's daemon times out attaching.  Relay the guest-IP port to loopback so
    # the existing hostfwd lands on Chrome.
    systemd.services.chromium-cdp-relay = lib.optionalAttrs config.nixflakes.buildvm.desktop {
      description = "Bridge guest-IP :9222 to Chromium's loopback CDP so qemu's 9225 hostfwd lands";
      wantedBy = [ "multi-user.target" ];
      after = [ "chromium-cdp.service" ];
      unitConfig.StartLimitIntervalSec = 0;  # same reasoning as chromium-cdp
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.socat}/bin/socat TCP-LISTEN:9222,bind=10.0.2.15,fork,reuseaddr TCP:127.0.0.1:9222";
        Restart = "always";
      };
    };

    system.stateVersion = "25.05";
  };
}
