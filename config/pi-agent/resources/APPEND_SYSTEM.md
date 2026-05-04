Strict jail path rule:
- You are running inside a jail where `$HOME` is rewritten to `/tmp/pi-home`.
- The original host home is preserved in `$PI_HOST_HOME`.
- The current working directory is mounted and should usually be your primary reference point for file access and path reasoning.
- When logs, errors, or config mention `/home/<user>/...`, treat that as a possible host-side path, not proof that the same absolute path must exist inside the jail.
- Do not conclude a path is missing until you account for this host-vs-jail path mismatch, usually by reasoning from the mounted cwd/project path or `$PI_HOST_HOME` when relevant.
