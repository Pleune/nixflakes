{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.bitbucket-runner;

  containerName = "bitbucket-runner-${cfg.name}";

  podmanBin = lib.getExe' config.services.podman.package "podman";

  runArgs = lib.concatStringsSep " " ([
    "--rm"
    "--name ${lib.escapeShellArg containerName}"
    "--volume ${lib.escapeShellArg cfg.workingDirectory}:/tmp"
    "--volume /run/user/$(id -u)/podman/podman.sock:/var/run/docker.sock"
    "--env-file ${lib.escapeShellArg (toString cfg.environmentFile)}"
    "--env WORKING_DIRECTORY=/tmp"
  ]
  ++ lib.optionals (cfg.name != null) [
    "--env RUNNER_NAME=${lib.escapeShellArg cfg.name}"
  ]
  ++ cfg.extraPodmanArgs);
in
{
  options.services.bitbucket-runner = with lib; {
    enable = mkEnableOption "Bitbucket Pipelines Runner (via Podman)";

    image = mkOption {
      type = types.str;
      default = "docker-public.packages.atlassian.com/sox/atlassian/bitbucket-pipelines-runner:latest";
      description = ''
        OCI image to use for the runner container.
      '';
    };

    name = mkOption {
      type = types.str;
      default = "bitbucket-runner";
      description = ''
        Runner name displayed in Bitbucket workspace settings.
        Set to your machine hostname or a custom label.
      '';
    };

    workingDirectory = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/.local/share/bitbucket-runner";
      description = ''
        Host directory mounted as the runner's working directory.
        Pipeline build artifacts are stored here.
      '';
    };

    environmentFile = mkOption {
      type = types.path;
      description = ''
        Path to an environment file containing runner credentials.
        Expected variables:
        - ACCOUNT_UUID
        - RUNNER_UUID
        - OAUTH_CLIENT_ID
        - OAUTH_CLIENT_SECRET
      '';
    };

    extraPodmanArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Extra arguments passed to `podman run`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.podman.enable;
        message = "services.bitbucket-runner requires services.podman.enable = true (nixflakes.services.podman.enable)";
      }
      {
        assertion = config.nixflakes.services.podman.enableSocket;
        message = "services.bitbucket-runner requires nixflakes.services.podman.enableSocket = true";
      }
    ];

    # Ensure the working directory exists
    home.activation.bitbucketRunnerWorkDir = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run mkdir -p ${lib.escapeShellArg cfg.workingDirectory}
    '';

    systemd.user.services.bitbucket-runner = {
      Unit = {
        Description = "Bitbucket Pipelines Runner";
        After = [
          "network.target"
          "podman.socket"
        ];
        Requires = [ "podman.socket" ];
      };

      Service = {
        Type = "simple";
        ExecStartPre = [
          "-${podmanBin} pull ${cfg.image}"
          "-${podmanBin} stop ${containerName}"
          "-${podmanBin} rm ${containerName}"
        ];
        ExecStart = "${podmanBin} run ${runArgs} ${cfg.image}";
        ExecStop = "${podmanBin} stop ${containerName}";
        Restart = "on-failure";
        RestartSec = 10;
      };

      Install = {
        WantedBy = [ "default.target" ];
      };
    };
  };
}
