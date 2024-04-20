{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [ system-config-printer ];
  services.printing = {
    enable = true;
    drivers = with pkgs; [
      gutenprint
      gutenprintBin
      hplipWithPlugin
      postscript-lexmark
      samsung-unified-linux-driver
      splix
      brlaser
      brgenml1lpr
      cnijfilter2
    ];
  };
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };
}
