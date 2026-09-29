# actions

Shared reusable GitHub Actions workflows for Brownserve repositories.

This repository follows the same conventions as every other Brownserve repository (see
[`.github/CONTRIBUTING.md`](.github/CONTRIBUTING.md)): Paket for dependencies, an `Invoke-Build`
based build under `.build/`, and the standard `StageRelease`/`Release` flow. Its own linting
(`actionlint`) is an Invoke-Build task, not a script, so it runs the same way locally and in CI.

## Reusable workflows

All secrets are declared explicitly under `workflow_call.secrets` and must be mapped explicitly by
the caller; this repository never uses `secrets: inherit`.

### `brownserve-pr-build.yaml`

Runs the change-detection gate and build matrix used by every generated `builds.yaml`.

Inputs: `repo-name`, `change-pattern`, `build-task` (default `BuildTestAndCheck`), `os-matrix`
(JSON array, default `["ubuntu-latest"]`), `rust`, `node`, `mono` (booleans, install the stable Rust
toolchain, Node.js 22 and Mono respectively).

Secrets: none.

Caller permissions: `pull-requests: read` (for the change check), `contents: read`.

### `brownserve-stage-release.yaml`

Inputs: `repo-name`, `release-type`, `rust` (boolean, installs Rust for `UpdateCargoVersion`).

Secrets: `app-id`, `app-private-key` (GitHub App used to generate a short-lived token for the
staging commit and pull request).

Caller permissions: none beyond what the called workflow's own jobs declare (it uses the App
token, not the caller's `GITHUB_TOKEN`).

### `brownserve-release.yaml`

Inputs: `repo-name`, `publish-to`, `package-matrix` (optional JSON array of package job includes,
each with an `os` and a `target`), `package-build-task` (default `Package`), `node`, `mono`
(booleans).

Secrets: `app-id`, `app-private-key`, `slack-webhook` (required); `nuget-api-key`,
`psgallery-api-key`, `dockerhub-username`, `dockerhub-token` (only needed for the matching
`publish-to` targets). `node` installs Node.js 22 and `mono` installs Mono. The GHCR push uses the job's own `GITHUB_TOKEN`, passed only when
`publish-to` includes `GHCR`.

Caller permissions: `contents: read`, plus `packages: write` when `publish-to` includes `GHCR`. The
release job declares no permissions of its own, so it uses whatever the calling job grants.

### `brownserve-deploy-docs.yaml`

Inputs: `engine` (`mkdocs` or `astro`), `docs-path` (default `pages`, only used for `astro`).

Secrets: none.

Caller permissions: `contents: write` (pushes to `gh-pages`).

### `brownserve-label-pr.yaml`

No inputs. Copied verbatim from the generated `label-pr.yaml` template.

Secrets: none.

Caller permissions: `issues: write`, `pull-requests: write`.

## Example: calling `brownserve-pr-build.yaml`

```yaml
name: builds
on:
  pull_request:
    branches: [main]

permissions:
  contents: read
  pull-requests: read

jobs:
  build:
    uses: Brownserve-UK/actions/.github/workflows/brownserve-pr-build.yaml@<commit-sha> # vX.Y.Z
    with:
      repo-name: my-repo
      change-pattern: '^(Cargo\.toml$|Cargo\.lock$|.*\.rs$|\.build/|\.config/|nuget\.config$)'
```

## Releases

This repository uses the standard Brownserve `StageRelease`/`Release` flow:

1. Run the `stage-release` workflow (`workflow_dispatch`), which bumps the version, updates
   `CHANGELOG.md` from merged PR labels, and opens a `release/vX.Y.Z` pull request via the GitHub
   API.
2. Review and merge that pull request.
3. Run the `release` workflow (`workflow_dispatch`), which tags the release and publishes a GitHub
   release (no assets).
