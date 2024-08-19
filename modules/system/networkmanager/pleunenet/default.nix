{
  pkgs,
  config,
  lib,
  private,
  hostName,
  ...
}:
let
  generate-pleunetowne = pkgs.writeShellScript "generate-pleunetowne" ''
    umask 600
    nmc=/etc/NetworkManager/system-connections/PleuneTowne.nmconnection
    sed -e "s#@PRIVATE_KEY@#$PRIVATE_KEY#" -e "s#@ID@#$ID#" < ${config.age.secrets.wireguard-template.path} > $nmc
    chmod 600 $nmc
  '';
in
with lib;
{
  options.nixflakes.pleunenet.enable = mkEnableOption "PleuneNET Wireguard NM preset";
  config = mkIf config.nixflakes.pleunenet.enable (mkMerge [
    {
      # don't block all the traffic please
      networking.firewall = {
        logReversePathDrops = true;
        extraCommands = ''
          ip46tables -t mangle -I nixos-fw-rpfilter -p udp -m udp --sport 51820 -j RETURN 
          ip46tables -t mangle -I nixos-fw-rpfilter -p udp -m udp --dport 51820 -j RETURN 
        '';
        extraStopCommands = ''
          ip46tables -t mangle -D nixos-fw-rpfilter -p udp -m udp --sport 51820 -j RETURN || true 
          ip46tables -t mangle -D nixos-fw-rpfilter -p udp -m udp --dport 51820 -j RETURN || true
        '';
      };

      nixflakes.agenix.enable = true; # make sure agenix is turned on
      age.secrets.wireguard-template.file = "${private.secrets}/wireguard_template.age";
      age.secrets.wireguard-settings.file = "${private.secrets}/wireguard_settings_${hostName}.age";
      systemd.services.NetworkManager.partOf = [ "instantiate_pleunenet.service" ];
      systemd.services.instantiate_pleunenet = {
        enable = true;
        description = "Generate a PleuneTowne VPN configuration for Network Manager from the system agenix secrets";
        serviceConfig = {
          EnvironmentFile = config.age.secrets.wireguard-settings.path;
          Type = "oneshot";
          ExecStart = "${generate-pleunetowne}";
        };
        after = [
          "run-agenix.d.mount"
          "systemd-tmpfiles-setup.service"
        ];
        before = [ "NetworkManager.service" ];
        wantedBy = [ "multi-user.target" ];
      };
    }
  ]);
}
