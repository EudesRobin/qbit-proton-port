# Contributing

Routed from [AGENTS.md](../AGENTS.md#where-to-look). Its security rules and verification loop apply to every change.

## Setup

The git hooks apply only once enabled in the clone. Before the first commit, check that `git config core.hooksPath` returns `.githooks`, and otherwise enable them:

```powershell
git config core.hooksPath .githooks
```

## Commits

- Commit messages are in French, 50 words at most. Start with one of these prefixes: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `build`, `revert`. The subject has no final period.
- No AI attribution in commits or pull request descriptions: no `Co-Authored-By`, no "Generated with".
- The author email for this repository is the GitHub no-reply address, set in the local git config.

The [commit-msg hook](../.githooks/commit-msg) checks all of this except the language and the email. CI checks the same rules on the commits of each pull request, merges and Dependabot's pull requests excepted, and on the commits pushed to `main`. To check a branch before pushing it:

```powershell
.\harness\Invoke-Harness.ps1 -CommitRange origin/main..HEAD
```

## Pull requests

- `main` is protected: every change goes through a branch and a pull request, merged once the `validate` check is green on a branch up to date with `main`. A branch behind `main` is updated first (*Update branch* on the pull request), which runs CI again on the result.
- Dependabot's commit messages are in English and carry the release notes: squash-merge its pull requests, with a message that follows the [commit rules](#commits).

No hook checks a pull request description, and a squash message written on GitHub is only checked once on `main`, by CI: apply the commit rules by hand.

## GitHub Actions

Actions are pinned to a commit SHA, with the version in a comment (`uses: owner/action@<sha>  # vX.Y.Z`): a tag can be moved to other code. [Dependabot](../.github/dependabot.yml) updates the SHA and the comment together.

The protection of `main` requires one check, the `validate` job of the [CI workflow](../.github/workflows/validate.yml). Every check runs in that job, through `Invoke-Harness.ps1`, so a new check is required as soon as it is added to the harness. Don't rename the job. A separate job is not required by the protection: add one only behind an aggregating job named `validate`, which `needs` it and fails unless every job it needs succeeded.

A value from the event (branch name, title, SHA) reaches a `run:` script through `env:`, never as `${{ }}` inside the script: expanded there, it would be code.

## Documentation

Documentation is in English. It describes the result, not the process.

The README is the user's documentation; [AGENTS.md](../AGENTS.md) and this folder hold the instructions for agents and contributors. When to update them is part of the [verification loop](../AGENTS.md#loop-after-every-edit).

## Releases

A release is an annotated git tag on a commit of `main`, published as a GitHub Release whose notes are the version's section of [CHANGELOG.md](../CHANGELOG.md). The tag defines the version: besides it, only the changelog heading written in the release pull request names it.

The tag follows semantic versioning, `MAJOR.MINOR.PATCH`, without a prefix: `1.0.0`, never `v1.0.0`. Choose the number to increment from all the changes since the previous release, as seen by a user who already runs the script:

| Number | Incremented when |
|---|---|
| `MAJOR` | An existing setup needs the user to act: a parameter or setting is removed or renamed, a runtime file moves, or the scheduled task must be registered again. |
| `MINOR` | A parameter, setting or behaviour is added, and an existing setup keeps working unchanged. |
| `PATCH` | Anything else: a fix, documentation, the harness, CI. |

Incrementing a number resets the ones after it: `1.4.2` becomes `1.5.0` or `2.0.0`.

### Changelog

[CHANGELOG.md](../CHANGELOG.md) follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), with an emoji per category so that the content of a release shows at a glance. Every pull request adds its entries under `## [Unreleased]`, in these subsections, each once and in this order:

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

An entry describes the result for its reader, in one line, not the commits. `Test-Consistency.ps1` checks the format, the subsections and their order, the order of the versions and their dates, the link references and the `💥 Upgrade` section of a major version; the wording of the entries is checked by reading.

### Release steps

1. **Release pull request**, titled `chore: version <version>`: in `CHANGELOG.md`, rename `## [Unreleased]` to `## [<version>] - <YYYY-MM-DD>`, add an empty `## [Unreleased]` above it, and update the link references at the end of the file (`[Unreleased]` compares `<version>...HEAD`, `[<version>]` compares the previous version with `<version>`).
2. **Merge it**, then check that the latest run of the `CI` workflow on `main` is green, in the Actions tab of the GitHub repository.
3. **Tag**, never on a working branch: the tag points to the state of `main` that users download.

   ```powershell
   git switch main
   git pull --ff-only
   git tag -a <version> -m "<version>"
   git push origin <version>
   ```

4. **Check the release.** Pushing the tag runs the [Release workflow](../.github/workflows/release.yml), which publishes the GitHub Release with the version's changelog section as notes. Check its run, then the release page.

A tag published without its GitHub Release, or whose run failed, is published again on demand: `gh workflow run release.yml -f tag=<version>`. That run reads `CHANGELOG.md` from `main`.

- **Annotated tag** (`-a`): it records the author and the release date, which a lightweight tag doesn't.
- **Ask before publishing.** `git push` of the tag, and `gh workflow run release.yml`, make the version public: get the user's approval before running them.
- **Never move or delete a published tag**: a clone that already fetched it would keep the old target. Fix a mistake with a new release.
