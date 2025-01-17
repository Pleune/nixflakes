{
  modulesPath,
  pkgs,
  config,
  private,
  ...
}:

{
  imports = [
    "${modulesPath}/virtualisation/lxc-container.nix"
  ];

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
      session.COOKIE_SECURE = true;
      service = {
        REGISTER_EMAIL_CONFIRM = true;
        ENABLE_NOTIFY_MAIL = true;
        DISABLE_REGISTRATION = false;
      };
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

  nixflakes.makeUser = false;
  system.stateVersion = "24.11";
}
