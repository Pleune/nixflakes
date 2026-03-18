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
      settings = {
        user = {
          name = userFullName;
          email = userEmail;
        };
        push.autoSetupRemote = true;
      };
    };

    delta = {
      enable = true;
      enableGitIntegration = true;
      options = {
        navigate = true;
        side-by-side = true;
      };
    };

    lazygit.enable = true;
  };

  home.packages = with pkgs; [
    git-subrepo # git subtree management addon command
    gh # GitHub
  ];
}
