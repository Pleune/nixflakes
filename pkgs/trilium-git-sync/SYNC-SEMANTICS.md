# Trilium Git Sync Semantics

## Goal

Define the intended sync model for `pkgs/trilium-git-sync` when git is the only transport between Trilium instances.

This document describes the target behavior for the existing exported-tree + ETAPI architecture. It is **not** Trilium native sync; it mirrors native-sync concepts where practical:

- explicit bootstrap direction
- stable note identity
- deterministic conflict behavior
- deletion intent preservation
- post-sync verification

## Current Flow Audit

The current sync loop in `trilium_git_sync/main.py` is:

1. Build the live Trilium note index.
2. Compare it to the cached previous live index.
3. Export live Trilium state to a staged export tree.
4. Commit that export to the local git worktree.
5. Rebase onto upstream.
6. Build an import plan from `oldLocalHead..rebasedHead`.
7. Apply the import plan back into live Trilium.
8. Re-export the final live state and commit it again.
9. Push if fast-forward is possible.

Important consequences:

- The current pipeline is inherently **Trilium-export-first**.
- A first sync against an existing git repo is ambiguous and unsafe unless explicitly classified as bootstrap.
- The import plan currently reasons from exported manifests and file diffs, not from Trilium-native sync metadata.
- Note identity is already stable because exported metadata carries canonical `noteId` values.

## Stable Identity Rules

1. `noteId` is the canonical identity for notes across devices.
2. Moves are represented by the same `noteId` with a different `parentNoteId` and possibly changed branch ordering metadata.
3. Renames/title changes are metadata changes on the same `noteId`.
4. Creation means a `noteId` appears in the desired git manifest but not in live Trilium.
5. Deletion means a `noteId` is intentionally absent from the desired git manifest **and** present in tombstone metadata, or is present in the old manifest and absent in the new manifest under a valid deletion transition.

## Bootstrap Direction Rules

Bootstrap must be explicit at the state-machine level, even if later exposed as automatic detection.

### Allowed bootstrap cases

#### 1. Trilium -> empty git
- Preconditions:
  - live Trilium has content
  - git export repo has no commits or no exported content
  - no previous live index is required
- Behavior:
  - export live Trilium tree
  - write metadata
  - commit/push to git

#### 2. git -> empty Trilium
- Preconditions:
  - git export repo has content/history
  - live Trilium is empty or effectively uninitialized for the configured root
  - no previous live index exists
- Behavior:
  - do **not** perform export-first deletion logic
  - treat git manifest as authoritative
  - materialize notes into Trilium top-down
  - verify resulting export matches git

### Fail-closed bootstrap cases

The sync must abort with a clear error when:

- both git and Trilium are non-empty, but there is no prior sync state proving lineage
- previous live cache is missing, but git already has history and Trilium is not empty enough to classify safely
- bootstrap direction cannot be determined without guessing

## Conflict Policy

This tool cannot safely emulate all of Trilium native sync semantics. The exported-tree architecture therefore uses a deterministic, fail-closed policy.

### Conflict definition

A conflict exists when both of these are true before reconciliation:

- live Trilium changed since the previous live-note-index cache
- git changed the same `noteId` (or a subtree that materially affects it)

### Policy

1. Non-overlapping changes may proceed normally.
2. Git-level rebase conflicts fail closed immediately.
3. Same-note semantic conflicts must fail closed unless there is a clearly defined resolver.
4. Child-order-only differences are ignorable if no other note metadata/content changed.
5. Moves across parents are supported only when a single-parent interpretation is unambiguous.

### Initial resolver scope

The implementation may safely support these cases first:

- git-created notes
- git-deleted notes
- git-driven parent moves
- git modifications to existing notes

It should still fail closed on:

- ambiguous multi-parent situations
- conflicting simultaneous delete-vs-modify cases unless explicitly resolved
- unresolved branch semantics the ETAPI cannot express reliably

## Tombstone Model

Tombstones are for **deletion tracking only**. Moves continue to rely on stable `noteId` plus changed `parentNoteId`.

### Why tombstones are needed

Absence alone is not enough to preserve deletion intent across sync runs because absence can mean:

- note intentionally deleted
- note never existed on this replica yet
- note omitted due to partial or stale metadata
- note lost during an unsafe first sync

### Minimum tombstone fields

Each tombstone should record at least:

- `noteId`
- `parentNoteId` at deletion time, if known
- `notePath` or last known directory/content path, if known
- `deletedAt` logical timestamp or export revision marker
- enough provenance to know which manifest/export revision introduced the tombstone

Optional helpful fields:

- `title`
- `type`
- subtree root marker
- deletion reason/source (`live-export-delete`, `git-import-delete`, etc.)

### Tombstone storage

Preferred approach:

- store tombstones in git-managed export metadata, alongside live metadata
- keep them in a dedicated top-level metadata section rather than mixing them into live `files`

Conceptually:

```json
{
  "files": [...live tree...],
  "sync": {
    "tombstones": [...]
  }
}
```

The exact schema can evolve, but it must:

- survive normal export/import cycles
- be stable across formatting
- remain diffable in git
- be ignored by consumers that only walk live `files`

### Tombstone pruning

Tombstones must not be removed eagerly.

Safe pruning must require confidence that:

- all replicas that matter have had a chance to observe the deletion, or
- the tombstone has been superseded by a later explicit create of the same `noteId`, or
- a configured retention policy says it is safe to drop old tombstones

Until such logic exists, prefer conservative retention.

## Create / Delete / Move Semantics

### Create
- Git manifest contains a `noteId` missing from live Trilium.
- Create notes top-down, parent before child.
- Preserve canonical `noteId` where the ETAPI allows it.
- Use staging import to materialize content, attributes, attachments, and relation rewrites.

### Delete
- Only apply deletes for topmost deleted roots.
- Use tombstones to confirm deletion intent.
- Delete subtrees in Trilium only after planning determines the delete is not actually a missing-yet-uncreated note.

### Move
- Same `noteId`, different `parentNoteId`.
- Apply via branch updates.
- Refresh ordering for affected old/new parents.
- No separate move tombstone is required.

## Verification Rules

After reconciliation, the implementation should:

1. re-export the live Trilium root
2. normalize/format metadata
3. compare the resulting manifest (and later, possibly a hash) against the expected git revision
4. fail if they differ

The post-apply export is the closest equivalent to Trilium native sync's integrity/hash check in this architecture.

## Immediate Implementation Guidance

The next implementation steps should follow this order:

1. add explicit bootstrap classification
2. add tombstone-aware metadata model
3. teach planning to distinguish intentional deletions from absence
4. support top-down creates
5. support topmost deletes and parent moves
6. add verification and focused regression tests
