#!/usr/bin/env bash
# git_pr_publish.sh — Publish a validated NSO spec build to git as a PR.
#
# Three explicit actions keep the human-in-the-loop gates in the agent, not the
# script: `prepare` (branch + allow-listed commit), `push`, and `pr`. The script
# never pushes or opens a PR unless that action is invoked explicitly.
#
# Usage:
#   git_pr_publish.sh prepare --service <name> --package <path> [--package <path> ...]
#                             [--date <yyyymmdd>] [--base <branch>]
#   git_pr_publish.sh push    --branch <branch>
#   git_pr_publish.sh pr      --branch <branch> --title <title>
#                             [--body-file <file>] [--base <branch>]
#
# prepare:
#   - preflight (repo, gh presence/auth are reported, not required here)
#   - create branch feature/<service>-<yyyymmdd> (collision → reuse or -N suffix)
#   - stage ONLY the given --package paths (allow-list; never `git add -A`)
#   - commit; leaves the branch local (no push)
#   - prints:  BRANCH=<name>
#
# push:
#   - git push -u origin <branch>   (run only after human confirmation)
#
# pr:
#   - detect base (origin default, default main) unless --base given
#   - gh pr create --base <base> --head <branch> --title <title> [--body-file <file>]
#   - prints:  PR_URL=<url>   (or compare URL fallback if gh unavailable)
#
# Security: stages only the explicit --package paths; never `git add -A`; never
# echoes or persists secrets. Validates inputs before acting.

set -euo pipefail

# ─── Helpers ─────────────────────────────────────────────────────────────────
die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "» $*" >&2; }

require_repo() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "not inside a git work tree"
}

detect_base() {
  local base
  base="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
          | sed 's#refs/remotes/origin/##')" || true
  [[ -n "$base" ]] && printf '%s' "$base" || printf 'main'
}

# validate a branch component: letters, digits, dot, underscore, hyphen only
sanitize_component() {
  local v="$1"
  [[ "$v" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid name component: '$v'"
  printf '%s' "$v"
}

branch_exists() {
  local b="$1"
  git show-ref --verify --quiet "refs/heads/$b" && return 0
  git show-ref --verify --quiet "refs/remotes/origin/$b" && return 0
  return 1
}

# pick a non-colliding branch name based on feature/<service>-<date>
pick_branch() {
  local base_name="$1" candidate="$1" n=2
  if ! branch_exists "$candidate"; then
    printf '%s' "$candidate"; return
  fi
  # reuse a local branch of the exact name if it has no remote-tracking ref yet
  if git show-ref --verify --quiet "refs/heads/$base_name" \
     && ! git show-ref --verify --quiet "refs/remotes/origin/$base_name"; then
    printf '%s' "$base_name"; return
  fi
  while branch_exists "${base_name}-${n}"; do n=$((n + 1)); done
  printf '%s-%s' "$base_name" "$n"
}

# ─── Action: prepare ─────────────────────────────────────────────────────────
action_prepare() {
  local service="" date_str="" base="" ; local -a packages=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --service) service="$2"; shift 2 ;;
      --package) packages+=("$2"); shift 2 ;;
      --date)    date_str="$2"; shift 2 ;;
      --base)    base="$2"; shift 2 ;;
      *) die "prepare: unknown arg '$1'" ;;
    esac
  done

  [[ -n "$service" ]] || die "prepare: --service is required"
  [[ ${#packages[@]} -gt 0 ]] || die "prepare: at least one --package is required"
  service="$(sanitize_component "$service")"
  [[ -z "$date_str" ]] && date_str="$(date +%Y%m%d)"
  date_str="$(sanitize_component "$date_str")"

  require_repo

  # validate every package path exists and is under packages/
  local p
  for p in "${packages[@]}"; do
    [[ "$p" == packages/* ]] || die "package path must be under packages/: '$p'"
    [[ -e "$p" ]] || die "package path does not exist: '$p'"
  done

  # gh status is informational at prepare time
  if command -v gh >/dev/null 2>&1; then
    gh auth status >/dev/null 2>&1 && info "gh: authenticated" \
      || info "gh: present but not authenticated (PR step will fall back to manual)"
  else
    info "gh: not installed (PR step will fall back to manual)"
  fi

  local wanted="feature/${service}-${date_str}"
  local branch; branch="$(pick_branch "$wanted")"

  if git show-ref --verify --quiet "refs/heads/$branch"; then
    info "reusing existing local branch $branch"
    git switch "$branch"
  else
    info "creating branch $branch"
    git switch -c "$branch"
  fi

  info "staging allow-listed package paths only"
  git add -- "${packages[@]}"

  if git diff --cached --quiet; then
    info "nothing staged (packages already committed?) — no commit created"
  else
    local subject="Add NSO service package(s): ${packages[*]#packages/}"
    git commit -m "$subject" >/dev/null
    info "committed: $subject"
  fi

  printf 'BRANCH=%s\n' "$branch"
}

# ─── Action: push ────────────────────────────────────────────────────────────
action_push() {
  local branch=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch) branch="$2"; shift 2 ;;
      *) die "push: unknown arg '$1'" ;;
    esac
  done
  [[ -n "$branch" ]] || die "push: --branch is required"
  require_repo
  info "pushing $branch to origin"
  git push -u origin "$branch"
  printf 'PUSHED=%s\n' "$branch"
}

# ─── Action: pr ──────────────────────────────────────────────────────────────
action_pr() {
  local branch="" title="" body_file="" base=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch)    branch="$2"; shift 2 ;;
      --title)     title="$2"; shift 2 ;;
      --body-file) body_file="$2"; shift 2 ;;
      --base)      base="$2"; shift 2 ;;
      *) die "pr: unknown arg '$1'" ;;
    esac
  done
  [[ -n "$branch" ]] || die "pr: --branch is required"
  [[ -n "$title" ]] || die "pr: --title is required"
  require_repo
  [[ -z "$base" ]] && base="$(detect_base)"

  if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
    # Manual fallback: emit a compare URL from the origin remote.
    local url
    url="$(git remote get-url origin 2>/dev/null \
           | sed -E 's#^git@github.com:#https://github.com/#; s#\.git$##')"
    [[ -n "$url" ]] || die "pr: gh unavailable and origin URL not resolvable"
    printf 'COMPARE_URL=%s/compare/%s...%s\n' "$url" "$base" "$branch"
    info "gh unavailable/unauthenticated — open the PR manually via COMPARE_URL"
    exit 0
  fi

  local -a args=(pr create --base "$base" --head "$branch" --title "$title")
  [[ -n "$body_file" ]] && args+=(--body-file "$body_file")
  local pr_url
  pr_url="$(gh "${args[@]}")"
  printf 'PR_URL=%s\n' "$pr_url"
}

# ─── Dispatch ────────────────────────────────────────────────────────────────
[[ $# -ge 1 ]] || die "usage: $0 <prepare|push|pr> [options]"
action="$1"; shift
case "$action" in
  prepare) action_prepare "$@" ;;
  push)    action_push "$@" ;;
  pr)      action_pr "$@" ;;
  -h|--help)
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *) die "unknown action '$action' (expected prepare|push|pr)" ;;
esac
