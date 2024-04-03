{ hostName, ... }: {
  imports = [
    ./${hostName}
    ./internationalisation.nix
  ];
}
