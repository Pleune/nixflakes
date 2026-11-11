#!/usr/bin/env python3
"""Host-side tests: python3 test.py SANDBOX FIXTURE BASH (from the repo).

Build agent-sandbox and agent-sandbox.tests.fixture first. Requires working
Bubblewrap/user namespaces; sandbox startup failures fail rather than skip.
"""

import os
import pathlib
import pty
import select
import signal
import socket
import subprocess
import sys
import tempfile
import threading

sandbox, fixture, shell = sys.argv[1:]
sandbox = str(pathlib.Path(sandbox) / "bin/agent-sandbox")
fixture = pathlib.Path(fixture)
checks = 0

with tempfile.TemporaryDirectory(prefix=".agent-sandbox-test-", dir=os.getcwd()) as temp:
    root = pathlib.Path(temp)
    cwd, home = root / "work", root / "home"
    cwd.mkdir()
    (home / "bin").mkdir(parents=True)
    secret = home / "secret"
    secret.write_text("must stay private")
    git_config = b"[user]\n\tname = Jail Probe\n"
    (home / ".config/git").mkdir(parents=True)
    (home / ".config/git/config").write_bytes(git_config)
    hidden_tool = home / "bin/host-home-tool"
    hidden_tool.write_text(f"#!{shell}\nexit 0\n")
    hidden_tool.chmod(0o755)
    env = dict(os.environ)
    for key in (
        "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GOOGLE_API_KEY",
        "MISTRAL_API_KEY", "DEEPSEEK_API_KEY", "XAI_API_KEY",
    ):
        env.pop(key, None)
    env.update(
        HOME=str(home), PI_HOST_HOME=str(home), TERM="xterm", LANG="C.UTF-8",
        PATH=f"{home}/bin:{env['PATH']}",
        AGENT_SANDBOX_PRIVATE="must-not-forward", OPENAI_API_KEY="test-key",
    )

    def run(*args, expected=0, input=None, environment=None):
        global checks
        result = subprocess.run(
            [sandbox, *args], cwd=cwd, env=environment or env,
            input=input, capture_output=True, timeout=20,
        )
        assert result.returncode == expected, (args, result.returncode, result.stderr)
        checks += 1
        return result.stdout

    usage = subprocess.run([sandbox], capture_output=True)
    assert usage.returncode == 64 and b"Usage:" in usage.stderr
    checks += 1
    run("agent-sandbox-command-that-does-not-exist", expected=127)
    blocked = cwd / "not-executable"
    blocked.write_text("no executable permission\n")
    run(str(blocked), expected=126)
    run(shell, "-c", "exit 37", expected=37)
    # Delete the launch cwd to force sandbox setup to fail. No host fallback.
    failed_cwd, marker = root / "deleted-work", root / "unsafe-fallback"
    failed_cwd.mkdir()
    failed = subprocess.run(
        [shell, "-c", '''cd "$1" && rmdir "$1" && exec "$2" "$3" -c 'printf unsafe > "$1"' -- "$4"''',
         "--", str(failed_cwd), sandbox, shell, str(marker)],
        env=env, capture_output=True, timeout=20,
    )
    assert failed.returncode != 0 and not marker.exists(), failed.stderr
    checks += 1

    arguments = ["", "two words", "'quoted'", '"double"', "*", "line\nbreak", "-x", "$(touch injected)"]
    expected = b"".join(arg.encode() + b"\0" for arg in arguments)
    for name in ("probe", "probe-alias", "space name", ".hidden-probe"):
        result = subprocess.run(
            [str(fixture / "bin" / name), *arguments], cwd=cwd, env=env,
            capture_output=True, timeout=20,
        )
        assert result.returncode == 0, result.stderr
        assert result.stdout == expected, (name, result.stdout)
        checks += 1
    assert not (cwd / "injected").exists()
    assert run("printf", "%s", "bare-path") == b"bare-path"
    relative = cwd / "relative probe"
    relative.write_text(f'#!{shell}\nprintf "%s" "$1"\n')
    relative.chmod(0o755)
    assert run("./relative probe", "relative-ok") == b"relative-ok"
    assert run(shell, "-c", "cat", input=b"stdin\n") == b"stdin\n"
    assert run(shell, "-c", "printf pipe | cat") == b"pipe"
    streams = subprocess.run(
        [sandbox, shell, "-c", "printf stdout; printf stderr >&2"],
        cwd=cwd, env=env, capture_output=True, timeout=20,
    )
    assert streams.returncode == 0 and streams.stdout == b"stdout" and streams.stderr == b"stderr"
    checks += 1
    assert run(shell, "-c", 'printf "%s" "$HOME"') == b"/tmp/pi-home"
    run(shell, "-c", 'test "$XDG_CONFIG_HOME" = "$HOME/.config" && test "$XDG_CACHE_HOME" = "$HOME/.cache" && test "$XDG_STATE_HOME" = "$HOME/.local/state"')
    run(shell, "-c", 'test -z "${AGENT_SANDBOX_PRIVATE+x}" && test "$OPENAI_API_KEY" = test-key && test -z "${ANTHROPIC_API_KEY+x}"')
    run(shell, "-c", 'test ! -e "$1" && test ! -e "$HOME/.pi"', "--", str(secret))
    run(shell, "-c", 'printf writable > created; printf ephemeral > "$HOME/ephemeral"')
    assert (cwd / "created").read_text() == "writable"
    run(shell, "-c", 'test ! -e "$HOME/ephemeral"')
    run("host-home-tool", expected=127)
    # The upstream jail builder caches fake passwd/group during host-side setup.
    assert sorted(p.name for p in home.iterdir()) == [".config", ".local", "bin", "secret"]
    assert sorted(p.name for p in (home / ".local/share/jail.nix").iterdir()) == ["group", "passwd"]
    assert not (home / ".pi").exists()
    # The host git config directory is shared read-only at the same XDG path.
    assert run(shell, "-c", 'cat "$XDG_CONFIG_HOME/git/config"') == git_config
    run(shell, "-c", 'printf hijacked > "$XDG_CONFIG_HOME/git/config"', expected=1)
    assert (home / ".config/git/config").read_bytes() == git_config
    profile = home / "profile-bin"
    profile.symlink_to(pathlib.Path(shell).parent)
    profile_env = dict(env, PATH=str(profile))
    assert run("bash", "--noprofile", "--norc", "-c", "printf profile-ok", environment=profile_env) == b"profile-ok"

    with socket.socket() as server:
        server.bind(("127.0.0.1", 0))
        server.listen(1)
        server.settimeout(20)
        port = server.getsockname()[1]

        def reply():
            with server.accept()[0] as connection:
                connection.sendall(b"network-ok\n")

        thread = threading.Thread(target=reply, daemon=True)
        thread.start()
        assert run(shell, "-c", f'read -r line </dev/tcp/127.0.0.1/{port}; printf "%s" "$line"') == b"network-ok"
        thread.join(timeout=5)
        assert not thread.is_alive()

    for sig in (signal.SIGINT, signal.SIGTERM):
        process = subprocess.Popen(
            [sandbox, shell, "-c", "printf ready; exec sleep 60"],
            cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True,
        )
        try:
            assert select.select([process.stdout], [], [], 20)[0], "signal probe did not start"
            assert process.stdout.read(5) == b"ready"
            process.send_signal(sig)
            process.communicate(timeout=10)
            assert process.returncode in (-sig, 128 + sig), process.returncode
            checks += 1
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()

    master, slave = pty.openpty()
    process = subprocess.Popen(
        [sandbox, shell, "-c", 'test -t 0 && test -t 1 || exit 1; read -r line; printf "tty:%s\\n" "$line"'],
        cwd=cwd, env=env, stdin=slave, stdout=slave, stderr=slave,
    )
    os.close(slave)
    try:
        os.write(master, b"interactive-ok\n")
        output = b""
        while b"tty:interactive-ok" not in output:
            assert select.select([master], [], [], 20)[0], "terminal probe timed out"
            output += os.read(master, 4096)
        assert process.wait(timeout=10) == 0
        checks += 1
    finally:
        os.close(master)
        if process.poll() is None:
            process.kill()
            process.wait()

print(f"Passed {checks} sandbox runtime checks")
