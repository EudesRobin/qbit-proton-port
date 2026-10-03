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

The [commit-msg hook](../.githooks/commit-msg) checks all of this except the language and the email. CI doesn't check commit messages.

## Pull requests

- `main` is protected: every change goes through a branch and a pull request, merged once the `validate` check is green.
- Dependabot's commit messages are in English and carry the release notes: squash-merge its pull requests, with a message that follows the [commit rules](#commits).

No hook checks a pull request description or a squash message written on GitHub: apply the commit rules by hand.

## GitHub Actions

Actions are pinned to a commit SHA, with the version in a comment (`uses: owner/action@<sha>  # vX.Y.Z`): a tag can be moved to other code. [Dependabot](../.github/dependabot.yml) updates the SHA and the comment together.

## Documentation

Documentation is in English. It describes the result, not the process.

The README is the user's documentation; [AGENTS.md](../AGENTS.md) and this folder hold the instructions for agents and contributors. When to update them is part of the [verification loop](../AGENTS.md#loop-after-every-edit).

## Releases

A release is an annotated git tag on a commit of `main`. The version number lives in the tag only, in no file.

The tag follows semantic versioning, `MAJOR.MINOR.PATCH`, without a prefix: `1.0.0`, never `v1.0.0`. Choose the number to increment from all the changes since the previous release, as seen by a user who already runs the script:

| Number | Incremented when |
|---|---|
| `MAJOR` | An existing setup needs the user to act: a parameter or setting is removed or renamed, a runtime file moves, or the scheduled task must be registered again. |
| `MINOR` | A parameter, setting or behaviour is added, and an existing setup keeps working unchanged. |
| `PATCH` | Anything else: a fix, documentation, the harness, CI. |

Incrementing a number resets the ones after it: `1.4.2` becomes `1.5.0` or `2.0.0`.

Tag only **after the pull request that closes the release is merged**, never on a working branch: the tag points to the state of `main` that users download. First check that the latest `validate` run on `main` is green, in the Actions tab of the GitHub repository.

```powershell
git switch main
git pull --ff-only
git tag -a <version> -m "<version>"
git push origin <version>
```

- **Annotated tag** (`-a`): it records the author and the release date, which a lightweight tag doesn't.
- **Ask before publishing.** `git push` makes the tag public: get the user's approval before running it.
- **Never move or delete a published tag**: a clone that already fetched it would keep the old target. Fix a mistake with a new release.
