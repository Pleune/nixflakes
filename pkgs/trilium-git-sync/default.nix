{
  lib,
  stdenvNoCC,
  makeWrapper,
  python3,
  git,
  git-lfs,
  defaultGitUrl ? null,
  defaultRepoPath ? ".local/share/trilium-git.git",
  defaultWorktreeRoot ? ".local/state/trilium-git-sync/worktrees",
}:

let
  python = python3.withPackages (ps: [ ps.gitpython ps.requests ]);
in
stdenvNoCC.mkDerivation {
  pname = "trilium-git-sync";
  version = "0.1.0";

  dontUnpack = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    install -Dm755 ${./trilium-git-sync.py} $out/libexec/trilium-git-sync.py
    cp -r ${./trilium_git_sync} $out/libexec/trilium_git_sync
    patchShebangs $out/libexec/trilium-git-sync.py

    makeWrapper ${python}/bin/python3 $out/bin/trilium-git-sync \
      --add-flags $out/libexec/trilium-git-sync.py \
      --prefix PYTHONPATH : $out/libexec \
      --prefix PATH : ${
        lib.makeBinPath [
          git
          git-lfs
        ]
      } \
      --set TRILIUM_GIT_SYNC_DEFAULT_REPO_PATH ${lib.escapeShellArg defaultRepoPath} \
      --set TRILIUM_GIT_SYNC_DEFAULT_WORKTREE_ROOT ${lib.escapeShellArg defaultWorktreeRoot} \
      ${lib.optionalString (
        defaultGitUrl != null
      ) "--set TRILIUM_GIT_SYNC_DEFAULT_REMOTE_URL ${lib.escapeShellArg defaultGitUrl}"}

    runHook postInstall
  '';

  meta = {
    description = "Periodic git-backed Trilium export sync helper";
    homepage = "https://github.com/TriliumNext/Notes";
    license = lib.licenses.agpl3Plus;
    mainProgram = "trilium-git-sync";
    platforms = lib.platforms.linux;
  };
}
