# Phase 0 - Baseline, Build Control, and Remediation Traceability

## Purpose

Phase 0 establishes a recoverable, reproducible starting point before any inventory, security, synchronization, or workflow behavior is changed.

## Preserved authority

- Original submitted ZIP SHA-256: `b52662391b0cffb60cecd05198e72d0385dfb00974dbd8f9aa8d237c6d2015ba`
- Canonical merged audit SHA-256: `27df1f949fc70bb76ddbc59bf8b7de113d214960203c41235d4bf80eab067933`
- Baseline source commit: `e74db8cfa19ea156cc2c0a692668b780315c68df`
- Immutable local tag: `pre-inventory-remediation`
- Working branch: `phase0-remediation`
- Baseline source file count: 43

The original ZIP, normalized baseline source tree, and per-file SHA-256 manifest are preserved outside the remediation worktree under the Phase 0 baseline bundle. No remediation change modifies those preserved copies.

## Package/build decision

`npm` is the canonical package manager for remediation work because `package-lock.json` exactly matches `package.json`. The submitted `pnpm-lock.yaml` does not include all declared runtime dependencies and has been removed only from the remediation branch; it remains preserved in the immutable baseline tag/source snapshot.

The remediation branch declares:

- Node: `>=22.12.0 <23`
- npm: `10.9.2`
- `npm run typecheck` -> `tsc --noEmit`
- `npm run check` -> typecheck followed by production build
- `npm run phase0:verify` -> dependency/lock/config/traceability control checks that do not require installed packages

## Deterministic source blocker resolved

The submitted Vite config imports `./.figma/make/site.json`, but that file was absent from the ZIP. The remediation branch adds a neutral `{}` configuration so Vite can retain its existing built-in defaults without inventing deployment metadata.

## Build verification status

A clean dependency install was attempted. This environment could not complete network package retrieval. An explicit offline retry failed with `ENOTCACHED` for Vite. Because dependencies are unavailable here:

- `npm ci`: **not completed in this sandbox**
- `tsc --noEmit`: **blocked by missing installed `@types/node`**
- `vite build`: **not executable until dependencies are installed**

This is recorded as an environment verification limitation, not as a passing build. A clean install plus `npm run check` remains a Phase 0 exit gate on a network-enabled runner/CI environment.

## Traceability register

`docs/remediation/REMEDIATION_MATRIX.csv` contains exactly 186 audit findings. Every finding begins in `OPEN` state and includes fields for:

- severity;
- audit section;
- remediation epic;
- design/ADR;
- implementation commit/PR;
- database migration;
- regression test;
- verification evidence;
- notes.

Allowed lifecycle:

`OPEN -> DESIGNED -> IMPLEMENTED -> TESTED -> VERIFIED -> CLOSED`

A finding must not be moved to `CLOSED` without recorded implementation, applicable migration, regression test, and verification evidence.

## Phase 0 safety rules

1. Never rewrite or delete the immutable baseline tag/snapshot.
2. Never squash away evidence needed to trace a finding to its fix.
3. Database migrations are additive-first; no destructive migration without backup and reconciliation.
4. Local/offline data schemas are versioned and migrated; pending work is never silently cleared.
5. Production fixture fallbacks are removed only after a real persisted snapshot/error-state replacement exists.
6. No finding is closed by inference because a nearby architectural issue was fixed.
7. High-risk changes require regression tests at the real database/transaction boundary where applicable.

## Phase 0 exit gates

- [x] Original ZIP preserved and hashed.
- [x] Normalized baseline source preserved and hashed.
- [x] Local Git baseline initialized and tagged.
- [x] Separate remediation branch created.
- [x] 186-item remediation matrix created.
- [x] Canonical package manager selected.
- [x] Stale alternate lockfile removed from remediation branch only.
- [x] Missing Figma site config source blocker neutralized.
- [x] Package scripts for typecheck/check/Phase 0 verification added.
- [ ] Clean `npm ci` succeeds on a network-enabled clean runner.
- [ ] `npm run typecheck` succeeds with installed dependencies.
- [ ] `npm run build` succeeds with installed dependencies.
- [ ] `npm run check` is added to CI and passes from a clean checkout.

Until the four unchecked build/CI gates pass, Phase 1 architectural changes should remain blocked from merge even though design work may proceed.
