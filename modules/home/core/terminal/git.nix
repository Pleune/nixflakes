{
  pkgs,
  userFullName,
  userEmail,
  ...
}:
{
  programs = {
    git = {
      enable = true;
      lfs.enable = true;
      userName = userFullName;
      userEmail = userEmail;
      delta = {
        enable = true;
        options = {
          navigate = true;
          side-by-side = true;
        };
      };
    };

    lazygit.enable = true;
  };

  home.packages = with pkgs; [
    git-subrepo # git subtree management addon command
    gh # GitHub
  ];
}
