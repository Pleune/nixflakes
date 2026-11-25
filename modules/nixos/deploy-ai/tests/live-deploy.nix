{ testers, pkgs, inputs }:

# End-to-end deploy inside one VM.  The gate node is also its own build host — ai reaches the
# build VM over `127.0.0.1:2224`, and that is exactly where a node can ssh to itself — so
# `--repo`, `--submit`, the nix build, the switch, the boot pin, the health wait, and the
# rollback of a switch-that-activates-but-dies all execute for real, on a real systemd-boot.
# The unit suite stubs every one of these; this check is what proves the orchestration converges
# a system instead of just calling the right helpers.  Needs qemu + KVM like the other VM checks.

let
  # The mini flake's nixpkgs input resolves through the committed lock (see miniFlake).  If the
  # pkgs pin moves, update both values below (`nix hash path $(nix eval --raw
  # '.#legacyPackages.x86_64-linux.path')` and the basename).
  nixpkgsRefHash = "sha256-ziZn2PvCJE5JEEpqTdxXwJpPB+L3YqoCpTAMCzyaP3U=";
  nixpkgsStoreName = baseNameOf pkgs.path;

  fakeApi = pkgs.writeText "fake-api.py" ''
    import http.server

    class Ok(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")

        def log_message(self, *args):
            pass

    http.server.HTTPServer(("127.0.0.1", 8642), Ok).serve_forever()
  '';

  # The tree the mini repo holds, and the same tree kept as ai's baseline (what submits patch
  # against and what the policy digest is computed from).  It is fully self-contained and needs
  # no network: its nixpkgs input resolves through the committed lock, the gate module +
  # package are vendored into `vendor/`, and the pinned nixpkgs source is in the VM's store.
  miniFlake = pkgs.writeText "mini-flake.nix" ''
    {
      # Resolved through the committed flake.lock (whose `original` byte-matches this URL, so
      # nix reads the locked entry instead of re-fetching; the lock carries a narHash validated
      # against the VM's registered paths, so nothing re-hashes the tree).
      inputs.nixpkgs.url = "${pkgs.path}";

      outputs = { self, nixpkgs }:
        let
          pkgs = import nixpkgs {
            system = "x86_64-linux";
            overlays = [
              (final: prev: { deploy-ai = prev.callPackage ./vendor/deploy-ai { }; })
            ];
          };
        in {
          nixosConfigurations.ai = nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            inherit pkgs;
            specialArgs = { deployedSrc = self; };
            modules =
              [ ./system.nix (nixpkgs + "/nixos/modules/testing/test-instrumentation.nix") ];
            # The candidate must keep the harness backdoor console shell: without it the switch
            # stops backdoor.service, and every later gate command hangs on the dead shell.
          };
        };
    }
  '';

  miniSystem = pkgs.writeText "mini-system.nix" ''
    { pkgs, lib, deployedSrc, ... }:
    {
      imports = [
        ./vendor/modules/nixos/deploy-ai/default.nix
        ./vendor/modules/nixos/virtualisation/buildvm/default.nix
      ];

      boot.loader.grub.enable = false;
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = false;
      # switch-to-configuration-ng compares the running /etc/fstab against the candidate
      # toplevel's byte-for-byte and reloads busy harness store mounts on any difference,
      # which aborts activation.  The gate node forces its /etc/fstab to THIS config's
      # generated fstab (see `candidateCfg` in the test file), so these entries only need to
      # be functionally correct — mount devices/types/overlay paths — not hand-mirrored to
      # the harness's merged mount options.
      fileSystems."/" = {
        device = "/dev/disk/by-label/nixos";
        fsType = "ext4";
      };
      fileSystems."/boot" = {
        # The real ESP partition of the harness's GPT disk (label ESP, FAT32).  tmpfs was the
        # test's blind spot: switch activations remount tmpfs (sysinit-reactivation restarts
        # mount units) and wipe loader entries, so boot-pin bugs the real disk-backed /boot
        # would expose never showed up.  noCheck keeps systemd-fsck (no fsck binary on this
        # minimal system's PATH) from being pulled into boot.mount's chain.
        device = "/dev/disk/by-label/ESP";
        fsType = "vfat";
        noCheck = true;
      };
      fileSystems."/nix/.ro-store" = {
        device = "nix-store";
        fsType = "virtiofs";
        options = [ "ro" ];
      };
      fileSystems."/nix/.rw-store" = {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [ "mode=0755" ];
      };
      # The harness mounts the store as an overlay over its virtiofs/tmfs shares; the
      # candidate must describe the same mount (stage1 paths) so its fstab stays mountable.
      fileSystems."/nix/store" = {
        device = "overlay";
        fsType = "overlay";
        options = [
          "lowerdir=/sysroot/nix/.ro-store"
          "upperdir=/sysroot/nix/.rw-store/upper"
          "workdir=/sysroot/nix/.rw-store/work"
        ];
      };
      fileSystems."/tmp/shared" = {
        device = "shared";
        fsType = "virtiofs";
      };
      fileSystems."/tmp/xchg" = {
        device = "xchg";
        fsType = "virtiofs";
      };

      nix.settings.experimental-features = [ "nix-command" "flakes" ];
      environment.systemPackages = with pkgs; [ git openssh python3 ];
      environment.etc."deploy-marker".text = "gen-1\n";

      users.users.builder = { isNormalUser = true; };

      # The gate sshes into the build host as `builder` over this port (health probe, guest
      # row, guest convergence); on ai that is qemu's forward into the VM, here it is loopback.
      services.openssh = {
        enable = true;
        settings.Port = 2224;
        settings.HostKey = "/run/secrets/ssh/host_ed25519";
      };
      # The VM image has no ssh host keys; mint one at boot (sshd-keygen races the overlay).
      systemd.services.ssh-hostkeys = {
        requiredBy = [ "sshd.service" ];
        before = [ "sshd.service" ];
        path = with pkgs; [ openssh ];
        serviceConfig = { Type = "oneshot"; };
        script = "install -d /run/secrets/ssh && [ -f /run/secrets/ssh/host_ed25519 ] || ssh-keygen -q -t ed25519 -N \"\" -f /run/secrets/ssh/host_ed25519";
      };

      systemd.services.fake-api = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${fakeApi}";
      };

      nixflakes.deploy-ai = {
        enable = true;
        # Baseline tree for submit diffs: the flake's own tree, copied to the store
        # during evaluation (allowed in pure mode).  The switch tail overwrites the
        # record files with the actual built toplevel and git commit anyway.
        deployedSource = deployedSrc;
        deployedCommit = "live-deploy-1";
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP0000000000000000000000000000000000000000 live-deploy-test";
        submit.enable = true;
        allowlist = [ "flake.nix" "system.nix" ];
        buildKey = "/run/deploy-test/id_ed25519";
        healthUnits = [ "fake-api.service" "sshd.service" ];
        healthUrl = "http://127.0.0.1:8642/health";
        trustedSources = [ { repo = "/srv/mini"; ref = "main"; } ];
      };
    }
  '';

  # Production's repo carries a committed flake.lock, so a deploy never re-hashes the nixpkgs
  # tree.  The mini tree must too, and the lock's `original` must byte-match the flake URL or
  # nix re-resolves.  The locked entry NEEDS its narHash: nix classifies a hashless path-type
  # entry as an "unlocked input" and refuses it outright (`--allow-dirty-locks` does not
  # actually bypass that check in nix 2.35).  With the correct hash and the path registered in
  # the guest's Nix DB (additionalPaths), validation reads the DB -- zero re-hashing, verified
  # 0.03s against the host and near-zero through virtiofs.
  miniLock = pkgs.runCommand "mini-lock" {} ''
    cat > $out <<EOF
{"nodes":{"root":{"inputs":{"nixpkgs":"nixpkgs"}},"nixpkgs":{"locked":{"lastModified":1790000000,"narHash":"${nixpkgsRefHash}","path":"/nix/store/${nixpkgsStoreName}","type":"path"},"original":{"path":"${pkgs.path}","type":"path"}}},"root":"root","version":7}
EOF
  '';
  miniTree = pkgs.runCommand "mini-tree" {} ''
    mkdir -p $out/vendor/modules/nixos/deploy-ai $out/vendor/modules/nixos/virtualisation/buildvm
    cp ${miniFlake} $out/flake.nix
    cp ${miniLock} $out/flake.lock
    cp ${miniSystem} $out/system.nix
    cp -r ${../../../../pkgs/deploy-ai} $out/vendor/deploy-ai
    chmod -R u+w $out/vendor/deploy-ai
    rm -rf $out/vendor/deploy-ai/__pycache__ $out/vendor/deploy-ai/tests
    cp ${../default.nix} $out/vendor/modules/nixos/deploy-ai/default.nix
    # The candidate's deploy module needs only the buildvm *options* the policy digest reads;
    # the test-options stub supplies them without the real buildvm module's host machinery.
    cp ${./test-options.nix} $out/vendor/modules/nixos/virtualisation/buildvm/default.nix
  '';
  miniBaseline = miniTree;
  miniRepo = miniTree;

  # Evaluate the exact candidate config (same modules, same pkgs, same specialArgs shape as the
  # mini flake) at test-evaluation time.  The gate node forces its own /etc/fstab to this
  # config's generated fstab: switch-to-configuration-ng diffs the running /etc/fstab against
  # the candidate toplevel's byte-for-byte and reloads busy harness store mounts on any
  # difference, which aborts activation.  Deriving the node's fstab from the candidate itself
  # makes the comparison identical by construction instead of by hand-mirrored mount options.
  candidateCfg = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    pkgs = import pkgs.path {
      system = "x86_64-linux";
      overlays = [
        (final: prev: { deploy-ai = prev.callPackage (miniTree + /vendor/deploy-ai) { }; })
      ];
    };
    specialArgs = { deployedSrc = miniTree; };
    modules =
      [ (miniTree + "/system.nix") (pkgs.path + "/nixos/modules/testing/test-instrumentation.nix") ];
  };

  # The host store is shared with the VM over virtiofs (see the gate node config), so the
  # guest's deploy build is a cache hit for everything already in the store.  Build-time-only
  # inputs (source tarballs, patches, stdenv build deps) are NOT runtime references and still
  # need fetching -- the guest substitutes those from cache.nixos.org over slirp, exactly like
  # the real `ai` does.  slirp forwards IPv4 only, while cache.nixos.org resolves IPv6-only on
  # this host, so pin an A record via static hosts (Fastly anycast, stable; verified reachable
  # from this host).
in
testers.nixosTest {
  name = "deploy-ai-live-deploy";
  globalTimeout = 3600;

  nodes.gate = { pkgs, ... }: {
    imports = [
      ../default.nix
      ./test-options.nix
    ];

    boot.loader.grub.enable = false;
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = false;
    # The test harness mkVMOverride's `fileSystems` from `virtualisation.fileSystems`, so the
    # ESP must be declared on the virtualisation side for the node.  `useBootLoader` + `useEFIBoot`
    # switch the harness image from a partitionless root to a real GPT disk with a FAT32 ESP
    # (label ESP), run the real systemd-boot installer during image build, and boot the VM through
    # OVMF and that loader — exactly the disk-backed ESP the ai host has.  Entries the installer
    # writes survive switch activations, the property tmpfs lacked.
    virtualisation.useBootLoader = true;
    virtualisation.useEFIBoot = true;
    virtualisation.fileSystems."/boot" = {
      device = "/dev/disk/by-label/ESP";
      fsType = "vfat";
      noCheck = true;
    };
    virtualisation.memorySize = 4096;
    virtualisation.diskSize = 8192;

    # The host Nix store is shared with the VM over virtiofs (the harness default).  Sharing
    # makes everything the host already built a cache hit for the guest -- same store, same
    # derivation hashes, no image baking and no host/guest eval-matching gymnastics.  The catch
    # is virtiofsd's default inode handling: one O_PATH fd per guest inode, held until FUSE
    # FORGET, so a nixpkgs eval (~55k files) drains the inherited ~40k fd pool (ENFILE).  The
    # fix is file handles, not a bigger pool: virtiofsd 1.14 references inodes via
    # --inode-file-handles, keeping the fd count low regardless of tree size, but obtaining a
    # handle needs CAP_DAC_READ_SEARCH -- which means virtiofsd must run as ROOT.  The harness
    # starts it from the test derivation's build, so run that derivation as root:
    #   nix build --option sandbox false --option build-users-group '' .#checks...
    # (sandbox=none keeps the harness's own caps intact; empty build-users-group stops nix
    # demoting the build to nixbld1, which has no caps and silently loses file handles.)
    # host.pkgs wraps the virtiofsd that the VM run script spawns via run-virtiofsd-qemu;
    # nixpkgs' own hard-coded `never` sites pass their flag last, so their behaviour is
    # unchanged.
    virtualisation.mountHostNixStore = pkgs.lib.mkForce true;
    virtualisation.writableStore = true;
    virtualisation.host.pkgs = pkgs.lib.mkForce (pkgs.extend (final: prev: {
      virtiofsd = prev.writeShellScriptBin "virtiofsd" ''
        exec ${prev.virtiofsd}/bin/virtiofsd --inode-file-handles=prefer "$@"
      '';
    }));
    # A shared store shows every host path to the guest, but only additionalPaths closures are
    # registered in the guest's Nix DB -- registration is what makes the deploy build a cache
    # hit and lets the mini lock resolve `nixpkgs` to a registered path.
    virtualisation.additionalPaths = [
      "${pkgs.path}"
      candidateCfg.config.system.build.toplevel
    ];

    # Build-time substitute fetches go to cache.nixos.org through the harness slirp network.
    # slirp's DNS only forwards A queries usefully (cache.nixos.org is AAAA-only from the host
    # resolver), so pin an IPv4 anycast address; slirp itself forwards IPv4 TCP to the internet.
    networking.nameservers = [ "10.0.2.3" ];
    networking.hosts."151.101.65.91" = [ "cache.nixos.org" ];

    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    environment.systemPackages = with pkgs; [ git openssh python3 ];

    users.users.builder = { isNormalUser = true; };

    services.openssh = {
      enable = true;
      settings.Port = 2224;
      settings.HostKey = "/run/secrets/ssh/host_ed25519";
    };
    systemd.services.ssh-hostkeys = {
      requiredBy = [ "sshd.service" ];
      before = [ "sshd.service" ];
      path = with pkgs; [ openssh ];
      serviceConfig = { Type = "oneshot"; };
      script = "install -d /run/secrets/ssh && [ -f /run/secrets/ssh/host_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -f /run/secrets/ssh/host_ed25519";
    };

    systemd.services.fake-api = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${fakeApi}";
    };

    nixflakes.deploy-ai = {
      enable = true;
      deployedSource = miniBaseline;
      deployedCommit = "live-deploy-1";
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP0000000000000000000000000000000000000000 live-deploy-test";
      submit.enable = true;
      allowlist = [ "flake.nix" "system.nix" ];
      buildKey = "/run/deploy-test/id_ed25519";
      healthUnits = [ "fake-api.service" "sshd.service" ];
      healthUrl = "http://127.0.0.1:8642/health";
      trustedSources = [ { repo = "/srv/mini"; ref = "main"; } ];
    };

    # Byte-identical to the candidate toplevel's fstab (same evaluated config), so
    # switch-to-configuration-ng sees zero fstab drift and never remounts the busy harness
    # store mounts.  Stage1 boot mounts come from the node's own `fileSystems` (untouched);
    # this only replaces the userspace /etc/fstab the switcher compares against.
    environment.etc."fstab".text = pkgs.lib.mkForce candidateCfg.config.environment.etc."fstab".text;
  };

  testScript = ''
    GATE = "/run/current-system/sw/bin/deploy-ai"

    # The store-share virtiofsd runs on the DRIVER host (spawned by the node's qemu run script
    # via run-virtiofsd-qemu) and inherits the build environment's ~40k fd limit.  With
    # --inode-file-handles=prefer (see the gate node's host.pkgs wrapper) its held-fd count
    # stays small no matter how large the shared store is; without it, a nixpkgs eval parks
    # one O_PATH fd per inode until the pool dies (ENFILE at 0/40350).  The monitor tracks the
    # peak across all virtiofsd processes and the v1 flow asserts it stayed low.
    import os, threading, time, resource
    _vfs = {"limit": resource.getrlimit(resource.RLIMIT_NOFILE), "peak": 0}
    def _is_vfs(d):
        try:
            with open("/proc/%s/cmdline" % d) as f:
                return "virtiofsd" in f.read()
        except OSError:
            return False
    def _vfsmon():
        while True:
            tot = 0
            try:
                pids = [d for d in os.listdir("/proc") if _is_vfs(d)]
                for pid in pids:
                    try:
                        tot += len(os.listdir("/proc/%s/fd" % pid))
                    except OSError:
                        pass
            except Exception:
                pass
            _vfs["peak"] = max(_vfs["peak"], tot)
            time.sleep(1)
    threading.Thread(target=_vfsmon, daemon=True).start()

    gate.start()
    gate.wait_for_unit("multi-user.target")
    # The EFI harness image carries the real installer's output (profile link + loader entries),
    # so normally nothing needs seeding.  Keep the fallback: install-bootloader refuses to run
    # with zero generations ("refusing to remove all boot loader entries").
    gate.succeed(
        "test -e /nix/var/nix/profiles/system"
        " || (mkdir -p /nix/var/nix/profiles"
        " && ln -sfn /run/current-system /nix/var/nix/profiles/system-1"
        " && ln -sfn system-1 /nix/var/nix/profiles/system)")
    gate.succeed(
        "(ls -ld /var /var/empty 2>&1; mount | grep boot; systemctl status systemd-tmpfiles-setup --no-pager -l 2>&1 | tail -12)"
        " | tee /dev/kmsg; true")
    gate.execute("echo filenr=$(cat /proc/sys/fs/file-nr) soft=$(ulimit -n) hard=$(ulimit -Hn)")
    gate.wait_for_unit("fake-api.service")
    gate.wait_for_unit("sshd.service")

    # The gate's guest login key, and the key the fake build host accepts — the roles the
    # real ai/VM pair splits over slirp.
    gate.succeed(
        "install -d -m 700 /run/deploy-test"
        " && ssh-keygen -q -t ed25519 -N \"\" -f /run/deploy-test/id_ed25519"
        " && install -d -o builder -g users -m 700 /home/builder/.ssh"
        " && install -m 600 -o builder -g users /run/deploy-test/id_ed25519.pub /home/builder/.ssh/authorized_keys"
    )
    gate.wait_until_succeeds(
        "ssh -i /run/deploy-test/id_ed25519 -p 2224 -o BatchMode=yes"
        " -o StrictHostKeyChecking=accept-new builder@127.0.0.1 echo ok", 120)

    # systemd-boot's install refuses an unmounted /boot, so require the ESP mount up front.
    gate.succeed(
        "mountpoint -q /boot || { systemctl status boot.mount --no-pager -l >&2; ls -l /dev/disk/by-label >&2; false; }")

    # No planted entries: the gate's only boot entry must come from the real installer that
    # deploy-ai runs -- that path (link profile, `switch-to-configuration boot`) is exactly what
    # failed on the real ai after the `--no-link` build, and planting entries hid it.

    # The candidate closure and the pinned nixpkgs source are registered in the guest's Nix DB
    # (additionalPaths over the shared store), so the guest's deploy build is a cache hit with
    # zero fetches.  These two checks prove the registration landed.
    gate.succeed("nix path-info /nix/store/${nixpkgsStoreName} >/dev/null")
    gate.succeed("nix path-info ${candidateCfg.config.system.build.toplevel}/init >/dev/null")

    # v1: the trusted-route deploy.  A tip of the whitelisted repo builds for real, switches,
    # installs and pins its boot entry, and confirms health.
    gate.succeed(
        "install -d /srv/mini && cp ${miniRepo}/flake.nix ${miniRepo}/flake.lock ${miniRepo}/system.nix /srv/mini/ && cp -r ${miniRepo}/vendor /srv/mini/"
        " && cd /srv/mini && git init -q -b main && git add -A"
        " && git -c user.email=t@t.invalid -c user.name=t commit -qm base"
        " && git branch live-deploy-1"  # the node's deployRef must exist for the descendant check
    )
    # (An fdwatch nohup loop here was removed: same pitfall as the kmsg watcher -- the guest
    # has no `sleep`, so the loop busy-spun and starved the single-CPU VM, and backgrounding
    # from a guest command wedges the harness command channel.)
    deploy_rc, deploy1 = gate.execute("timeout 1500 deploy-ai --repo /srv/mini --ref main 2>&1", timeout=1800)
    # A real switch ends with `result: applied`; `result: ok` is only for --vet/--dry-run.
    if "result: applied" not in deploy1:
        # `gate.execute` stdout is captured, never echoed to the console, and the console runs
        # with `set -e` -- so dump everything through kmsg and let every step fail soft.
        diag = gate.succeed(
            "(echo DIAG_BEGIN;"
            " echo BUILD_LOG_BEGIN; tail -60 /var/lib/deploy-ai/log/build.log 2>&1 || true; echo BUILD_LOG_END;"
            " echo NET_BEGIN; ip addr 2>&1 | grep -E 'inet |eth' ; ip route 2>&1 | head -4 || true; echo NET_END;"
            " echo DNS_BEGIN; cat /etc/resolv.conf 2>&1 | grep -v '^#' | head -5; getent hosts cache.nixos.org || echo GETENT_FAIL;"
            " echo DNS_END;"
            " echo FETCH_TEST_BEGIN; curl -sS -m 10 -o /dev/null -w '%{http_code}\n' https://cache.nixos.org/nix-cache-info 2>&1 || true; echo FETCH_TEST_END;"
            " echo SUBSTITUTER_BEGIN; nix show-config 2>/dev/null | grep -i substitut || true; echo SUBSTITUTER_END;"
            " echo PATHS_BEGIN; ls -d /nix/store/*CVE-2026-55199* /nix/store/*glibc-2.44-57* 2>&1 || true; echo PATHS_END;"
            " true)",
            timeout=300,
        )
        raise Exception("first live deploy failed:\n" + deploy1 + "\nDIAG:\n" + diag + "\nvirtiofsd driver rlimit=%s peak host fds held=%s" % (_vfs["limit"], _vfs["peak"]))
    gate.succeed("grep -q gen-1 /etc/deploy-marker")
    # Proof the file-handle fix works: had virtiofsd fallen back to O_PATH fds, the nixpkgs
    # eval inside the v1 deploy would have parked its held-fd count in the tens of thousands
    # (the pool died at 40350).  With file handles it stays small regardless of store size.
    assert _vfs["peak"] < 20000, "virtiofsd held %d fds at peak -- file handles are not in use" % _vfs["peak"]
    print("virtiofsd peak fds: %d" % _vfs["peak"])
    gate.succeed(
        "test \"$(readlink -f /run/current-system)\" = \"$(cat /var/lib/deploy-ai/toplevel)\"")
    gate.succeed(
        "test \"$(cat /var/lib/deploy-ai/commit)\" = \"$(git -C /srv/mini rev-parse HEAD)\"")
    # The deployed-source record must be one clean store path: `deployedSource + "\n"` was
    # path concatenation in Nix and wrote a mangled path, so assert the shape, not just presence.
    gate.succeed("grep -qxE '/nix/store/[a-z0-9]+-[^/ ]+' /etc/deploy-ai/deployed-source")
    # After the switch the driver's ssh keys are gone with the old system; commands continue
    # over the serial console, and PATH is minimal there.
    gate.succeed(GATE + " --status 2>&1 | grep 'runs the running generation' >/dev/null")
    gate.succeed(GATE + " --status 2>&1 | grep 'none armed' >/dev/null")
    # The pin must be real, not just reported: loader.conf's default names an entry file, and
    # that entry names the running toplevel's init -- the same contract the firmware applies.
    gate.succeed(
        "load=$(grep '^default ' /boot/loader/loader.conf | cut -d' ' -f2)"
        " && grep -qF \"init=$(readlink -f /run/current-system)/init\""
        " /boot/loader/entries/$load")
    # `systemctl cancel --when` must clear logind's schedule file too, not just the transient
    # timer `--status` reads: a leftover /run/systemd/shutdown/scheduled reboots the host later.
    gate.succeed("cat /run/systemd/shutdown/scheduled 2>/dev/null || echo SCHEDULED_CLEARED")

    # Watcher: runs INSIDE the guest via setsid, not `&` — the harness executes every command
    # as `bash -c ... | base64`, a non-interactive pipe context where bash refuses background
    # jobs ("initialize_job_control: no job control in background"), failing the whole command.
    # It writes to kmsg (survives the console) and diffs any freshly built backdoor unit
    # against the running one, showing exactly why a switch would decide to restart/stop it.
    gate.succeed("cp /etc/systemd/system/backdoor.service /tmp/bd1.service")
    gate.execute(
        "ls -t /nix/store/*-unit-backdoor.service | head -2; diff -q /tmp/bd1.service "
        "$(ls -t /nix/store/*-unit-backdoor.service | head -1) >/dev/null 2>&1"
        " && echo BDUNIT_SAME || echo BDUNIT_DIFF")
    # (A kmsg watcher here was tried and removed: the mini system lacks coreutils, so its loop
    # busy-spun 'sleep: command not found' and starved the single-CPU guest.  The one-shot
    # backdoor-unit diff above is enough to diagnose console death if it ever recurs.)

    # v2: the submit route.  A patch against the baseline (allowlisted path, policy unchanged)
    # reconstructs a tree, builds, switches, and confirms.
    gate.succeed("cd /srv/mini && sed -i 's/gen-1/gen-2/' system.nix && git diff > /tmp/v2.patch")
    gate.succeed("timeout 1500 " + GATE + " --submit < /tmp/v2.patch 2>&1", timeout=1800)
    gate.succeed("grep -q gen-2 /etc/deploy-marker")
    r2 = gate.succeed("cat /var/lib/deploy-ai/commit").strip()
    # Commit the v2 change in the repo so the working tree matches the deployed tree: a
    # submitted patch must apply onto ai's baseline (the deployed tree), which is exactly
    # `git diff HEAD~1 HEAD` from here — like production's `deployed..main` series.
    gate.succeed("cd /srv/mini && git add -A && git -c user.email=t@t.invalid -c user.name=t commit -qm v2")

    # v3: activates fine, then health dies.  Rewriting only `wantedBy` would NOT work — the unit
    # file stays byte-identical, so the switch never restarts/stops the running fake-api and the
    # deploy succeeds (verified: result applied in 1.3s).  Instead the candidate changes the
    # ExecStart itself: the switch restarts fake-api, the new command exits instantly, and from
    # activation onwards the unit is inactive and the health endpoint is dead.  The tail must
    # wait, roll back to v2, restore the records, and stand the guard down only because the
    # rolled-back system is demonstrably healthy.  gen-3 marks v3, so gen-2 afterwards proves v2.
    gate.succeed(
        "cd /srv/mini && sed -i 's/gen-2/gen-3/' system.nix && python3 - <<'PYEOF'"
        "\nimport re"
        "\nsrc = open('system.nix').read()"
        "\nm = re.search('ExecStart = \\\"([^\\\"]*)\\\"', src)"
        "\nassert m, 'no ExecStart line found'"
        "\nexe = m.group(1).split()[0]  # the python3 path the unit already runs"
        "\nsrc, n = re.subn('ExecStart = \\\"[^\\\"]*\\\"', 'ExecStart = \\\"' + exe + ' -c exit(0)\\\"', src)"
        "\nassert n == 1, 'ExecStart rewrite must land exactly once'"
        "\nopen('system.nix', 'w').write(src)"
        "\nPYEOF"
    )
    gate.succeed("cd /srv/mini && git add -A && git -c user.email=t@t.invalid -c user.name=t commit -qm v3 && git diff HEAD~1 HEAD > /tmp/v3.patch")
    # `systemd-run --wait` sends the switch unit's output to the journal; the gate replays the
    # journal tail on stderr, so capture the whole output and require the rollback line — a
    # guard refusal (which exits fast without building) would otherwise pass `fail()` vacuously.
    rc3, out3 = gate.execute("timeout 1500 " + GATE + " --submit < /tmp/v3.patch 2>&1", timeout=1800)
    if rc3 == 0:
        raise Exception("v3 submit unexpectedly succeeded:\n" + out3)
    if "was rolled back" not in out3:
        raise Exception("v3 failed without taking the rollback path:\n" + out3)
    gate.succeed("grep -q gen-2 /etc/deploy-marker")
    gate.succeed(
        "test \"$(readlink -f /run/current-system)\" = \"$(cat /var/lib/deploy-ai/toplevel)\"")
    gate.succeed("test \"$(cat /var/lib/deploy-ai/commit)\" = \"" + r2 + "\"")
    gate.succeed("systemctl is-active fake-api.service | grep -q active")
    # Boot pin after rollback: the disk-backed /boot survives switch activations, so the loader
    # default must now name the entry of what is live again -- the rolled-back generation.
    gate.succeed(
        "load=$(grep '^default ' /boot/loader/loader.conf | cut -d' ' -f2)"
        " && grep -qF \"init=$(cat /var/lib/deploy-ai/toplevel)/init\""
        " /boot/loader/entries/$load")
    gate.succeed(GATE + " --status 2>&1 | grep 'none armed' >/dev/null")

    # v4: a patch touching a path outside the allowlist must be refused BEFORE any build, with
    # the system untouched.  Assert the refusal text, not just rc != 0 — a generic failure would
    # otherwise pass vacuously.
    gate.succeed(
        "cd /srv/mini && echo pwned > evil.txt && git add -A && "
        "git -c user.email=t@t.invalid -c user.name=t commit -qm v4-evil && "
        "git diff HEAD~1 HEAD > /tmp/v4.patch"
    )
    rc4, out4 = gate.execute("timeout 300 " + GATE + " --submit < /tmp/v4.patch 2>&1", timeout=400)
    if rc4 == 0:
        raise Exception("v4 submit unexpectedly succeeded:\n" + out4)
    if "outside the deploy-ai allowlist" not in out4 or "result: refused" not in out4:
        raise Exception("v4 refused for the wrong reason:\n" + out4)
    gate.succeed("grep -q gen-2 /etc/deploy-marker")
    gate.succeed("test \"$(cat /var/lib/deploy-ai/commit)\" = \"" + r2 + "\"")
    gate.succeed(GATE + " --status 2>&1 | grep 'none armed' >/dev/null")
  '';
}
