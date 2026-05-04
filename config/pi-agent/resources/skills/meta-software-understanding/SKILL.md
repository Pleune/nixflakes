---
name: meta-software-understanding
description: Routes software-understanding requests to the right analysis guide. Use when the user wants to inspect a codebase, understand project structure or conventions, map a ROS 2 workspace, or look up current library documentation with code examples.
---

# Meta Software Understanding

This router is the only actual skill package in this subtree. The child directories are router-owned guides, not standalone skills.

Choose the closest child guide, then read its Markdown file before proceeding.
If a child guide references a relative path, resolve it against that child guide's directory.

- [Improve Codebase Architecture](./improve-codebase-architecture/improve-codebase-architecture.md) — deep codebase exploration, module-boundary review, and refactor discovery. Triggers: architecture review, refactor candidates, shallow modules, deepening modules.
- [ROS 2 Workspace Overview](./ros2-workspace-overview/ros2-workspace-overview.md) — analyze ROS 2 packages, nodes, dependencies, and launch files. Triggers: ROS 2 workspace map, package overview, nodes, launch files.
- [Context7](./context7/context7.md) — current library and framework documentation lookup with code examples. Triggers: API docs, framework usage, current examples, library reference.

## Routing guidance

- Use [Improve Codebase Architecture](./improve-codebase-architecture/improve-codebase-architecture.md) for repository structure review, architecture mapping, module boundaries, and refactor candidates.
- Use [ROS 2 Workspace Overview](./ros2-workspace-overview/ros2-workspace-overview.md) for ROS 2 workspace discovery, package overviews, dependency mapping, and launch/run guidance.
- Use [Context7](./context7/context7.md) for library API docs, framework usage, and current code examples.
- If a task starts with an external library question and then needs local integration analysis, start with [Context7](./context7/context7.md) and then inspect the repo.
