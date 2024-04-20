{
  pkgs,
  username,
  userFullName,
  ...
}:
{
  home-manager.users.${username} = {
    programs.gpg = {
      enable = true;
    };

    services.gpg-agent = {
      enable = true;
    };

    programs.git.signing = {
      signByDefault = true;
      key = "${userFullName}";
    };
  };
}
