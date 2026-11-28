# Contributing

Routed from [AGENTS.md](../AGENTS.md#where-to-look). Its security rules and verification loop apply to every change.

## Setup

The git hooks apply only once enabled in the clone. Before the first commit, check that `git config core.hooksPath` returns `.githooks`, and otherwise enable them:

```powershell
git config core.hooksPath .githooks
```

Some checks need tools that don't ship with Windows. Install them once, at the versions CI uses:

```powershell
python -m pip install -r harness/requirements.txt                       # zizmor, audit of the workflows
Install-Module Pester -RequiredVersion 6.1.0 -Force -SkipPublisherCheck  # Pester 6, unit tests
Install-PSResource PSScriptAnalyzer -Version 1.25.0 -Scope CurrentUser -TrustRepository  # static analysis
```

`-SkipPublisherCheck` is needed because Windows ships an old Pester 3 signed by another publisher. Any Pester 6.x and any PSScriptAnalyzer version work locally (`Update-Module Pester` keeps Pester current); CI pins both versions in the [CI workflow](../.github/workflows/validate.yml), updated by hand since Dependabot doesn't follow PowerShell Gallery modules.

## PowerShell code

`Test-Lint.ps1` runs PSScriptAnalyzer on every PowerShell file, and every error or warning fails it. A rule that doesn't fit the whole repository is excluded in [`PSScriptAnalyzerSettings.psd1`](../PSScriptAnalyzerSettings.psd1), with the reason in a comment. A single finding that is wrong where it occurs is suppressed there, with a `[Diagnostics.CodeAnalysis.SuppressMessageAttribute()]` and its `Justification`. Never exclude or suppress a finding only to make the check pass.

A missing tool makes its check exit 2 ("could not run"): the pre-commit hook lets the commit through with a warning, but CI installs every tool and stays strict.

## Commits

- Commit messages are in English, 50 words at most. Start with one of these prefixes: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `build`, `revert`. The subject has no final period.
- No AI attribution in commits or pull request descriptions: no `Co-Authored-By`, no "Generated with".
- The author email for this repository is the GitHub no-reply address, set in the local git config.

The [commit-msg hook](../.githooks/commit-msg) checks all of this except the language and the email. CI checks the same rules on the commits of each pull request and on the commits pushed to `main`, merges and Dependabot's commits excepted. To check a branch before pushing it:

```powershell
.\harness\Invoke-Harness.ps1 -CommitRange origin/develop..HEAD
```

## Pull requests

- Two branches are protected, and neither accepts a direct push. `develop` is the default branch and the integration branch: every working pull request targets it, Dependabot's and urgent fixes included. `main` is the publication branch: it only moves through the **publication pull request** from `develop` to `main`, merged with a merge commit when a version is released (see [Release steps](#release-steps)); `develop` is kept.
- The `validate` check is required on both branches, and the `source` check also on `main`, which thus refuses a pull request from any branch other than `develop` of this repository. A pull request to `develop` is merged on a branch up to date with `develop`: a branch behind it is updated first (*Update branch* on the pull request), which runs CI again on the result. `main` doesn't require this: its merge commit never goes back to `develop`, so requiring it would block the next publication pull request.
- Dependabot's pull requests are merged with a merge commit, like the others: its commits keep their own messages and release notes, which the commit checks skip.
- The description follows the [pull request template](../.github/pull_request_template.md): every section is kept, and a box is ticked only when its point was actually verified. Issues are opened through the forms of [`.github/ISSUE_TEMPLATE/`](../.github/ISSUE_TEMPLATE/config.yml), whose warning about secrets matches the [security rules](../AGENTS.md#security-rules--non-negotiable).

No hook checks a pull request description, and a squash message written on GitHub is only checked by CI on the next publication pull request: apply the commit rules by hand.

## GitHub Actions

Actions are pinned to a commit SHA, with the version in a comment (`uses: owner/action@<sha>  # vX.Y.Z`): a tag can be moved to other code. The repository's Actions settings enforce it (*Require actions to be pinned to a full-length commit SHA*). [Dependabot](../.github/dependabot.yml) updates the SHA and the comment together.

The protection of `develop` and `main` requires the `validate` job of the [CI workflow](../.github/workflows/validate.yml). Every check of the code runs in that job, through `Invoke-Harness.ps1`, so a new check is required as soon as it is added to the harness. The protection of `main` also requires the `source` job, which runs on a pull request to `main` only and checks that it comes from `develop` of this repository. Don't rename either job. Any other separate job is not required by the protection: add one only behind an aggregating job named `validate`, which `needs` it and fails unless every job it needs succeeded.

CI runs on every pull request, on every push to `main` and on demand. A push to `develop` doesn't run it: a pull request to `develop` is up to date before its merge, and its run already checked the merged code.

A value from the event (branch name, title, SHA) reaches a `run:` script through `env:`, never as `${{ }}` inside the script: expanded there, it would be code.

`Test-Workflows.ps1` audits the workflows with [zizmor](https://docs.zizmor.sh/), and every finding fails it. A finding accepted on purpose is ignored on its line with `# zizmor: ignore[<audit>]`, followed by the reason. The version of zizmor is pinned in [`harness/requirements.txt`](../harness/requirements.txt), which Dependabot updates like the actions.

## Documentation

Documentation is in English. It describes the result, not the process.

The README is the user's documentation; [AGENTS.md](../AGENTS.md) and this folder hold the instructions for agents and contributors. When to update them is part of the [verification loop](../AGENTS.md#loop-after-every-edit).

A new file under `docs/` gets a row in [Where to look](../AGENTS.md#where-to-look), phrased by the task it serves ("About to…"), and starts with the line `Routed from [AGENTS.md](../AGENTS.md#where-to-look).`, followed by what it covers.

Some rules are written in several places on purpose, each copy for its own reader. A change to one of them updates all its copies in the same commit:

| Rule | Copies |
|---|---|
| Read AGENTS.md before any action | [AGENTS.md](../AGENTS.md), [CLAUDE.md](../CLAUDE.md), [copilot-instructions.md](../.github/copilot-instructions.md) |
| Enable the git hooks (`git config core.hooksPath .githooks`) | [Setup](#setup), [`pre-commit`](../.githooks/pre-commit), [`commit-msg`](../.githooks/commit-msg) |
| Commit rules: prefixes, 50 words, no final period, no AI attribution | [Commits](#commits), the header of [`Test-CommitMessage.ps1`](../harness/Test-CommitMessage.ps1), [`commit-msg`](../.githooks/commit-msg) |
| Changelog subsections and their order | [Changelog](#changelog), the introduction of [CHANGELOG.md](../CHANGELOG.md), rule 11 of [`Test-Consistency.ps1`](../harness/Test-Consistency.ps1) |
| Read the 💥 Upgrade section before a major version | [README](../README.md#updating), the introduction of [CHANGELOG.md](../CHANGELOG.md) |

## Releases

A release is an annotated git tag on a commit of the publication branch, `main`, published as a GitHub Release whose notes are the version's section of [CHANGELOG.md](../CHANGELOG.md). The tag defines the version: besides it, only the changelog heading written in the release pull request names it.

The tag follows semantic versioning, `MAJOR.MINOR.PATCH`, without a prefix: `1.0.0`, never `v1.0.0`. Choose the number to increment from all the changes since the previous release, as seen by a user who already runs the script:

| Number | Incremented when |
|---|---|
| `MAJOR` | An existing setup needs the user to act: a parameter or setting is removed or renamed, a runtime file moves, or the scheduled task must be registered again. |
| `MINOR` | A parameter, setting or behaviour is added, and an existing setup keeps working unchanged. |
| `PATCH` | Anything else: a fix, documentation, the harness, CI. |

Incrementing a number resets the ones after it: `1.4.2` becomes `1.5.0` or `2.0.0`.

### Changelog

[CHANGELOG.md](../CHANGELOG.md) follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), with an emoji per category so that the content of a release shows at a glance. Every pull request adds its entries under `## [Unreleased]`, except Dependabot's, the release pull request and the publication pull request, in these subsections, each once and in this order:

| Subsection | Content | Usual commit prefix |
|---|---|---|
| `### 💥 Upgrade` | What an existing setup must do, such as registering the scheduled task again. Required in a version raising `MAJOR` | |
| `### 🚀 Added` | A new parameter, setting or behaviour | `feat` |
| `### 🔄 Changed` | An existing behaviour that works differently | `feat`, `fix` |
| `### ⏳ Deprecated` | Something that still works but will be removed | |
| `### 🔥 Removed` | Something that no longer exists | |
| `### 🐛 Fixed` | A bug fix | `fix` |
| `### 🔒 Security` | A fix or hardening of the [security model](../README.md#security) | `fix` |
| `### 📝 Documentation` | The README or the contributor documentation | `docs` |
| `### 🧹 Maintenance` | The harness, CI, tests, dependencies, refactoring | `chore`, `build`, `test`, `refactor` |

An entry describes the result for its reader, in one line, not the commits. `Test-Consistency.ps1` checks the format, the subsections and their order, the order of the versions and their dates, the link references and the `💥 Upgrade` section of a major version. The presence of an entry and its wording are checked by reading.

### Release steps

1. **Release pull request** to `develop`, titled `chore: version <version>`: in `CHANGELOG.md`, rename `## [Unreleased]` to `## [<version>] - <YYYY-MM-DD>`, add an empty `## [Unreleased]` above it, and update the link references at the end of the file (`[Unreleased]` compares `<version>...HEAD`, `[<version>]` compares the previous version with `<version>`).
2. **Merge it.**
3. **Publication pull request** from `develop` to `main`, with the same title and the version's changelog section as description. Merge it with a merge commit, keep `develop`, then check that the latest run of the `CI` workflow on `main` passed, in the Actions tab of the GitHub repository.
4. **Tag on `main`**, never on `develop` or on a working branch: the tag points to the state of `main` that users download.

   ```powershell
   git switch main
   git pull --ff-only
   git tag -a <version> -m "<version>"
   git push origin <version>
   ```

5. **Check the release.** Pushing the tag runs the [Release workflow](../.github/workflows/release.yml). It checks that the tagged commit is on `main` and that CI passed on it, then publishes the GitHub Release with the version's changelog section as notes. Check its run, then the release page.

A tag published without its GitHub Release, or whose run failed, is published again on demand: `gh workflow run release.yml -f tag=<version>`. That run reads `CHANGELOG.md` from `main`, and fails if started from another branch.

- **Annotated tag** (`-a`): it records the author and the release date, which a lightweight tag doesn't.
- **Ask before publishing.** `git push` of the tag, and `gh workflow run release.yml`, make the version public: get the user's approval before running them.
- **Never move or delete a published tag**: a clone that already fetched it would keep the old target. Fix a mistake with a new release. The `Version tags` ruleset of the repository refuses the update or deletion of any tag on GitHub.
