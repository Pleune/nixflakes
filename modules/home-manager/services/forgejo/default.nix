{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.forgejo;
  format = pkgs.formats.ini { };
  exe = lib.getExe cfg.package;

  injectCookieScript = ./inject-cookie.sh;

  forgejoCliFlags = "-w ${lib.escapeShellArg cfg.stateDir} -c ${lib.escapeShellArg "${cfg.stateDir}/custom/conf/app.ini"}";

  # Prepare directories and generate secrets on first start
  prepareScript = pkgs.writeShellScript "forgejo-prepare" ''
    set -eu

    mkdir -p ${lib.escapeShellArg cfg.stateDir}/{conf,custom/conf,data,log,repositories}

    # Generate secrets if they don't exist yet
    secret_dir=${lib.escapeShellArg "${cfg.stateDir}/custom/conf"}

    if [ ! -s "$secret_dir/secret_key" ]; then
      ${lib.escapeShellArg exe} generate secret SECRET_KEY > "$secret_dir/secret_key"
    fi

    if [ ! -s "$secret_dir/internal_token" ]; then
      ${lib.escapeShellArg exe} generate secret INTERNAL_TOKEN > "$secret_dir/internal_token"
    fi

    if [ ! -s "$secret_dir/oauth2_jwt_secret" ]; then
      ${lib.escapeShellArg exe} generate secret JWT_SECRET > "$secret_dir/oauth2_jwt_secret"
    fi

    ${lib.optionalString cfg.lfs.enable ''
      if [ ! -s "$secret_dir/lfs_jwt_secret" ]; then
        ${lib.escapeShellArg exe} generate secret LFS_JWT_SECRET > "$secret_dir/lfs_jwt_secret"
      fi
    ''}

    # Write app.ini from the Nix-generated config
    config_file=${lib.escapeShellArg "${cfg.stateDir}/custom/conf/app.ini"}
    cp -f ${lib.escapeShellArg (format.generate "app.ini" cfg.settings)} "$config_file"
    chmod u+w "$config_file"

    # Inject secrets via environment-to-ini
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (envVar: path: ''
      export ${envVar}=${lib.escapeShellArg path}
    '') secretEnvVars)}
    ${lib.getExe' cfg.package "environment-to-ini"} --config "$config_file"
    chmod u-w "$config_file"
  '';

  # Admin user bootstrap + cookie injection script
  adminSetupScript = pkgs.writeShellScript "forgejo-admin-setup" ''
    set -eu

    export FORGEJO_WORK_DIR=${lib.escapeShellArg cfg.stateDir}
    export FORGEJO_CUSTOM=${lib.escapeShellArg "${cfg.stateDir}/custom"}

    forgejo=${lib.escapeShellArg exe}
    cli_flags="${forgejoCliFlags}"
    password_file=${lib.escapeShellArg "${cfg.stateDir}/custom/conf/admin_password"}
    base_url="http://127.0.0.1:${toString cfg.settings.server.HTTP_PORT}"
    cookie_name=${lib.escapeShellArg cfg.settings.session.COOKIE_NAME}
    username=${lib.escapeShellArg cfg.adminUser.username}

    # Wait for forgejo to be ready
    for i in $(seq 1 30); do
      if ${pkgs.curl}/bin/curl -sf "$base_url" >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done

    # Generate a random password if we don't have one yet
    if [ ! -s "$password_file" ]; then
      $forgejo generate secret SECRET_KEY > "$password_file"
      chmod 600 "$password_file"
    fi
    password=$(cat "$password_file")

    # Create admin user if it doesn't exist, or fix existing one
    if ! $forgejo admin user list $cli_flags 2>/dev/null | grep -q "$username"; then
      $forgejo admin user create $cli_flags \
        --admin \
        --username "$username" \
        --email ${lib.escapeShellArg cfg.adminUser.email} \
        --password "$password" \
        --must-change-password=false
      echo "Admin user '$username' created"
    else
      # Ensure password is synced and user is usable
      $forgejo admin user change-password $cli_flags \
        --username "$username" \
        --password "$password" \
        --must-change-password=false 2>/dev/null || true
    fi

    ${lib.optionalString cfg.autoLogin.enable ''
      # --- Session cookie injection into Firefox ---

      # Find Firefox profile directory
      firefox_dir="${config.home.homeDirectory}/.mozilla/firefox"
      if [ ! -d "$firefox_dir" ]; then
        echo "Firefox directory not found, skipping auto-login"
        exit 0
      fi

      # Find the default profile
      profile_dir=""
      if [ -f "$firefox_dir/profiles.ini" ]; then
        rel_path=$(${pkgs.gawk}/bin/awk -F= '
          /^\[/ { section=$0 }
          /^Default=1/ { found=section }
          /^Path=/ && found { print $2; exit }
        ' "$firefox_dir/profiles.ini")
        if [ -n "$rel_path" ]; then
          profile_dir="$firefox_dir/$rel_path"
        fi
      fi

      # Fallback: find first profile directory
      if [ -z "$profile_dir" ] || [ ! -d "$profile_dir" ]; then
        profile_dir=$(find "$firefox_dir" -maxdepth 1 -type d -name "*.default*" | head -1)
      fi

      if [ -z "$profile_dir" ] || [ ! -d "$profile_dir" ]; then
        echo "No Firefox profile found, skipping auto-login"
        exit 0
      fi

      cookies_db="$profile_dir/cookies.sqlite"

      # Check if Firefox has the DB locked
      if ${pkgs.psmisc}/bin/fuser "$cookies_db" >/dev/null 2>&1; then
        echo "Firefox is running (cookies.sqlite locked), skipping cookie injection"
        echo "Restart the forgejo service when Firefox is closed to inject the cookie"
        exit 0
      fi

      # Login via POST to get session cookies (don't follow redirect, just capture cookies)
      jar=$(mktemp)
      ${pkgs.curl}/bin/curl -c "$jar" -b "$jar" \
        -d "user_name=$username&password=$password&remember=on" \
        "$base_url/user/login" \
        -s -o /dev/null 2>/dev/null

      # Extract cookie values from the jar
      session_value=$(grep "$cookie_name" "$jar" 2>/dev/null | tail -1 | awk '{print $NF}')
      remember_value=$(grep "persistent" "$jar" 2>/dev/null | tail -1 | awk '{print $NF}')

      rm -f "$jar"

      if [ -z "$session_value" ]; then
        echo "Login failed or no session cookie received, skipping cookie injection"
        exit 0
      fi

      cookie_host=${lib.escapeShellArg cfg.settings.server.DOMAIN}

      # Inject cookies via helper script
      ${pkgs.bash}/bin/bash ${injectCookieScript} \
        "$cookies_db" "$cookie_name" "$session_value" "$cookie_host" "$remember_value" \
        ${pkgs.sqlite}/bin/sqlite3

      echo "Session cookie injected into Firefox profile: $profile_dir"
    ''}
  '';

  # Map secrets to FORGEJO__section__key__FILE env vars
  secretEnvVars = {
    "FORGEJO__SECURITY__SECRET_KEY__FILE" = "${cfg.stateDir}/custom/conf/secret_key";
    "FORGEJO__SECURITY__INTERNAL_TOKEN__FILE" = "${cfg.stateDir}/custom/conf/internal_token";
    "FORGEJO__OAUTH2__JWT_SECRET__FILE" = "${cfg.stateDir}/custom/conf/oauth2_jwt_secret";
  } // lib.optionalAttrs cfg.lfs.enable {
    "FORGEJO__SERVER__LFS_JWT_SECRET__FILE" = "${cfg.stateDir}/custom/conf/lfs_jwt_secret";
  };
in
{
  options.services.forgejo = with lib; {
    enable = mkEnableOption "Forgejo, a lightweight self-hosted Git forge";

    package = mkPackageOption pkgs "forgejo" { };

    stateDir = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/.local/share/forgejo";
      description = ''
        Directory for Forgejo data, repositories, and configuration.
      '';
    };

    adminUser = {
      enable = mkEnableOption "automatic admin user creation on first start";

      username = mkOption {
        type = types.str;
        default = config.home.username;
        defaultText = literalExpression "config.home.username";
        description = "Username for the auto-created admin account.";
      };

      email = mkOption {
        type = types.str;
        default = "${cfg.adminUser.username}@localhost";
        defaultText = literalExpression ''"''${username}@localhost"'';
        description = "Email for the auto-created admin account.";
      };
    };

    autoLogin = {
      enable = mkEnableOption "automatic Firefox session cookie injection on service start";
    };

    lfs = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable Git LFS support.";
      };

      contentDir = mkOption {
        type = types.str;
        default = "${cfg.stateDir}/data/lfs";
        defaultText = literalExpression ''"''${config.services.forgejo.stateDir}/data/lfs"'';
        description = "Where to store LFS files.";
      };
    };

    settings = mkOption {
      default = { };
      description = ''
        Free-form settings written to app.ini.
        Refer to https://forgejo.org/docs/latest/admin/config-cheat-sheet/ for supported values.
      '';
      type = types.submodule {
        freeformType = format.type;
        options = {
          server = {
            PROTOCOL = mkOption {
              type = types.enum [
                "http"
                "https"
                "fcgi"
                "http+unix"
                "fcgi+unix"
              ];
              default = "http";
              description = "Listen protocol.";
            };

            HTTP_ADDR = mkOption {
              type = types.either types.str types.path;
              default =
                if lib.hasSuffix "+unix" cfg.settings.server.PROTOCOL
                then "${cfg.stateDir}/forgejo.sock"
                else "0.0.0.0";
              defaultText = literalExpression ''"0.0.0.0"'';
              description = "Listen address.";
            };

            HTTP_PORT = mkOption {
              type = types.port;
              default = 3000;
              description = "Listen port. Ignored when using a unix socket.";
            };

            DOMAIN = mkOption {
              type = types.str;
              default = "localhost";
              description = "Domain name of your server.";
            };

            ROOT_URL = mkOption {
              type = types.str;
              default = "http://${cfg.settings.server.DOMAIN}:${toString cfg.settings.server.HTTP_PORT}/";
              defaultText = literalExpression ''"http://localhost:3000/"'';
              description = "Full public URL of Forgejo server.";
            };

            STATIC_ROOT_PATH = mkOption {
              type = types.either types.str types.path;
              default = cfg.package.data;
              defaultText = literalExpression "config.services.forgejo.package.data";
              description = "Path to static assets.";
            };

            DISABLE_SSH = mkOption {
              type = types.bool;
              default = true;
              description = "Disable SSH features (recommended for user service).";
            };
          };

          session = {
            COOKIE_NAME = mkOption {
              type = types.str;
              default = "forgejo_session";
              description = "Name of the session cookie.";
            };
          };

          log = {
            ROOT_PATH = mkOption {
              type = types.str;
              default = "${cfg.stateDir}/log";
              defaultText = literalExpression ''"''${config.services.forgejo.stateDir}/log"'';
              description = "Root path for log files.";
            };

            LEVEL = mkOption {
              type = types.enum [
                "Trace"
                "Debug"
                "Info"
                "Warn"
                "Error"
                "Critical"
              ];
              default = "Info";
              description = "General log level.";
            };
          };
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.autoLogin.enable -> cfg.adminUser.enable;
        message = "services.forgejo.autoLogin requires services.forgejo.adminUser to be enabled";
      }
    ];

    services.forgejo.settings = {
      DEFAULT = {
        RUN_MODE = lib.mkDefault "prod";
        WORK_PATH = lib.mkDefault cfg.stateDir;
      };

      database = {
        DB_TYPE = "sqlite3";
        PATH = lib.mkDefault "${cfg.stateDir}/data/forgejo.db";
      };

      repository = {
        ROOT = lib.mkDefault "${cfg.stateDir}/repositories";
      };

      security = {
        INSTALL_LOCK = true;
        LOGIN_REMEMBER_DAYS = lib.mkIf cfg.autoLogin.enable (lib.mkDefault 3650);
      };

      service = lib.mkIf cfg.adminUser.enable {
        DISABLE_REGISTRATION = lib.mkDefault true;
      };

      session = lib.mkIf cfg.autoLogin.enable {
        PROVIDER = lib.mkDefault "file";
        PROVIDER_CONFIG = lib.mkDefault "${cfg.stateDir}/data/sessions";
        SESSION_LIFE_TIME = lib.mkDefault 315360000;
      };

      server = lib.mkIf cfg.lfs.enable {
        LFS_START_SERVER = true;
      };

      lfs = lib.mkIf cfg.lfs.enable {
        PATH = cfg.lfs.contentDir;
      };
    };

    systemd.user.services.forgejo = {
      Unit = {
        Description = "Forgejo - Self-hosted Git forge";
        After = [ "network.target" ];
      };

      Service = {
        ExecStartPre = "${prepareScript}";
        ExecStart = "${exe} web";
        ExecStartPost = lib.mkIf cfg.adminUser.enable "${adminSetupScript}";
        Restart = "on-failure";
        WorkingDirectory = "~";
        Environment = [
          "USER=%u"
          "HOME=${cfg.stateDir}"
          "FORGEJO_WORK_DIR=${cfg.stateDir}"
          "FORGEJO_CUSTOM=${cfg.stateDir}/custom"
        ];
      };

      Install = {
        WantedBy = [ "default.target" ];
      };
    };

    # Git credential helper for HTTP auth to the local Forgejo instance
    programs.git.settings = lib.mkIf cfg.adminUser.enable {
      credential."http://${cfg.settings.server.DOMAIN}:${toString cfg.settings.server.HTTP_PORT}" = {
        helper = let
          script = pkgs.writeShellScript "forgejo-git-credential" ''
            password_file=${lib.escapeShellArg "${cfg.stateDir}/custom/conf/admin_password"}
            if [ "$1" = "get" ]; then
              if [ -r "$password_file" ]; then
                echo "username=${cfg.adminUser.username}"
                echo "password=$(cat "$password_file")"
              fi
            fi
          '';
        in "!${script}";
      };
    };

    home.packages = [
      cfg.package
      pkgs.git
    ];
  };
}
