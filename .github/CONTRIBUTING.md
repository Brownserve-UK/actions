# Contributing

Pull requests are welcome. Please read this guide before submitting.

## Repository conventions

- Composite actions live in their own top-level directory, named after the action, with an `action.yml`.
- Reusable workflows live in `.github/workflows/`, named `brownserve-<name>.yaml`, and declare their inputs, secrets
  and outputs explicitly.
- Internal references to this repository's own actions/workflows use the full
  `Brownserve-UK/actions/<path>@vX.Y.Z` form so that consumers always pin an exact release.

## Running the checks locally

```sh
pwsh ./.build/build.ps1 -Build BuildTestAndCheck
```

This runs the Pester tests under `.build/tests/`, plus `actionlint` and `zizmor` against every action and
workflow in the repository.

## Commit and PR requirements

> **Please Note:**
> Our branch protection rules **require** all commits to be [signed](https://docs.github.com/en/github/authenticating-to-github/managing-commit-signature-verification/signing-commits).
> While we can rebase and sign commits for you it's much more likely that your PR will be merged promptly if you ensure your commits are signed before submitting the PR.

We use the [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) standard for PR titles and **this is a hard requirement.** Your PR title must begin with a recognised prefix so that an automated workflow can classify the change for the changelog.

Supported prefixes (brackets are optional):

| Prefix examples | Type |
| --- | --- |
| `[feat]:` `feat:` `[feature]:` `feature:` | New feature or enhancement |
| `[fix]:` `fix:` `[bug]:` `bug:` | Bug fix |
| `[docs]:` `docs:` `[doc]:` `doc:` | Documentation update |
| `[ci]:` `ci:` `[cicd]:` `cicd:` | CI/CD changes |
| `[chore]:` `[refactor]:` `[ops]:` `[test]:` `[style]:` (and without brackets) | Maintenance |

Add `!` before the colon to flag a breaking change, e.g. `feat!: rename an action input`.

> **Please Note:**
> If your PR title does not match a recognised prefix the check will fail and a comment will be posted on the PR explaining what to fix. Simply update the title and the checks will re-run automatically.
