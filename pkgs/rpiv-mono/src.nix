{ fetchFromGitHub }:
let
  version = "1.5.2";
in
{
  inherit version;
  npmDepsHash = "sha256-2MxUQ1FTpIu3cpx4rghv+IOEaFfjilfFLfvHxpJg0EI=";
  src = fetchFromGitHub {
    owner = "juicesharp";
    repo = "rpiv-mono";
    rev = "v${version}";
    hash = "sha256-NCz6gJMhJio3eZRfhHYxmbxNDjWQ12IJdXH49DkLmr4=";
  };
}
