# ceph-backport-doc

## Summary

This repository contains the script `ceph-backport-doc.sh` that can be used to
generate backports for documentation PRs in
the [Ceph repository](https://github.com/ceph/ceph).

A good proportion is copied shamelessly from the official
`ceph-backport.sh` [script](https://github.com/ceph/ceph/blob/main/src/script/ceph-backport.sh).

Differences between this script and the official one:
* **No requirement for the Ceph [bug tracker](https://tracker.ceph.io/)**: Docs
  PRs do not require a tracker issue. A GitHub PR # is used as a
  starting point and no tracker issues are opened or modified.
* **Simplified**: Skips a lot of the rather unnecessary polish like the
  interactive configuration feature, git upstream remote auto-detection
  (hardcoded to `upstream`), etc.
* **PR description**: PR description from the original development branch PR is
  automatically copied in full to the backport PR with a reference to the
  original PR.

## Dependencies

* Git (or Git for Windows, Git Bash will work on Windows)
* jq (or jq Windows build)

## Configuration

Add your [GitHub personal access token](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
either in the environment variable `github_token` or in the
file `$HOME/.github_token`.

```console
export github_token=ghp_XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
```

Currently the script assumes that `origin` is set to your GitHub fork and that
`upstream` is the upstream Ceph repository. This should be configurable in a
future version. To check that your remotes are compatible, run:

```console
git remote -v
```

## Usage

```console
/path/to/ceph-backport-doc.sh [--test] [--message <PR body line>] <stable branch name> <GitHub PR ID>
```

The script needs to be run from inside your `ceph` git repository local copy.

## Example Usage

Create a backport PR to the `tentacle` stable branch from a single PR #1920210:

```console
~/ceph-backport-doc.sh tentacle 1920210
```

## Cherry Pick Conflicts

If cherry pick conflicts, resolve the conflict as usual:
* Edit the conflict file(s), make sure to search/fix/delete all git markup such
  as `>>>>>>` and `<<<<<<`.
* Run `git add <conflict file> ...`.
* Run `git cherry-pick --continue`.

And then re-run the script with the exact same arguments.

The script will check that cherry pick is completed, the backport branch does
not already exist upstream and that the latest commit log message includes the
automatically added cherry picked commit SHA. After the checks succeed, the
backport branch is pushed to origin and a GitHub PR is opened.

## Contact

I am on `#ceph-doc` at the Ceph Slack.

