"""The gate's CLI contract: the usage text the deployer's agent reads, and `--list`.

The gate talks to agents over ssh with exit codes and one usage block; that surface is a
product, so it is tested as one -- including that argparse's own exit codes never leak.
"""

import io
from contextlib import redirect_stderr, redirect_stdout

import pytest

from support import DeployWorld, World, deploy_ai, refusal


class TestCliContract(World):
    def usage_for(self, argv) -> str:
        err = io.StringIO()
        with redirect_stderr(err), pytest.raises(SystemExit) as exit_request:
            deploy_ai.parse_args(argv)
        assert (exit_request.value.code == 1)
        return err.getvalue()

    def test_an_unknown_option_answers_the_usage_not_an_argparse_trace(self):
        assert ("deploy-ai" in self.usage_for(["--frobnicate"]))

    def test_a_stray_positional_is_refused_the_same_way(self):
        assert (self.usage_for(["deploy"]) == self.usage_for(["--frobnicate"]))

    def test_help_is_the_one_reply_that_exits_clean(self):
        out = io.StringIO()
        with redirect_stdout(out), pytest.raises(SystemExit) as exit_request:
            deploy_ai.parse_args(["--help"])
        assert (exit_request.value.code == 0)
        assert ("deploy-ai" in out.getvalue())

    def test_a_bare_call_reports_usage_and_exits_one(self):
        err = io.StringIO()
        with redirect_stderr(err):
            assert (deploy_ai.main([]) == 1)
        assert ("deploy-ai" in err.getvalue())


class TestListRoad(DeployWorld):
    def setup_method(self):
        super().setup_method(DEPLOY_AI_ALLOWLIST="platforms/\n",
                             DEPLOY_AI_POLICY_FILE="abc123")

    def test_list_names_the_live_branches_and_what_is_deployed(self):
        repo, deployed = self.origin(**{"flake.nix": "{}\n"})
        self.tool.repo = repo
        out = io.StringIO()
        with redirect_stdout(out):
            assert (self.tool.do_list() == "ok")
        assert ("refs/heads/main" in out.getvalue())
        assert (deployed[:8] in out.getvalue())

    def test_listing_without_a_repo_refuses(self):
        with refusal() as message:
            self.tool.do_list()
        assert ("--repo is required" in message.getvalue())
