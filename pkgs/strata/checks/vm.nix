{
  testers,
  strataModule,
  strataPkg,
}:

# The whole module on a real machine: the service comes up with the mock engine (no GPU, no weights,
# no CUDA) and answers on its port through the unit's hardening.  The engine is never realized -
# mockEngine plus prefetchOnStart = false means nothing references passthru.engine.
testers.nixosTest {
  name = "strata-module-vm";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ strataModule ];

      nixflakes.services.strata = {
        enable = true;
        package = strataPkg;
        mockEngine = true;
        prefetchOnStart = false;
        vision = "off"; # the mock engine serves text only
        port = 8080;
      };

      environment.systemPackages = [ pkgs.curl ];
      virtualisation.memorySize = 1024;
    };

  testScript = ''
    machine.start()
    machine.wait_for_open_port(8080)

    machine.succeed("curl -sf http://127.0.0.1:8080/health | grep -q '\"status\": \"ok\"'")

    machine.succeed(
      "curl -sf http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' "
      "-d '{\"model\":\"mock\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":200}' "
      "| grep -q 'Hello from the mock engine.'"
    )

    machine.succeed("curl -sf http://127.0.0.1:8080/v1/models | grep -q '\"object\": \"model\"'")
  '';
}
