{ pkgs, agent-sandbox }:
let
  inherit (pkgs) lib;
  source = lib.makeOverridable (
    {
      description ? "Sandbox test fixture",
    }:
    pkgs.runCommand "agent-sandbox-fixture"
      {
        outputs = [
          "out"
          "bin"
          "man"
        ];
        meta = {
          inherit description;
          mainProgram = "probe";
          outputsToInstall = [
            "bin"
            "man"
          ];
        };
      }
      ''
        mkdir -p "$out/commands" "$out/share" "$bin" "$man/share/man/man1"
        printf '#!%s\nprintf "%%s\\0" "$@"\n' ${lib.escapeShellArg pkgs.runtimeShell} > "$out/commands/probe"
        chmod +x "$out/commands/probe"
        ln -s probe "$out/commands/probe-alias"
        ln -s probe "$out/commands/space name"
        ln -s probe "$out/commands/.hidden-probe"
        echo 'non-executable bin asset' > "$out/commands/README"
        echo fixture-data > "$out/share/fixture-data"
        echo fixture-man > "$man/share/man/man1/probe.1"
        ln -s "$out/commands" "$bin/bin"
      ''
  ) { };
  fixture = agent-sandbox.wrap source;
  overridden = fixture.override { description = "Overridden fixture"; };
  adjusted = fixture.overrideAttrs (old: {
    meta = old.meta // {
      description = "Adjusted wrapper";
    };
  });
in
{
  inherit fixture;
  layout =
    assert fixture.meta.mainProgram == "probe";
    assert fixture.meta.outputsToInstall == [ "out" ];
    assert fixture.unwrapped == source;
    assert fixture.man == source.man;
    assert overridden.meta.description == "Overridden fixture";
    assert adjusted.meta.description == "Adjusted wrapper";
    assert adjusted.unwrapped == source;
    pkgs.runCommand "agent-sandbox-layout-test" { } ''
      test -d ${fixture}/bin
      test ! -L ${fixture}/bin
      for name in probe probe-alias 'space name' .hidden-probe; do
        test -x "${fixture}/bin/$name"
        test ! -L "${fixture}/bin/$name"
        grep -F ${lib.escapeShellArg "${agent-sandbox}/bin/agent-sandbox"} "${fixture}/bin/$name"
      done
      test -L ${fixture}/bin/README
      grep -Fx fixture-data ${fixture}/share/fixture-data
      grep -Fx fixture-man ${fixture}/share/man/man1/probe.1
      touch "$out"
    '';
}
