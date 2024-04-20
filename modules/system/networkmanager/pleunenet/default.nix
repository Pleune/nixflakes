{
  pkgs,
  hostName,
  config,
  private,
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
{
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
