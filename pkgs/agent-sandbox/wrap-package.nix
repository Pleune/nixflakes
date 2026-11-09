{
  lib,
  symlinkJoin,
  runtimeShell,
  agent-sandbox,
}:
let
  wrap =
    package:
    let
      binOutput = lib.getBin package;
      # Project the outputs normally installed in a profile, plus the selected
      # executable output. Inspect their filesystem layout only at build time.
      installOutputs = map (name: package.${name}) (
        package.meta.outputsToInstall or [ (package.outputName or "out") ]
      );
      forwardedOutputs = lib.genAttrs (lib.filter (name: name != "out" && name != "bin") (
        package.outputs or [ ]
      )) (name: package.${name});
      wrapped = symlinkJoin {
        name = "${package.name or (lib.getName package)}-sandboxed";
        paths = lib.unique (
          [
            binOutput
            package
          ]
          ++ installOutputs
        );
        postBuild = ''
          # Never edit through a projected/symlinked bin directory.
          rm -rf "$out/bin"
          mkdir -p "$out/bin"
          shopt -s nullglob dotglob
          count=0
          for entry in ${lib.escapeShellArg "${binOutput}/bin"}/*; do
            name="''${entry##*/}"
            if [ -f "$entry" ] && [ -x "$entry" ]; then
              printf '#!%s\nexec %q %q "$@"\n' \
                ${lib.escapeShellArg runtimeShell} \
                ${lib.escapeShellArg (lib.getExe agent-sandbox)} \
                "$entry" > "$out/bin/$name"
              chmod +x "$out/bin/$name"
              count=$((count + 1))
            else
              ln -s "$entry" "$out/bin/$name"
            fi
          done
          if [ "$count" -eq 0 ]; then
            echo 'agent-sandbox.wrap: package has no executable files in its selected bin output' >&2
            exit 1
          fi
        '';
        meta = (package.meta or { }) // {
          outputsToInstall = [ "out" ];
        };
        passthru =
          (package.passthru or { })
          // forwardedOutputs
          // lib.optionalAttrs (package ? shellPath) { inherit (package) shellPath; }
          // {
            unwrapped = package;
          };
      };
    in
    wrapped
    // lib.optionalAttrs (package ? override) {
      # Override the original package, then sandbox the result again.
      override = args: wrap (package.override args);
    };
in
wrap
