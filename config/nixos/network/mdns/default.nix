{ ... }:
{
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    nssmdns6 = true;
    # RFC42-style settings; the flat ipv4/ipv6/publish.* options were renamed.
    settings.server = {
      use-ipv4 = true;
      use-ipv6 = true;
    };
    settings.publish = {
      disable-publishing = false;
      publish-addresses = true;
      publish-workstation = true;
    };
  };
}
