{ hostName, ... }: 
{
  imports = [ ./nix ./terminal ./user ];
  networking.hostName = "${hostName}";  
}
