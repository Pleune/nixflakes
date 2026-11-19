# The guest's side of the NAT link, shared by both guest systems.
#
# `buildvm.service` hands the VM a virtio NIC on qemu's user-mode network, which is a NAT to whatever
# ai can reach, and pins the subnet it NATs:
#
#     -netdev user,id=n0,net=10.0.2.0/24,host=10.0.2.2,dns=10.0.2.3,dhcpstart=10.0.2.15,hostfwd=…
#
# The guest is configured to match rather than left to DHCP, because qemu's defaults in this build
# hand out `240.0.0.1/24` with no default route and no resolver, and a guest with no route cannot
# fetch nixpkgs, the git host, or anything else it builds.  Change the qemu arguments and this file
# together.
#
# `ens3` is what systemd names the single virtio-net-pci on the q35 topology buildvm uses.  If that
# ever changes, networking here stops working loudly (no address, so no ssh), which is the point:
# a silently misrouted guest fails later, somewhere much harder to read.
{
  # Static addresses need a manager.  With `useNetworkd = false` this config falls to nixpkgs' scripted
  # path, and `useDHCP = false` means nothing runs at all: `systemd.network.networks` stays `{ }`, the
  # interface comes up with no address, and `ssh -p 2224` hangs after `Connection established` because
  # libslirp has forwarded the connection to a guest nobody can reach.
  networking.useNetworkd = true;
  networking.useDHCP = false;

  networking.interfaces.ens3 = {
    ipv4.addresses = [ { address = "10.0.2.15"; prefixLength = 24; } ];
  };

  # qemu's NAT gateway and its built-in resolver, which forwards to ai's own resolver.
  networking.defaultGateway = { address = "10.0.2.2"; interface = "ens3"; };
  networking.nameservers = [ "10.0.2.3" ];
}
