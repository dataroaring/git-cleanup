# git-cleanup

Clean up old local git branches and worktrees.

Deletes local branches that are either (a) already merged into the main
branch, or (b) stale — no commits for more than N days. Also prunes
worktrees whose working directory is gone.

**Safe by default:** runs as a dry-run and only prints what it *would* do.
Pass `--apply` to actually delete anything.

## Usage

```
./git-cleanup.sh [options]
```

## Options

| Option | Description |
| --- | --- |
| `--apply` | Actually delete (default is dry-run). |
| `--days N` | Stale threshold in days (default: 30). |
| `--main BRANCH` | Main branch to compare against (default: auto-detect master/main). |
| `--no-merged` | Skip the "merged into main" cleanup. |
| `--no-stale` | Skip the "stale by age" cleanup. |
| `--no-worktrees` | Skip worktree pruning. |
| `-h`, `--help` | Show this help. |

## Branches that are never touched

- the main branch, the currently checked-out branch
- any branch checked out in a worktree
- protected branches: `master`, `main`, `develop`, `dev`, `release`
