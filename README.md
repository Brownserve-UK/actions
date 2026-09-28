# actions

Shared composite actions and reusable GitHub Actions workflows for Brownserve repositories.

This repository follows the same conventions as every other Brownserve repository (see
[`.github/CONTRIBUTING.md`](.github/CONTRIBUTING.md)): Paket for dependencies, an `Invoke-Build`
based build under `.build/`, and the standard `StageRelease`/`Release` flow. Its own linting
(`actionlint`, `zizmor`) and internal reference bumping are implemented as Invoke-Build tasks, not
scripts, so they run the same way locally and in CI.

## Composite actions

### `setup-toolchains`

Installs the Rust, Node.js and/or Mono toolchains used by Brownserve build scripts.

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `rust` | No | `false` | Install the stable Rust toolchain via `rustup`. |
| `node` | No | `false` | Install Node.js via `actions/setup-node`. |
| `node-version` | No | `22` | Node.js version, used when `node` is `true`. |
| `mono` | No | `false` | Install Mono (needed to run `NuGet.exe` on Linux). |

No secrets or extra permissions required.

### `run-build`

Checks out a repository at the `<repo-name>` path convention and calls its `.build/build.ps1`.

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `repo-name` | Yes | | The GitHub repo name, also used as the checkout path. |
| `checkout-token` | No | `github.token` | Token used to check out the repo. |
| `fetch-depth` | No | `1` | Passed to `actions/checkout`. Use `0` when the build reads the changelog. |
| `branch-name` | No | `github.ref` | Branch this is being built from. |
| `build` | Yes | | The build to run, e.g. `BuildTestAndCheck`, `StageRelease`, `Package` or `Release`. |
| `release-type` | No | | `major`, `minor` or `patch`. |
| `publish-to` | No | | Same format as the release workflow input, e.g. `"nuget", "PSGallery", "GitHub"`. |
| `github-repo-owner` | No | | Owning org/account, uses the build script's default when not set. |
| `github-stage-release-token` | No | | Token for `StageRelease`. |
| `github-release-token` | No | | Token for `Release`. |
| `nuget-feed-api-key` | No | | NuGet feed API key. |
| `psgallery-api-key` | No | | PowerShell Gallery API key. |
| `dockerhub-username` | No | | DockerHub username. |
| `dockerhub-token` | No | | DockerHub token. |
| `ghcr-token` | No | | Token used to push to GHCR. |
| `target` | No | | Target to package for. |
| `archive-source-directory` | No | | Directory of pre-built archives to include in the release. |

Each optional input is only passed to `build.ps1` when set, so only set the ones the repository's
build script accepts. Requires the caller job to grant `contents: read`.

### `detect-changes`

Checks whether the current pull request touched any file matching a pattern, mirroring the
`check-changes` step every generated per-repo `builds.yaml` uses.

| Input | Required | Description |
| --- | --- | --- |
| `pattern` | Yes | Extended regular expression (`grep -iqE`) matched against changed file paths. |
| `pr-number` | Yes | Pull request number to inspect. |
| `repository` | Yes | `owner/repo` to inspect (defaults to `github.repository`). |
| `github-token` | Yes | Token with `pull-requests: read`. |

Output: `relevant` (`'true'`/`'false'`).

Requires the caller job to grant `pull-requests: read`.

### `notify`

Runs a checked-out repository's `.build/_init.ps1` then calls `Send-BuildNotification`.

| Input | Required | Description |
| --- | --- | --- |
| `repo-path` | Yes | Path to the checked-out repo root containing `.build/_init.ps1`. |
| `webhook` | Yes | Slack (or compatible) incoming webhook URL. |
| `build-name` | Yes | Name of the build/job to report. |
| `build-status` | Yes | Status of the build/job to report. |
| `repo-branch` | Yes | Branch the build ran on. |

No extra caller permissions required.

## Reusable workflows

All secrets are declared explicitly under `workflow_call.secrets` and must be mapped explicitly by
the caller; this repository never uses `secrets: inherit`.

### `brownserve-pr-build.yaml`

Runs the change-detection gate and build matrix used by every generated `builds.yaml`.

Inputs: `repo-name`, `change-pattern`, `build-task` (default `BuildTestAndCheck`), `os-matrix`
(JSON array, default `["ubuntu-latest"]`), `rust`, `node`, `mono` (booleans).

Secrets: none.

Caller permissions: `pull-requests: read`, `contents: read`.

### `brownserve-stage-release.yaml`

Inputs: `repo-name`, `release-type`, `rust` (boolean, installs Rust for `UpdateCargoVersion`).

Secrets: `app-id`, `app-private-key` (GitHub App used to generate a short-lived token for the
staging commit and pull request).

Caller permissions: none beyond what the called workflow's own jobs declare (it uses the App
token, not the caller's `GITHUB_TOKEN`).

### `brownserve-release.yaml`

Inputs: `repo-name`, `publish-to`, `package-matrix` (optional JSON array of package job includes,
each with an `os` and a `target`), `package-build-task` (default `Package`), `mono` (boolean).

Secrets: `app-id`, `app-private-key`, `slack-webhook` (required); `nuget-api-key`,
`psgallery-api-key`, `dockerhub-username`, `dockerhub-token` (only needed for the matching
`publish-to` targets). The GHCR push uses the job's own `GITHUB_TOKEN`, passed only when
`publish-to` includes `GHCR`.

Caller permissions: `contents: read` and `packages: write`. The release job always requests
`packages: write` because job permissions can't depend on inputs, and a called workflow fails to
start if it requests more than the caller grants.

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
    uses: Brownserve-UK/actions/.github/workflows/brownserve-pr-build.yaml@v0.1.0
    with:
      repo-name: my-repo
      change-pattern: '^(Cargo\.toml$|Cargo\.lock$|.*\.rs$|\.build/|\.config/|nuget\.config$)'
```

## Releases

This repository uses the standard Brownserve `StageRelease`/`Release` flow:

1. Run the `stage-release` workflow (`workflow_dispatch`), which bumps the version, updates
   `CHANGELOG.md` from merged PR labels, rewrites every internal
   `Brownserve-UK/actions/<path>@vX.Y.Z` reference to the new version, and opens a `release/vX.Y.Z`
   pull request via the GitHub API.
2. Review and merge that pull request.
3. Run the `release` workflow (`workflow_dispatch`), which tags the release and publishes a GitHub
   release (no assets).

The first release from this flow is expected to be `v0.1.0`.
