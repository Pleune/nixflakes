{ pkgs }:
{
  resources = {
    roots = [ ./resources ];
    packages = with pkgs; [
      pi-ask
      pi-hermes-memory
      pi-subagents
      rpiv-btw
      rpiv-todo
      pi-token-burden
    ];
  };

  jail = {
    forwardedEnv = [
      "OPENAI_API_KEY"
      "ANTHROPIC_API_KEY"
      "GOOGLE_API_KEY"
      "MISTRAL_API_KEY"
      "DEEPSEEK_API_KEY"
      "XAI_API_KEY"
    ];
    shareNetwork = true;
    statePaths = [
      ".pi/agent/auth.json"
      ".pi/agent/mcp-cache.json"
      ".pi/agent/memory"
      ".pi/agent/models.json"
      ".pi/agent/projects-memory"
      ".pi/agent/run-history.jsonl"
      ".pi/agent/sessions"
    ];
  };
}
