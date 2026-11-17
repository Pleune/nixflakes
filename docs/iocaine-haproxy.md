# iocaine behind HAProxy on OPNsense

`platforms/jump.nix` configures the upstream `services.iocaine` NixOS module
(`nixos/modules/services/networking/iocaine.nix`). HAProxy is not part of Nix: it
runs on the OPNsense firewall, so iocaine answers over TCP rather than a unix
socket. The gateway asks the SPOP agent for a verdict on every request and forwards
only the requests it decided to block to iocaine's HTTP output server.

Every section below is **enter this** first, **why** second.

## Ports to expose

**Enter this**

| Server | Bind | Purpose |
| --- | --- | --- |
| `http` | `[::]:42069` | produces the poisoned responses |
| `spoa` | `[::]:42070` | SPOP agent HAProxy asks for a decision |
| `metrics` | `[::]:42042` | Prometheus endpoint, persisted to `/var/lib/iocaine/metrics.json` |

Set those binds in `services.iocaine.settings.server`, drop the module's
`unix-socket-access` list, and add
`networking.firewall.allowedTCPPorts = [ 42069 42070 42042 ]`. Check with
`iocaine show config`.

**Why**

- HAProxy on FreeBSD cannot reach `/run/iocaine/iocaine.sock`, hence TCP.
- Both request-serving binds are wildcard sockets: Linux keeps `bindv6only` at 0, so
  one listener serves IPv4 and IPv6, and `allowedTCPPorts` is installed with
  `ip46tables` so the gateway can reach both families.
- Metrics is published too because Prometheus runs on the NAS and scrapes it across
  the container bridge (see *Monitoring*). Nothing authenticates the agent or the
  metrics endpoint — iocaine answers whoever asks — so keep all three ports
  unreachable from the WAN side.
- Both servers instantiate one handler declaration, `nam-shub-of-enki`
  (`pkgs.nam-shub-of-enki`, Roto, `inherits = "default"`). It disables any check
  whose required data is missing, so the default ruleset runs without wordlists, an
  ASN database, or an `ai.robots.txt` file.

## OPNsense side

The HAProxy plugin (`os-haproxy` 5.1, HAProxy 3.2) has no SPOE form fields: the
engine file is created by hand and the rest of the wiring uses pass-through options
plus the generic dialogs under Services → HAProxy → Settings → **Rules & Checks**, the
page that holds both the Rules (actions) and Conditions (ACLs) tabs. Run
`haproxy -c -f /usr/local/etc/haproxy.conf` after every change, and `haproxy -v`
before using `mode spop`.

### A. The engine file

**Enter this** — `/usr/local/etc/iocaine-spoa.cfg`, over SSH or Diagnostics → Command:

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

**Why**

- The `[iocaine]` scope name must equal the engine name in
  `filter spoe engine iocaine config ...`.
- `option var-prefix iocaine` publishes the agent's reply as
  `var(txn.iocaine.response)`, which is what the frontend ACL reads.
- `req_src` is load-bearing: iocaine's HTTP handler only sees headers, so the agent
  path synthesizes `X-Forwarded-For` from that argument
  (`iocaine/src/checkpoint_charlie.rs:124-133`). Without it the second evaluation
  sees the firewall's address as the client.
- `timeout processing` covers acquiring a stream, encoding the NOTIFY frame, waiting
  for the ack, and processing the reply (`doc/SPOE.txt:451-461`), so it bounds how
  long a request waits on the agent.

### B. Real servers and backends

**Enter this**

| Object | Settings |
| --- | --- |
| Real server `iocaine-spoa` | Address = jump's IP, Port = `42070`, TLS off |
| Real server `iocaine-http` | Address = jump's IP, Port = `42069`, TLS off |
| Health Check `iocaine-tcp` | Type = `tcp`, *Custom TCP check* **off**, Interval `2s` |
| Backend `iocaine` | Mode = `tcp`, *Enable Health Checking* on + Monitor = `iocaine-tcp`, Servers = `iocaine-spoa`, *Option pass-through* below |
| Backend `iocaine-output` | Mode = `http`, *Enable Health Checking* on + Monitor = `iocaine-tcp`, tick *X-Forwarded-For header*, Servers = `iocaine-http` |

One monitor serves both backends, and the *Custom TCP check* box must stay unchecked:
Services > HAProxy > Settings > **Health Checks** (menu item *Health Checks*), add it,
and leave the send/expect fields alone.

On the backend page the mode dropdown is labelled **Mode**; on the Public Service page
the same thing is labelled **Type**.

Servers are attached on the backend: Services > HAProxy > Settings > Backends, edit
the backend, and use the **Servers** field (a tokenizer — type the real server name
or pick it and press TAB). Real servers only define address and port. Pass-through
for the SPOP backend:

```
mode spop
option spop-check
timeout connect 5s
timeout server 3m
```

**Why**

- **X-Forwarded-For.** `option forwardfor` makes HAProxy add or extend
  `X-Forwarded-For` with the client's real IP when forwarding. Iocaine's HTTP handler
  only sees headers, so a rate limit, allowlist, or block decision would otherwise
  key on the firewall's address. Tick the backend checkbox instead of pasting the
  line; the Public Service's equivalent checkbox is marked *(deprecated)*.
- **TLS.** Leave TLS and *Verify SSL certificate* unchecked here: iocaine listens in
  plain TCP/HTTP and the plugin only emits TLS options when TLS is enabled on the
  server (or the health check itself uses SSL), so with TLS off neither box changes
  the rendered `server` line. Enable TLS and the default-checked verify adds
  `verify required` plus a `ca-file`, and the SPOP handshake fails against a
  self-signed listener. TLS *does* belong on the site's own real server, since
  Forgejo terminates TLS (`PROTOCOL = "https"` with `KEY_FILE`/`CERT_FILE`), and
  `verify required` there needs the issuing CA imported on OPNsense. Services >
  HAProxy > Settings also has a global SSL-verification option that overrides the
  per-server checkbox.
- `mode spop` exists only in HAProxy 3.1+ (`PR_MODE_SPOP`); on 3.0 and older it fails
  with `unknown proxy mode 'spop'`, so on old versions leave the GUI mode at TCP and
  drop the line. The GUI writes its own `mode` line before pass-through, and HAProxy
  applies the last `mode` seen, so `mode spop` wins.
- **Health checks.** Turn them on, but understand what the monitor is for: the plugin
  adds `check` to the `server` line only when a backend has a monitor attached and
  *Enable Health Checking* ticked, and its monitor list has no `spop` type
  (`tcp`/`http`/`agent`/`ldap`/`mysql`/`pgsql`/`redis`/`smtp`/`esmtp`/`ssl`). The
  monitor therefore only switches checking on; the check itself stays the SPOP
  handshake from `option spop-check` in pass-through, which sends the HAProxy hello
  plus `healthcheck` K/V (`src/flt_spoe.c:1061`) and requires an agent hello back
  (`src/flt_spoe.c:1104`). Ticking *Custom TCP check* would emit `option tcp-check`
  with send/expect rules and replace that SPOP ruleset, so leave it off. A real check
  matters here: with no server up, `spoe_create_appctx` skips the filter entirely
  (`src/flt_spoe.c:2029`), so requests go straight to the site instead of waiting on
  connect timeouts, and the GUI shows the agent as down instead of silently passing
  traffic.
- A monitor that reads down while `nc -z <jump-ip> 42070` succeeds is almost always the
  real server's **Port to check** field, which overrides the server's own port. Set it
  to the port you actually want probed, or leave it alone, rather than debugging the
  agent.
- Probed against jump's live agent with HAProxy 3.4.7 (the nixpkgs build; OPNsense runs
  3.2.x) using `check inter 2s` on each server: `option spop-check` on the SPOA port is
  **UP**, a plain TCP monitor on the HTTP output port is **UP**, and `option spop-check`
  on the HTTP output port is **DOWN** — that port speaks HTTP, not SPOP, so the hello
  never gets an answer. iocaine replies to any HAProxy hello with an agent hello
  (`version 2.0.0`, the offered `max_frame_size`, `capabilities = [Pipelining]`) and
  closes the connection when the hello carried `healthcheck`
  (`iocaine/src/checkpoint_charlie.rs:73-84`, `:215-224`), which is the pass condition in
  `spoe_handle_healthcheck_response`.
- Use the TCP monitor for `iocaine-output` rather than an HTTP one. `option httpchk`
  sends a real request into the honeypot, and nam-shub answers a legitimate-looking
  request with `421`, so a `status 200` expectation marks the honeypot permanently
  down and blocked traffic then gets `503` from HAProxy instead of poison.
- `option spop-check` needs `timeout connect` above it and `timeout server` above the
  agent's idle timeout; both are in the pass-through block above.
- Rendering: backend pass-through lands at the end of the backend section; an ACL of
  type *Custom condition (option pass-through)* becomes `acl acl_<uuid> <your text>`;
  a rule of type *Custom rule (option pass-through)* is emitted verbatim, so do not
  link conditions to it — the plugin appends them after the raw text.

### C. Frontend

**Enter this** — four pieces, and only one of them goes in a pass-through box.

1. On the Public Service (Services → HAProxy → Settings → Public Services), which is
   the page holding **Listen Addresses**, put exactly one line in *Option pass-through*:

   ```
   filter spoe engine iocaine config /usr/local/etc/iocaine-spoa.cfg
   ```

   Nothing else goes in this box. Rules and switching go in the GUI because the plugin
   renders pass-through text after them; putting an `http-request` rule there also earns
   a warning (`a 'http-request' rule placed after a 'use_backend' rule will still be
   processed before`).

2. Condition (Settings → **Rules & Checks**, Conditions tab): Name `iocaine-blocked`,
   Condition type *Custom condition (option pass-through)*, and the expression goes in
   the field labelled *Option pass-through* at the bottom of the dialog:

   ```
   var(txn.iocaine.response) -m reg ^(garbage|challenge:)
   ```

   *Negate condition* and *Case-sensitive* are both left alone: for a custom condition
   the plugin emits the text verbatim and adds no `-i`, so those checkboxes change
   nothing, and HAProxy regex matching is case-sensitive unless you write `-i` yourself.

2b. Condition for every host that must never be blocked, e.g. Name `emby-host`,
   Condition type *Host matches regular expression*, value
   `^emby\.pleunetowne\.com(:[0-9]+)?$`, and *Negate condition* ticked. Tick
   *Negate condition* rather than writing a negated expression: the plugin puts the `!`
   in the rule (`/tmp/haproxy.tmpl` pushes `'!acl_' ~ id` when `negate == '1'`), which is
   the only way this works, since an `acl` line cannot negate a fetch. Leave
   *Case-sensitive* alone so the plugin adds `-i`. Give each exempt host its own
   condition, or widen the regex to an alternation.

3. Rules (Settings → **Rules & Checks**, Rules tab), two of them:

   - `iocaine-proto` — Type *http-request*, Action *set-header*, header name
     `X-Forwarded-Proto`, value `https`.
   - `iocaine-poison` — Type *Use specified Backend Pool*, *Use backend pool*
     `iocaine-output`, *Match Mode* *IF [default]*, *Logic Operator* *AND [default]*,
     *Select conditions* `iocaine-blocked` **and** every negated host condition such as
     `emby-host`. Logic stays AND: the rule fires only on a block verdict for a host
     that is not exempt.

   Both *Enabled*.

4. Attach both rules to the Public Service: edit it and put `iocaine-proto` and
   `iocaine-poison` at the **top** of *Select Rules*, above every SNI rule, poison
   before proto. Conditions are never attached to a service — only rules are — and
   *Select Rules* is a sortable list, so its order is the order HAProxy evaluates.

There is no `my_real_backend` to create: unblocked traffic matches nothing and falls
through to the SNI rule that already names the site's backend. Rendered equivalent:

```
backend iocaine
    mode tcp
    mode spop
    option spop-check
    timeout connect 5s
    timeout server 3m
    server iocaine-spoa 10.0.0.2:42070 check

backend iocaine-output
    mode http
    option forwardfor
    server iocaine-http 10.0.0.2:42069 check

frontend main
    bind [::]:443 ssl
    acl acl_iocaine_blocked var(txn.iocaine.response) -m reg ^(garbage|challenge:)
    acl acl_emby_host hdr_reg(host) -i ^emby\.pleunetowne\.com(:[0-9]+)?$
    acl acl_sni_git ssl_fc_sni git.example.com
    http-request set-header X-Forwarded-Proto https
    use_backend iocaine-output if acl_iocaine_blocked !acl_emby_host
    use_backend Git if acl_sni_git
    filter spoe engine iocaine config /usr/local/etc/iocaine-spoa.cfg
```

`haproxy -c -f /usr/local/etc/haproxy.conf` should print `Configuration file is valid`
with no config warnings. Notices about unrelated backends failing to resolve are a DNS
problem on that host, not an iocaine problem; the two iocaine servers resolve or HAProxy
says so by disabling them.

**Why**

- Switching rules go in the GUI, never in the pass-through box: the plugin renders
  pass-through text *after* every GUI rule, and HAProxy evaluates `use_backend` in
  declaration order, first match winning. Pasted rules land under the SNI rules and
  never fire, so every blocked request still reaches the real app.
- `option forwardfor` on `iocaine-output` is not optional. The SPOA path learns the
  client address from the `req_src` argument, but the HTTP path reads headers, so
  without X-Forwarded-For the re-evaluation sees the firewall's address and every
  IP-keyed rate limit, ban and allowlist applies to OPNsense instead of the client.
- The `filter` line renders last and still runs first: SPOE events fire just before
  `http-request` rules are evaluated (`doc/SPOE.txt:75-78`, `:1088-1091`), which is
  what lets the ACL see the verdict. Same rule order means `X-Forwarded-Proto https`
  is added after the SPOA snapshot, so it reaches `iocaine-output` and the
  re-evaluation there rather than the agent; on the agent path iocaine rebuilds
  `X-Forwarded-For` from `req_src`. Any https-keyed check therefore only bites on the
  second evaluation.
- HAProxy has no `-m defined` matching method — the "this fetch returned something"
  test is `-m found` — and an `acl` line cannot negate a fetch. Negation belongs on
  the ACL (*Negate condition*, or `!acl_<uuid>` in a rule). Pasting
  `acl borked var(txn.iocaine.error) -m defined` and
  `acl borked !var(txn.iocaine.response) -m defined` fails the whole config:

  ```
  error detected while parsing ACL 'borked' : unknown matching method 'defined' when parsing ACL expression.
  error detected while parsing ACL 'borked' : missing fetch method in ACL expression '!var(txn.iocaine.response)'.
  error detected while parsing switching rule : no such ACL : 'borked'.
  ```

- HAProxy answers with one transaction variable, `response`, set only when a handler
  succeeds (`iocaine/src/checkpoint_charlie.rs:159-167`), so `option var-prefix
  iocaine` presents it as `var(txn.iocaine.response)`. Its value is whatever the
  handler returned, and nam-shub-of-enki returns one of three strings
  (`main/nam_shub_of_enki/verdicts.roto`):

| Value | Meaning | Route |
| --- | --- | --- |
| `not-for-us` | legitimate client | no rule matches, so the SNI rule picks the real backend |
| `garbage` | scraper | `iocaine-output` |
| `challenge:<name>` | nam-shub wants a challenge issued | `iocaine-output` |
| *nothing* | agent failed, timed out, or unreachable | same as `not-for-us` |

- Matching only the two block verdicts, rather than "everything except `not-for-us`",
  is what makes the wiring fail open (see below). The upstream guide's `eq "default"`
  matches the built-in handler, not this one; with nam-shub-of-enki that ACL never
  matches and every request looks like a scraper.
- An exempt host is exempt from *routing*, not from *evaluation*. `filter` lines take no
  ACL conditions, so the agent still sees that host's requests and still logs and counts
  them; the negated ACL just throws the verdict away. That costs one LAN round trip per
  request and no risk of poison. To keep a host out of iocaine entirely it needs its own
  Public Service on a distinct address or port without the `filter` line — two frontends
  cannot share one `bind`.

## Routing behaviour

### One evaluation, or two

**Enter this** — nothing beyond the rule above. If a client of yours gets poisoned,
add it to `checks.custom-agents.allow` on jump, which answers `not-for-us`.

**Why**

- Legitimate traffic is evaluated once: the SPOA replies `not-for-us`, HAProxy
  switches to the real backend, and the payload never reaches iocaine.
- Blocked traffic is evaluated twice: the SPOA replies `garbage` or
  `challenge:<name>`, HAProxy forwards the whole request to `iocaine-output`, and
  nam-shub-of-enki re-runs its rules on the forwarded request before choosing the
  poison or challenge. It reads no trusted-decision-header key, unlike the built-in
  handler, so the `Iocaine-Decision` header is informational only.
- A browser-shaped User-Agent with no browser headers is a disguise:
  `browser-verification` answers `garbage` with reason `faked-browser` for a
  Firefox-shaped User-Agent carrying no `Sec-Fetch-Mode` and no `Sec-GPC`
  (`main/nam_shub_of_enki/detect/mod.roto:98-120`), while `curl/8.5.0`,
  `python-requests/2.32.3`, and an absent User-Agent get the fallthrough.

### 421 Misdirected Request

**Enter this** — no HAProxy rule. Do not add a retry to the real backend on a `421`;
the status comes from nam-shub-of-enki's fallthrough setting
(`org/module/responses.org:44`, surfaced as `fallthrough: 421` in
`iocaine show config`).

**Why**

- Because the output backend re-decides, the two evaluations can disagree: a rate
  limit that expires, or an allowlist edit landing between the SPOA call and the HTTP
  call, makes the second evaluation answer `not-for-us`. The HTTP handler then has
  nothing to serve, returns `421 Misdirected Request`, and HAProxy hands that to the
  client.
- There is no fallback on purpose. Forwarding to `iocaine-output` consumes the HTTP
  body, so HAProxy cannot replay a POST without buffering and re-sending it; that
  would corrupt form submissions and add a round trip to traffic that already passed
  the agent. The `421` is the safety valve: one retry from a cooperative client,
  instead of poison served to a real user.

### Fail open when the agent is silent

**Enter this** — optional only: `option set-on-error error` in the engine file if you
want to log or count agent failures. Leave `option continue-on-error` off.

**Why**

- `borked` was a name invented in an earlier draft of this document; it is not a value
  iocaine sends, and HAProxy creates no error variable unless the agent declares one
  with `option set-on-error <name>` (`doc/SPOE.txt:300-313`, published as
  `txn.<prefix>.<name>`, an integer code). Nothing routes on it.
- The one rule that switches to `iocaine-output` matches block verdicts only, so every
  other outcome — `not-for-us`, a handler error returned as an SPOP error frame
  (`iocaine/src/checkpoint_charlie.rs:159-162`), a processing timeout, an agent that
  is down — leaves `iocaine-blocked` false and traffic takes its normal SNI route. An
  iocaine outage cannot take the site down.
- On an abnormal error HAProxy also disables the SPOE filter for the rest of that
  transaction (`doc/SPOE.txt:1185-1192`), so a broken agent stops costing a round trip
  per request. `option continue-on-error` keeps later events processing at the price
  of a stale variable shadowing a later verdict.
- Health checking on the SPOP backend is part of this fail-open story. When no agent
  server is up, `spoe_create_appctx` creates no appctx at all
  (`src/flt_spoe.c:2029`), so requests skip the filter instead of waiting on connect
  timeouts; without checks HAProxy keeps trying a dead agent on every request.

### Exempting a host from blocking

**Enter this** — the condition and rule change from step 2b and step 3 above: one
negated host condition per exempt host, added to `iocaine-poison`'s *Select conditions*
with Logic *AND*. Rendered:

```
acl acl_iocaine_blocked var(txn.iocaine.response) -m reg ^(garbage|challenge:)
acl acl_emby_host hdr_reg(host) -i ^emby\.pleunetowne\.com(:[0-9]+)?$
use_backend iocaine-output if acl_iocaine_blocked !acl_emby_host
```

**Why**

- Matching on `hdr(host)` rather than `ssl_fc_sni` is deliberate: the exemption has to
  bite on the plain-HTTP frontend too, where there is no SNI, and on any request that
  reaches the frontend by IP with a Host header.
- The regex anchors the whole value and allows an optional `:port`. `hdr(host)` exact
  matching would miss `emby.pleunetowne.com:8443`-style values, and a loose substring
  match would exempt `emby.attacker.example`.
- Do not solve this by ordering an emby `use_backend` rule above the poison rule. It
  works, but it duplicates the per-site switching rule, and any later exempt host means
  another rule above the poison rule — a list whose order silently decides which sites
  iocaine can protect at all. One AND list on the poison rule keeps the exemption in one
  place.
- The agent still evaluates exempt traffic. `filter` statements take no ACL conditions,
  so requests to emby still cost an SPOP round trip and still show up in iocaine's logs
  and metrics; only the routing decision is discarded. nam-shub-of-enki has no
  pass-by-host allowlist — `checks.demo-host` does the opposite
  (`org/module/detection/demo_host.org:12-13` returns `verdicts.garbage` for its
  configured host), and `checks.cookie-monster.fediverse-hosts` /
  `forgejo-hosts` scope an anti-bot check rather than exempting a host — so there is
  nothing to set on the iocaine side.
- Exempting a host means what it says: that host has no bot protection, no honeypot trap,
  and no 421 safety valve, because its traffic never reaches `iocaine-output`. Keep the
  list short.
- Check it by requesting the honeypot path on the exempt host, which is the one path
  iocaine always blocks:

  ```
  curl -sS -o /dev/null -w '%{http_code}\n' https://emby.pleunetowne.com/guestbook-7c4b59dd/
  ```

  Expect emby's own answer (a redirect or its 404), never a poisoned page. Compare with
  the same path on a protected host, which does poison:

  ```
  curl -sS https://git.pleunetowne.com/guestbook-7c4b59dd/ | sed -n '1,8p'
  ```

## Honeypot links

**Enter this** — the bait is a token that has to match in exactly two places. On git,
`platforms/git.nix`:

```nix
honeypotToken = "guestbook-7c4b59dd";
forgejoBait = pkgs.writeTextDir "templates/custom/extra_links_footer.tmpl" ''
  <a href="/${honeypotToken}/" class="tw-hidden">Guestbook</a>
  <a href="/cgi-bin/guestbook.pl" class="tw-hidden">Visitor log</a>
'';
```

with `preStart` (merged with `pkgs.lib.mkAfter`) installing that file into
`${config.services.forgejo.customDir}/templates/custom/`, both `install` calls omitting
`-o`/`-g`, and `restartTriggers` set to the bait. On jump, `platforms/jump.nix`:

```nix
checks.generated-urls.identifiers = [ "+" "guestbook-7c4b59dd" ];
```

Keep Forgejo's `[server] LANDING_PAGE` at its default `home`, or an anonymous crawler
lands somewhere without the footer. `/cgi-bin/guestbook.pl` needs no config. To add
more bait, put the token in `identifiers` and the link in `forgejoBait`; the two must
match exactly, and matching is substring, not regex.

**Why**

- Iocaine started life as a tarpit and the poison pages are part of that: every link in
  a generated page is prefixed with a poison id (`org/module/templates/html.org:139-141`)
  and the `generated-url` check matches that id as a substring of the path *or* the
  Referer (`org/module/detection/generated_urls.org`), which is what makes the maze
  infinite. `+` expands to the auto-generated id nam-shub-of-enki keeps in its state
  file (`org/module/configuration_loading.org:277-293`), so your ids are added alongside
  it rather than replacing it.
- `cgi-bin-trap` is enabled by default and matches any path starting with `/cgi-bin`.
- `tw-hidden` hides the links from humans but not crawlers; do not add `rel="nofollow"`,
  since the point is that a crawler follows them.
- `services.forgejo` has no template option, so the file is dropped into `customDir`:
  Forgejo's `assetfs.Local("custom", setting.CustomPath, "templates")`
  (`modules/templates/base.go:19`) overrides the empty placeholder it ships at
  `templates/custom/extra_links_footer.tmpl`, which `templates/base/footer_content.tmpl:30`
  includes on every page with a footer. The `install` flags matter: the unit runs as the
  Forgejo user with `CapabilityBoundingSet = ""`, `NoNewPrivileges` and `PrivateUsers`,
  so a chown there dies with `Bad system call` (`status=159`) and Forgejo never starts.
  Forgejo docs call custom templates unsupported and warn updates break them without
  notice; overriding an empty placeholder is the least breakable version of that. The
  same placeholders cover a whole landing page — `templates/custom/header`
  (`base/head.tmpl:29`), `templates/custom/extra_links` (`base/head_navbar.tmpl:48`),
  `templates/custom/extra_links_footer` (`base/footer_content.tmpl:30`) — with
  `LANDING_PAGE = custom` pointing at a path only the bait advertises.
- Detection lives entirely on jump: the SPOA sees the bait path, answers `garbage`, and
  HAProxy forwards to `iocaine-output`, where the second evaluation serves the poison.
  Forgejo never sees the request and never talks to iocaine — hence a token in
  `identifiers` rather than a real page. A crawler that follows a bait link and keeps
  browsing is poisoned too, because the Referer check matches the same substring.
  Anything else you want poisoned must be traffic the gateway fronts.
- Repeat hits on `generated-url` are what `firewall.block-rule-hits` names as a blocking
  trigger (default in nam-shub-of-enki's `minimal()`), but
  `services.iocaine.settings.firewall.enable = false` on jump keeps it inert: iocaine's
  firewall installs nftables sets (`table inet iocaine`, `blocks_v4`/`blocks_v6`, 4h
  timeout, `src/vaccine.rs:14-60`), needing nftables and `CAP_NET_ADMIN` inside this LXC
  container, and dropping at the container's input hook would cut off Forgejo as well.
  Blocking also ends the poisoning, so upstream treats it as a last resort.

## Poison corpus

**Enter this** — `platforms/jump.nix` fetches public-domain books, cuts the Gutenberg
header and licence footer, publishes the result at `/etc/iocaine/corpus`, and points both
Markov sources at it:

```nix
let
  # poisonCorpus = pkgs.runCommand "iocaine-poison-corpus" { } ''…'' — the stripping
  # step, defined in platforms/jump.nix
  corpusPaths = map (name: "/etc/iocaine/corpus/${name}") [
    "alice-in-wonderland.txt"
    "a-tale-of-two-cities.txt"
    "oliver-twist.txt"
    "huckleberry-finn.txt"
    "the-time-machine.txt"
  ];
in
{
  environment.etc."iocaine/corpus".source = poisonCorpus;

  services.iocaine.settings.handler.nam-shub-of-enki.config = {
    inherits = "default";
    sources.training-corpus = corpusPaths;
    sources.wordlists = corpusPaths;
  };

  systemd.services.iocaine.restartTriggers = [ pkgs.nam-shub-of-enki poisonCorpus ];
}
```

Nothing on OPNsense changes: the corpus is a jump-side input to the same handler.

**Why**

- With no corpus, nam-shub-of-enki falls back to `MarkovChain.default()`
  (`org/module/sources.org:26-33`), and iocaine's default corpus is its own embedded
  Rust and Lua source (`iocaine-powder/src/bullshit/mod.rs`, the `#[folder = "src/"]`
  and `#[folder = "embeds/"]` Embed structs). The symptom is a well-formed poisoned page
  whose prose is source code: `<title>Accept", options.table_name.</title>`,
  `Val<MutableVector>) -> Opt`, `/// Returns [`VibeCodedError`] if the path`.
- Every string on a poison page comes out of `MARKOV` — title
  (`org/module/templates/html.org:132`), description (:136), paragraphs (:173, :207),
  link text (:209), list items (:232) — so a bad corpus is a bad page everywhere, and
  there is no template bug to chase.
- `fetchurl` points at Wayback Machine snapshots (`web.archive.org/web/<timestamp>id_/…`)
  instead of gutenberg.org, which answers `403 Forbidden` to some egress addresses. The
  `id_` modifier serves the archived bytes without Wayback's own chrome, and pinning the
  capture timestamp is what keeps the `fetchurl` hash stable: `nix-prefetch-url` on the
  pinned URL, then `nix hash convert --hash-algo sha256 --to sri <hex>` for the
  `hash = "sha256-…"` field. Re-fetching a pinned capture is byte-identical; following a
  `…/2020id_/…` redirect is not, so hash the URL the redirect resolves to, not the
  redirect itself.
- `poisonCorpus` drops the licence header, the licence footer, the trailing
  `End of Project Gutenberg …` line, the byte-order mark and CRLF, so none of it can
  surface inside a poisoned page.
- The corpus is store data symlinked under `/etc/iocaine`, beside the generated
  `iocaine.json`. The unit runs `ProtectSystem=strict`, which makes the filesystem
  read-only but leaves `/etc` readable, and a `DynamicUser` service can follow the
  symlink into the store.
- `restartTriggers` has to name the corpus. The generated config only lists the
  `/etc/iocaine/corpus/…` paths, which never change, so swapping books or re-stripping
  them would otherwise leave the old Markov chain running until the next unrelated
  restart.
- `sources.wordlists` gets the same files. WORDLIST feeds the generated link paths
  (`org/module/templates/html.org:148,152,157,208,231`) and the JavaScript identifiers
  (`org/module/templates/js.org:18-19`), and its default is the same embedded source:
  roto's `WordList.default()` calls `GargleBargle::default()`
  (`iocaine-powder/src/sex_dungeon/means_of_production/bullshit/garglebargle.rs:37-40`),
  which builds its list from `SquashFS::iter()`
  (`iocaine-powder/src/bullshit/garglebargle.rs:14-26`) — the crate's own source plus the
  embedded handler files and the `iocaine-label` word list
  (`iocaine-label/src/lib.rs:17-20`). Leaving it unset keeps code-shaped path fragments
  and identifiers even once the Markov chain is trained on prose.
- Verified by running the packaged `iocaine 3.5.1` with this handler config and the
  stripped corpus locally: the poisoned page came up in about a second with prose
  (`Doctor. “Blathers and Duff, being rewarded with a spade, at first. He'll never
  know.`) instead of source fragments, and `WordList.new` on 2.6 MB of prose added no
  measurable start-up cost.

## Checks that need data

**Enter this** — keys under
`services.iocaine.settings.handler.nam-shub-of-enki.config`, pointing at files under
`/etc/iocaine` or `/var/lib/iocaine` rather than at store paths written by hand:

- `sources."training-corpus"` → the Markov chain; `sources.wordlists` → the link-path and
  identifier word list. Both point at `/etc/iocaine/corpus/…` here, which is a symlink
  into the store (see *Poison corpus*).
- `checks.ai-robots-txt.path` → the `ai-robots-txt` check
- `checks.asn.database-path` + `checks.asn.asns` → ASN check against a GeoLite2-ASN mmdb
- `checks.cookie-monster.forgejo-hosts`, `checks.cookie-monster.fediverse-hosts` → cookie-monster
- `checks.demo-host.host`, `checks.forbidden-referrers.referrers`,
  `checks.generated-urls.identifiers`, `checks.custom-agents.allow/disallow`,
  `templates.fake-jpeg`, `logging.classification.mastodon-frontend-hosts`
- `checks.enable`, `checks.disable` → force a check on or off regardless of the
  inherited ruleset

`services.iocaine.extraSettingsPaths` takes extra files passed to iocaine with
`--config-path`, merged after the generated config.

**Why**

- nam-shub-of-enki disables a check whose required data is missing, so an unset source
  costs nothing and a wrong path silently turns one check off.
- `extraSettingsPaths` exists for values that must not end up in the store.

## Checks to run

```bash
nix eval --option eval-cache false '.#nixosConfigurations.jump.config.system.build.toplevel.drvPath'

# on jump
sudo iocaine show config -c /etc/iocaine/iocaine.json
ss -ltnp | grep -E '42042|42069|42070'                                  # :42069, :42070, :42042
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:42069/random-path/yes/   # garbage, not 404
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:42042/metrics             # 200
# the bait paths answer garbage, and the bait shows up in a rendered page
curl -s http://127.0.0.1:42069/guestbook-7c4b59dd/ | head -5
curl -s http://127.0.0.1:42069/cgi-bin/guestbook.pl | head -5

# poison prose comes from the corpus, not from iocaine's own source
ls /etc/iocaine/corpus                                              # five books
sudo iocaine show config -c /etc/iocaine/iocaine.json | grep -A8 training-corpus
curl -s http://127.0.0.1:42069/guestbook-7c4b59dd/ | sed -n '1,12p'  # sentences, not code

# on git: the bait is installed where Forgejo reads custom templates
ls -l /var/lib/forgejo/custom/templates/custom/extra_links_footer.tmpl
curl -s https://git.pleunetowne.com/ | grep -c guestbook-7c4b59dd   # 1

# on OPNsense: both ports reachable, and the generated config parses
nc -z <jump-ip> 42070 && nc -z <jump-ip> 42069
haproxy -c -f /usr/local/etc/haproxy.conf

# exempt hosts never poison, not even on a path iocaine always blocks
grep -n 'use_backend iocaine-output' /usr/local/etc/haproxy.conf   # ends in !acl_<emby-host>
curl -sS -o /dev/null -w '%{http_code}\n' https://emby.pleunetowne.com/guestbook-7c4b59dd/
curl -sS https://git.pleunetowne.com/guestbook-7c4b59dd/ | sed -n '1,8p'   # still poisoned
```

Through the frontend, a scraper request should return poison and a real browser should
reach the application. If everything is poisoned, the ACL is comparing against a verdict
nam-shub-of-enki never returns; check the rendered config and the engine file's
`option var-prefix`. If a legitimate request comes back `421`, the two evaluations
disagreed and the safety valve worked.

## Monitoring

**Enter this** — three pieces, no agent other than Alloy:

```nix
# platforms/jump.nix
services.iocaine.settings.server.metrics = {
  bind = "[::]:42042";
  mode = "prometheus";
  persist-path = "/var/lib/iocaine/metrics.json";
  persist-interval = "10m";
};
networking.firewall.allowedTCPPorts = [ 42069 42070 42042 ];

services.alloy.enable = true;
environment.etc."alloy/config.alloy".text = ''
  loki.relabel "journal" {
    forward_to = []
    rule { source_labels = ["__journal__systemd_unit"] target_label = "unit" }
    rule { source_labels = ["__journal_priority_keyword"] target_label = "priority" }
  }
  loki.source.journal "journal" {
    forward_to = [loki.write.loki.receiver]
    relabel_rules = loki.relabel.journal.rules
    labels = { host = "jump" }
  }
  loki.write "loki" {
    endpoint { url = "http://nas.home.pleunetowne.com:3030/loki/api/v1/push" }
  }
'';
```

```nix
# platforms/nas.nix
services.loki.configuration.server.http_listen_address = "::";   # was "::1"
services.prometheus.scrapeConfigs = [
  # …node and zfs jobs…
  { job_name = "iocaine";
    static_configs = [{ targets = [ "jump.home.pleunetowne.com:42042" ]; }]; }
];
```

Validate the Alloy config before deploying it:

```bash
nix build --impure --no-link --print-out-paths \
  --expr '(builtins.getFlake "/home/mitch/nixflakes").inputs.nixpkgs.legacyPackages.x86_64-linux.grafana-alloy' \
  | xargs -I{} sh -c 'export PATH=$PATH:{}; alloy validate /etc/alloy/config.alloy'
```

**Why**

- `services.alloy` is the option name (`nixos/modules/services/monitoring/alloy.nix`),
  and the unit runs with `SupplementaryGroups = [ "systemd-journal" ]`, which is what
  lets it read the container's journal. promtail is gone from this nixpkgs
  (`platforms/nas.nix` still carries the commented-out block and a FIXME).
- `alloy validate` is the only cheap check: `alloy fmt` accepts nonsense, and the
  labels stage in particular has no `rules` attribute — journal fields arrive as
  internal `__journal_*` labels that Alloy drops unless `relabel_rules` renames them.
- Loki pushed its listener to `::` because a container pushing to a loopback socket
  reaches the container, not the NAS. `firewall.trustedInterfaces = [ "br0" ]` is
  what makes that acceptable: the bridge is where the containers live.
- Scrape by name, not by `192.168.10.5`, matching the `llm.nix` host-naming
  convention; Prometheus and the NAS share the same resolver.
- `labels = { host = "jump" }` plus Alloy's automatic `job` label is what distinguishes
  this container's logs from the NAS's own once both are in one Loki.

```bash
# on jump
curl -s http://127.0.0.1:42042/metrics | grep -c '^iocaine'      # counters present
systemctl status alloy.service
# on nas
curl -s 'http://localhost:9090/api/v1/targets' | grep -o '"job":"iocaine"[^}]*"health":"[a-z]*"'
curl -sG 'http://localhost:3030/loki/api/v1/query' --data-urlencode 'query={host="jump"}' | head -c 300
```

A target stuck `unhealthy` is a bridge or firewall problem, not an iocaine one:
`nc -z jump.home.pleunetowne.com 42042` from the NAS answers `open` when the port is
published and allowed. No Loki stream means Alloy cannot authenticate to the journal —
check that the container has `systemd-journal` group membership, not the config.
