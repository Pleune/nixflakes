# Minimal stand-in for the buildvm option surface the deploy-ai module reads.
#
# deploy-ai's policy digest captures five buildvm path/identity settings (see the `policy`
# block in modules/nixos/deploy-ai/default.nix), so the mini system needs those options to
# exist -- but NOT the real buildvm module, whose provisioning, key generation, and VM-host
# units have nothing to do with testing the deploy package.  This mirrors only the option
# names, types, and defaults the digest reads; enable nothing, configure nothing.
{ lib, config, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.nixflakes.virtualisation.buildvm = {
    loginKeysDir = mkOption {
      type = types.str;
      default = "/var/lib/buildvm/keys";
      description = "Digest input only: where host-side logins live on the real ai.";
    };
    guestKeyPath = mkOption {
      type = types.str;
      default = "/var/lib/buildvm/secrets/id_ed25519";
      description = "Digest input only: the private key's guest-side location.";
    };
    publicKey = mkOption {
      type = types.str;
      default = "";
      description = "Digest input only: the guest's outbound deploy key.";
    };
    provision = {
      loginKey = mkOption {
        type = types.str;
        default = "${config.nixflakes.virtualisation.buildvm.loginKeysDir}/provision/id_ed25519";
        description = "Digest input only: the provisioning login key path.";
      };
      activationUser = mkOption {
        type = types.str;
        default = "root";
        description = "Digest input only: the user that activates inside the guest.";
      };
    };
  };
}
