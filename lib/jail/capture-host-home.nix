{
  combinators,
  ...
}:
let
  inherit (combinators)
    add-runtime
    include-once
    ;
in
{
  sig = "Permission";
  doc = ''
    Captures the host HOME directory in `PI_HOST_HOME` so later runtime
    combinators can safely rewrite `HOME` for the jailed process without
    losing access to explicitly whitelisted host paths.
  '';
  impl = include-once "capture-host-home" (add-runtime ''
    if [ -z "''${PI_HOST_HOME-}" ]; then
      PI_HOST_HOME="''${HOME-}"
    fi
  '');
}
