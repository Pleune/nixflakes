# The guest's side of the NAT link, shared by both guest systems.
#
# `buildvm.service` hands the VM a virtio NIC on qemu's user-mode network, which is a NAT to whatever
# ai can reach, and pins the subnet it NATs:
#
#     -netdev user,id=n0,net=10.0.2.0/24,host=10.0.2.2,dns=10.0.2.3,dhcpstart=10.0.2.15,mac=…,hostfwd=…
#
# The guest is configured to match rather than left to DHCP, because qemu's defaults in this build
# hand out `240.0.0.1/24` with no default route and no resolver, and a guest with no route cannot
# fetch nixpkgs, the git host, or anything else it builds.  Change the qemu arguments and this file
# together.
#
# The interface is matched by MAC address, deliberately.  Predictable interface names are not stable
# across generations of this VM - one boot named the card `ens3`, the next `enp0s3` - and a name-based
# `.network` unit that stops matching fails silently: the card comes up `state DOWN` with no address,
# `nc -z 127.0.0.1 2224` still reports the port open because qemu accepts the forward locally, and ssh
# then hangs before the banner.  qemu pins the MAC, so this match cannot drift.
{
  # Static addresses need a manager.  With `useNetworkd = false` this config falls to nixpkgs' scripted
  # path, and `useDHCP = false` means nothing runs at all: `systemd.network.networks` stays `{ }`, the
  # interface comes up with no address, and `ssh -p 2224` hangs after `Connection established` because
  # libslirp has forwarded the connection to a guest nobody can reach.
  networking.useNetworkd = true;
  networking.useDHCP = false;

  systemd.network.networks."40-buildvm-nat" = {
    # Mirrors `nixflakes.virtualisation.buildvm.netGuestMac`.
    matchConfig.MACAddress = "52:54:00:12:34:56";

    networkConfig = {
      DHCP = "no";
      # qemu's NAT gateway and its built-in resolver, which forwards to ai's own resolver.  Both go
      # here rather than through `networking.defaultGateway`/`networking.nameservers` because those
      # are keyed on interface *names*, which is exactly what cannot be relied on.
      Gateway = "10.0.2.2";
      DNS = "10.0.2.3";
    };

    # qemu hands out this address over DHCP; the guest takes it statically instead, so the address
    # does not depend on libslirp's pool behaving.
    address = [ "10.0.2.15/24" ];
  };
}
