#!/usr/bin/env bash
#
# git-cleanup.sh — clean up old git branches and worktrees.
#
# Deletes local branches that are either (a) already merged into the main
# branch, or (b) stale — no commits for more than N days. Also prunes
# worktrees whose working directory is gone.
#
# SAFE BY DEFAULT: runs as a dry-run and only prints what it *would* do.
# Pass --apply to actually delete anything.
#
# Usage:
#   ./git-cleanup.sh [options]
#
# Options:
#   --apply            Actually delete (default is dry-run).
#   --days N           Stale threshold in days (default: 30).
#   --main BRANCH      Main branch to compare against (default: auto-detect
#                      master/main).
#   --no-merged        Skip the "merged into main" cleanup.
#   --no-stale         Skip the "stale by age" cleanup.
#   --no-worktrees     Skip worktree pruning.
#   -h, --help         Show this help.
#
# Branches that are NEVER touched:
#   - the main branch, the currently checked-out branch
#   - any branch checked out in a worktree
#   - branches matching the protected list (see PROTECTED below)

set -euo pipefail

# --- defaults ---------------------------------------------------------------
APPLY=0
DAYS=30
MAIN_BRANCH=""
DO_MERGED=1
DO_STALE=1
DO_WORKTREES=1
PROTECTED=("master" "main" "develop" "dev" "release")

# --- colors (only when stdout is a tty) ------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BOLD=""
fi

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# --- parse args -------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)        APPLY=1; shift ;;
    --days)         DAYS="${2:?--days needs a value}"; shift 2 ;;
    --main)         MAIN_BRANCH="${2:?--main needs a value}"; shift 2 ;;
    --no-merged)    DO_MERGED=0; shift ;;
    --no-stale)     DO_STALE=0; shift ;;
    --no-worktrees) DO_WORKTREES=0; shift ;;
    -h|--help)      usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

# --- sanity checks ----------------------------------------------------------
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "${C_RED}Not inside a git repository.${C_RESET}" >&2
  exit 1
fi

# Auto-detect the main branch if not given.
if [[ -z "$MAIN_BRANCH" ]]; then
  for b in main master; do
    if git show-ref --verify --quiet "refs/heads/$b"; then MAIN_BRANCH="$b"; break; fi
  done
fi
if [[ -z "$MAIN_BRANCH" ]] || ! git show-ref --verify --quiet "refs/heads/$MAIN_BRANCH"; then
  echo "${C_RED}Could not determine main branch (looked for main/master). Use --main.${C_RESET}" >&2
  exit 1
fi

CURRENT_BRANCH="$(git symbolic-ref --quiet --short HEAD || echo "")"

# Track branches already handled so a branch that is both merged and stale
# isn't deleted (or reported) twice.
declare -A SEEN=()

# Branches checked out in any worktree (these can't be deleted).
mapfile -t WORKTREE_BRANCHES < <(
  git worktree list --porcelain | awk '/^branch /{sub("refs/heads/","",$2); print $2}'
)

is_protected() {
  local br="$1"
  [[ "$br" == "$MAIN_BRANCH" ]] && return 0
  [[ "$br" == "$CURRENT_BRANCH" ]] && return 0
  local p; for p in "${PROTECTED[@]}"; do [[ "$br" == "$p" ]] && return 0; done
  local w; for w in "${WORKTREE_BRANCHES[@]}"; do [[ "$br" == "$w" ]] && return 0; done
  return 1
}

# Returns 0 if it handled the branch (printed a line), 1 if skipped as a dup.
delete_branch() {
  local br="$1" reason="$2"
  [[ -n "${SEEN[$br]:-}" ]] && return 1   # already handled
  SEEN[$br]=1
  count=$((count+1))
  if [[ "$APPLY" -eq 1 ]]; then
    if git branch -D "$br" >/dev/null 2>&1; then
      echo "  ${C_RED}deleted${C_RESET} $br ${C_DIM}($reason)${C_RESET}"
    else
      echo "  ${C_YELLOW}failed to delete${C_RESET} $br ${C_DIM}($reason)${C_RESET}"
    fi
  else
    echo "  ${C_YELLOW}would delete${C_RESET} $br ${C_DIM}($reason)${C_RESET}"
  fi
}

# --- header -----------------------------------------------------------------
mode="${C_YELLOW}DRY-RUN${C_RESET} ${C_DIM}(pass --apply to delete)${C_RESET}"
[[ "$APPLY" -eq 1 ]] && mode="${C_RED}APPLY${C_RESET}"
echo "${C_BOLD}git-cleanup${C_RESET}  main=${C_GREEN}$MAIN_BRANCH${C_RESET}  stale>${DAYS}d  mode=$mode"
echo

count=0

# --- 1. branches merged into main ------------------------------------------
if [[ "$DO_MERGED" -eq 1 ]]; then
  echo "${C_BOLD}Merged into $MAIN_BRANCH:${C_RESET}"
  found=0
  while IFS= read -r br; do
    br="${br#"${br%%[![:space:]]*}"}"   # ltrim
    [[ -z "$br" ]] && continue
    is_protected "$br" && continue
    delete_branch "$br" "merged" && found=1
  done < <(git branch --merged "$MAIN_BRANCH" --format='%(refname:short)')
  [[ "$found" -eq 0 ]] && echo "  ${C_DIM}none${C_RESET}"
  echo
fi

# --- 2. stale branches by age ----------------------------------------------
if [[ "$DO_STALE" -eq 1 ]]; then
  echo "${C_BOLD}Stale (no commits in >${DAYS} days):${C_RESET}"
  cutoff=$(( $(date +%s) - DAYS*86400 ))
  found=0
  while IFS=$'\t' read -r ts br; do
    [[ -z "$br" ]] && continue
    is_protected "$br" && continue
    (( ts >= cutoff )) && continue
    age_days=$(( ( $(date +%s) - ts ) / 86400 ))
    delete_branch "$br" "${age_days}d old" && found=1
  done < <(git for-each-ref --sort=committerdate \
              --format='%(committerdate:unix)%09%(refname:short)' refs/heads/)
  [[ "$found" -eq 0 ]] && echo "  ${C_DIM}none${C_RESET}"
  echo
fi

# --- 3. worktrees -----------------------------------------------------------
if [[ "$DO_WORKTREES" -eq 1 ]]; then
  echo "${C_BOLD}Worktrees with missing directories:${C_RESET}"
  if [[ "$APPLY" -eq 1 ]]; then
    out="$(git worktree prune -v 2>&1 || true)"
    if [[ -n "$out" ]]; then echo "$out" | sed 's/^/  /'; else echo "  ${C_DIM}none${C_RESET}"; fi
  else
    out="$(git worktree prune -n -v 2>&1 || true)"
    if [[ -n "$out" ]]; then echo "$out" | sed "s/^/  ${C_YELLOW}would: ${C_RESET}/"; else echo "  ${C_DIM}none${C_RESET}"; fi
  fi
  echo
fi

# --- summary ----------------------------------------------------------------
if [[ "$APPLY" -eq 1 ]]; then
  echo "${C_GREEN}Done.${C_RESET} Processed $count branch(es)."
else
  echo "${C_DIM}Dry-run complete — $count branch(es) would be deleted. Re-run with --apply.${C_RESET}"
fi
