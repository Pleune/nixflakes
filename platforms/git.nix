{
  modulesPath,
  pkgs,
  config,
  private,
  ...
}:
let
  jupyter = pkgs.python3.withPackages (
    ps: with ps; [
      ipywidgets
      jupyterlab
      nbconvert
    ]
  );

  # Honeypot bait for iocaine. These links are hidden from humans but sit in
  # the footer of every rendered page, so a crawler that follows them hands
  # iocaine a path it only ever recognizes as bait. The token has to match
  # `checks.generated-urls.identifiers` in platforms/jump.nix, because the
  # poisoned page is served by iocaine on the other host and there is no way
  # for Forgejo to ask it anything.
  honeypotToken = "guestbook-7c4b59dd";
  forgejoBait = pkgs.writeTextDir "templates/custom/extra_links_footer.tmpl" ''
    <a href="/${honeypotToken}/" class="tw-hidden">Guestbook</a>
    <a href="/cgi-bin/guestbook.pl" class="tw-hidden">Visitor log</a>
  '';
in
{
  imports = [
    "${modulesPath}/virtualisation/lxc-container.nix"
  ];

  nixpkgs.hostPlatform = {
    # gcc.arch = "alderlake";
    # gcc.tune = "alderlake";
    system = "x86_64-linux";
  };

  environment.systemPackages = with pkgs; [ vim ];
  networking.firewall.allowedTCPPorts = [ config.services.forgejo.settings.server.HTTP_PORT ];

  networking = {
    dhcpcd.enable = false;
    useDHCP = false;
    useHostResolvConf = false;
  };

  systemd.network = {
    enable = true;
    networks."50-eth0" = {
      matchConfig.Name = "eth0";
      networkConfig = {
        DHCP = "ipv4";
        IPv6AcceptRA = true;
      };
      linkConfig.RequiredForOnline = "routable";
    };
  };

  users.users.git = {
    home = config.services.forgejo.stateDir;
    useDefaultShell = true;
    group = config.services.forgejo.group;
    isSystemUser = true;
  };

  nixflakes.agenix.enable = true;
  age.secrets."PT-Git.key" = {
    file = "${private.secrets}/PT-Git.key";
    owner = config.services.forgejo.user;
  };
  age.secrets."PT-Git.crt" = {
    file = "${private.secrets}/PT-Git.crt";
    owner = config.services.forgejo.user;
  };
  age.secrets."smtpuser" = {
    file = "${private.secrets}/aws_smtp_user.txt";
    owner = config.services.forgejo.user;
  };
  age.secrets."smtppasswd" = {
    file = "${private.secrets}/aws_smtp_password.txt";
    owner = config.services.forgejo.user;
  };

  services.forgejo = {
    enable = true;
    user = "git";
    settings = {
      server = {
        DOMAIN = "git.pleunetowne.com";
        ROOT_URL = "https://git.pleunetowne.com";
        PROTOCOL = "https";
        SSH_PORT = 2223;
        KEY_FILE = config.age.secrets."PT-Git.key".path;
        CERT_FILE = config.age.secrets."PT-Git.crt".path;
      };
      mailer = {
        ENABLED = true;
        FROM = "git@pleunetowne.com";
        PROTOCOL = "smtps";
        SMTP_ADDR = "email-smtp.us-east-2.amazonaws.com";
        SMTP_PORT = 2465;
      };
      "markup.jupyter" = {
        ENABLED = true;
        FILE_EXTENSIONS = ".ipynb";
        RENDER_COMMAND = "${jupyter}/bin/jupyter nbconvert --stdout --to html --template full";
        IS_INPUT_FILE = true;
      };
      actions.ENDLESS_TASK_TIMEOUT = "56h";
      session.COOKIE_SECURE = true;
      service = {
        REGISTER_EMAIL_CONFIRM = true;
        ENABLE_NOTIFY_MAIL = true;
        DISABLE_REGISTRATION = true;
      };
      # Bot crawlers hitting /archive/ links generate tarballs on the fly and
      # fill the disk with repo-archive cache (forgejo/forgejo#7011); refuse
      # the downloads entirely. Git and Nix flake fetches are unaffected.
      "repository".DISABLE_DOWNLOAD_SOURCE_ARCHIVES = true;
      "repository.pull-request".DEFAULT_MERGE_STYLE = "rebase";
      "repository.upload".FILE_MAX_SIZE = 60000;
      attachment.MAX_SIZE = 60000;
    };
    secrets = {
      mailer = {
        USER = config.age.secrets."smtpuser".path;
        PASSWD = config.age.secrets."smtppasswd".path;
      };
    };
    lfs.enable = true;
    package = pkgs.forgejo;
  };

  # Forgejo has no option for extra templates, and the upstream docs treat
  # custom templates as unsupported, so these hooks are the ones shipped as
  # empty placeholders upstream (`templates/custom/*.tmpl`) rather than an
  # override of a real page. `customDir` is already in ReadWritePaths, and
  # the unit runs as the Forgejo user with `CapabilityBoundingSet = ""`,
  # `NoNewPrivileges` and `PrivateUsers` set, so `install` must not try to
  # chown: the copy lands owned by the service's own user and group.
  #
  # Forgejo overlays `${customDir}/templates` onto its builtin templates
  # (modules/templates/base.go:19 in 17.0.1), which is how the placeholder
  # gets replaced. Templates are still the unsupported route upstream: expect
  # to re-check this include site after a Forgejo upgrade.
  systemd.services.forgejo = {
    preStart = pkgs.lib.mkAfter ''
      install -d -m 0750 ${config.services.forgejo.customDir}/templates/custom
      install -m 0640 ${forgejoBait}/templates/custom/extra_links_footer.tmpl ${config.services.forgejo.customDir}/templates/custom/extra_links_footer.tmpl
    '';
    restartTriggers = [ forgejoBait ];
  };

  nixflakes.makeUser = false;
  system.stateVersion = "24.11";
}
