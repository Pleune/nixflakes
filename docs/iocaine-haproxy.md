# iocaine behind HAProxy

`platforms/jump.nix` configures the upstream `services.iocaine` NixOS module
(`nixos/modules/services/networking/iocaine.nix`) directly. Nothing here touches
HAProxy: HAProxy stays outside Nix and reads the socket iocaine publishes, so it
must run inside the same container as iocaine.

Servers as seen by `iocaine show config`:

| Server | Bind | Purpose |
| --- | --- | --- |
| `http` | `127.0.0.1:42069` | produces the poisoned responses |
| `spoa` | `/run/iocaine/iocaine.sock` | SPOP agent HAProxy asks for a decision |
| `metrics` | `127.0.0.1:42042` | Prometheus endpoint, persisted to `/var/lib/iocaine/metrics.json` |

Both request-serving servers instantiate one handler declaration,
`nam-shub-of-enki` (`pkgs.nam-shub-of-enki`, Roto, `inherits = "default"`).
nam-shub-of-enki disables any check whose required data is missing, so the
default ruleset runs without wordlists, an ASN database, or an `ai.robots.txt`
file.

## HAProxy side

`/etc/haproxy/iocaine-spoa.cfg`:

```
[iocaine]
spoe-agent iocaine
    log global
    option var-prefix iocaine
    timeout processing 5s
    messages check-request
    use-backend iocaine

spoe-message check-request
    args req_method=method req_hdrs=req.hdrs req_path=path req_query=query req_src=src
    event on-frontend-http-request
```

Backends and the shape every frontend needs:

```
backend iocaine
    mode spop
    option spop-check
    server iocaine "/run/iocaine/iocaine.sock"

backend iocaine-output
    mode http
    server iocaine-http 127.0.0.1:42069

frontend main
    bind [::]:80

    # An incoming iocaine-decision header is proof of an untrusted client.
    acl forbidden_hdr hdr_cnt(iocaine-decision) gt 0
    http-request set-header iocaine-decision "garbage" if forbidden_hdr
    use_backend iocaine-output if forbidden_hdr

    filter spoe engine iocaine config /etc/haproxy/iocaine-spoa.cfg

    # iocaine never answered
    http-request set-var(txn.iocaine.response,ifnotset) str("borked")

    acl iocaine_passed var(txn.iocaine.response) -m str eq "default"
    acl iocaine_unavailable var(txn.iocaine.response) -m str eq "borked"

    http-request add-header Iocaine-Decision "%[var(txn.iocaine.response)]" unless forbidden_hdr

    use_backend iocaine-output if !iocaine_passed !iocaine_unavailable
    use_backend my_real_backend if iocaine_passed
```

`var(txn.iocaine.response)` is the decision: `default` serves real content,
`borked` means iocaine never answered, anything else goes to `iocaine-output`.
Keep `option forwardfor`, and set `X-Forwarded-Proto https` when TLS terminates
upstream, because the QMK rules only fire on https.

The decision reaches the output backend as `Iocaine-Decision`, but
nam-shub-of-enki reads no trusted-decision-header key (only the built-in handler
does), so that backend decides again from the same request. Divergence needs
state that changes between the two calls, and a re-decision that passes returns
the fallthrough status (421) instead of content. Route on the SPOA decision and
treat the header as informational.

## Reaching the socket

`server.spoa.unix-socket-access` is `group`, so the socket belongs to the
dynamically allocated `iocaine` group. `id iocaine` prints the gid once the unit
has started; a HAProxy outside Nix reaches the socket by running as root or by
joining that gid. When HAProxy *is* managed by Nix, the upstream module grants
the group to nginx and caddy only, so add:

```nix
systemd.services.haproxy = {
  requires = [ "iocaine.service" ];
  after = [ "iocaine.service" ];
  serviceConfig.SupplementaryGroups = [ "iocaine" ];
};
```

## Checks that need data

Add keys under `services.iocaine.settings.handler.nam-shub-of-enki.config`, and
point them at files under `/etc/iocaine` or `/var/lib/iocaine`, both outside the
Nix store:

- `sources.wordlists`, `sources."training-corpus"` → garbage and QMK sources
- `checks.ai-robots-txt.path` → the `ai-robots-txt` check
- `checks.asn.database-path` + `checks.asn.asns` → ASN check against a
  GeoLite2-ASN mmdb
- `checks.cookie-monster.forgejo-hosts`, `checks.cookie-monster.fediverse-hosts`
  → cookie-monster
- `checks.demo-host.host`, `checks.forbidden-referrers.referrers`,
  `checks.generated-urls.identifiers`, `checks.custom-agents.allow/disallow`,
  `templates.fake-jpeg`, `logging.classification.mastodon-frontend-hosts`
- `checks.enable`, `checks.disable` → force a check on or off regardless of the
  inherited ruleset

`services.iocaine.extraSettingsPaths` takes extra files passed to iocaine with
`--config-path`, merged after the generated config, for values that must not end
up in the store.

## Checks to run

```bash
nix eval --option eval-cache false '.#nixosConfigurations.jump.config.system.build.toplevel.drvPath'

# on jump
iocaine show config
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:42069/random-path/yes/   # garbage, not 404
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:42042/metrics             # 200
ss -lup | grep iocaine                                                              # SPOA socket present
```
