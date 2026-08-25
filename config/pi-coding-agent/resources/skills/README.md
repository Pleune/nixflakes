# Pi skill authoring guide

This directory is organized to keep startup prompt context small.

Top-level skills should stay few and stable. Specialized guidance should usually live under `meta-*` router skills so the agent only loads detailed instructions on demand.

## Decide where a new capability goes

1. If it is broadly useful across many unrelated sessions and worth direct discovery, make it a top-level utility skill.
2. Otherwise, place it under the best matching `meta-*` router.
3. Under a router, prefer a router-owned child guide instead of another skill package.
4. If no router fits, prefer broadening an existing router before creating a new one.
5. Create a new router only when it will own a real family of related child guides.

## Top-level rules

Top-level entries in this directory must be one of:

- a `meta-*` router skill, or
- a global utility skill.

Global utility skills stay top-level only.
Do not also place them under a meta router.

## Meta router rules

- Router directories use the `meta-` prefix.
- A router owns only the child guides nested beneath its own directory.
- Do not use a router to point at top-level utility skills.
- Keep one canonical copy of each capability. Do not duplicate the same capability in multiple places.
- Singleton routers are allowed when they represent an intentional workflow bucket.
- Router descriptions should mention key children, but stay concise to avoid prompt bloat.
- Put detailed routing logic and child links in the router `SKILL.md`, not in the description frontmatter.
- The router `SKILL.md` owns the routing metadata for child guides: name, purpose, triggers, and link.

## Child guide rules

Child guides under a router are not standalone skills.

- Keep each child in its own directory.
- Name the main child document after the directory, such as `context7/context7.md` or `liquid-glass/liquid-glass.md`.
- Do not use `SKILL.md` for child guides.
- Do not add skill frontmatter to child guides.
- Keep child-specific scripts, templates, references, and assets in the same child directory.
- If a child guide references a relative path, write it relative to that child directory.

When converting a former child skill into a child guide, move its name/description trigger information up into the router `SKILL.md` and keep the remaining instructions in the child Markdown file.

## Promote a capability to top level only when

- it is broadly useful across many sessions,
- it is uniquely valuable as a direct discovery target, and
- it is worth paying for in startup prompt space.

If those conditions are not met, keep it under a router.

When promoting or demoting a capability, move the canonical directory instead of copying content.

## Create a new router only when

- the grouped capabilities share a clear trigger surface,
- the router would make routing easier for the agent, and
- the router meaningfully reduces top-level prompt clutter.

If a new capability mostly fits an existing router, place it there instead of creating a new router.

## Placement note for future setup guides

Future Nix flake, devshell, and related setup guides belong under `meta-software-implementation`.
