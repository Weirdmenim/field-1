# Phase 0 Verification Evidence

## Completed locally

- Original ZIP and canonical audit were hashed and preserved.
- Normalized baseline contains 43 source files.
- Baseline commit/tag exists: `pre-inventory-remediation` -> `e74db8cfa19ea156cc2c0a692668b780315c68df`.
- Remediation branch: `phase0-remediation`.
- `package-lock.json` dependency and devDependency declarations match `package.json`.
- Stale `pnpm-lock.yaml` is removed from the remediation branch while remaining preserved in the baseline tag.
- Missing `./.figma/make/site.json` is supplied as neutral `{}` configuration.
- Static relative-import check examined 83 relative imports and found zero missing paths after the site-config addition.
- The remediation matrix contains exactly 186 findings and all start as `OPEN`.
- `npm run phase0:verify` passes.
- `git diff --check` passes before commit.

## Build/install evidence

A clean dependency installation was attempted in this sandbox but could not complete network package retrieval. The explicit offline attempt failed because the required Vite package was not cached:

`ENOTCACHED: vite-8.3.0.tgz`

The global TypeScript compiler was also invoked before dependencies were installed and correctly failed because the project-required `@types/node` package is unavailable without installation.

Therefore the following are **not claimed as passing** in this environment:

- `npm ci`
- `npm run typecheck`
- `npm run build`
- `npm run check`

## CI gate

`.github/workflows/ci.yml` now runs from a clean checkout using Node 22.16.0:

1. `npm ci --no-audit --no-fund`
2. `npm run phase0:verify`
3. `npm run check`

Phase 1 implementation changes should not merge until this workflow passes in a network-enabled CI runner.
