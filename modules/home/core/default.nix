{
  imports = [
    ./nix
    ./terminal
    ./fonts
    ./gpg
  ];

  # fix tray not launching due to not managing xsession with HM
  systemd.user.targets.tray = {
    Unit = {
      Description = "Home Manager System Tray";
      Requires = [ "graphical-session-pre.target" ];
    };
  };
}
