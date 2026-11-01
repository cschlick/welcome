#!/usr/bin/env bash
# Check out (or fast-forward) a config repository into DIR (e.g. ~/.claude).
# Runs as the owning account. Usage: config-repo-sync.sh DIR REPO BRANCH KEY
#
# The last line of output is STATUS=<word>, which the role reads:
#   cloned     DIR did not exist or was empty; fresh checkout
#   adopted    DIR already held files (the tool had already run); checked out in place
#   updated    fast-forwarded to the remote branch
#   unchanged  already current
#   dirty      tracked files have local edits; left alone
#   diverged   local commits the remote lacks; left alone
set -euo pipefail

dir=$1 repo=$2 branch=$3 key=$4

# Repo-local, so a later manual `git pull` in DIR uses the same key.
ssh_command="ssh -i $key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

# No commit yet covers both a fresh directory and a first run that died after
# `git init` (e.g. the fetch failed); either way, (re)do the initial checkout.
if ! git -C "$dir" rev-parse -q --verify HEAD >/dev/null 2>&1; then
  mkdir -p "$dir"
  # The tool keeps runtime state (history, sessions, credentials) in DIR too.
  # Initialise around it rather than cloning into it, which git refuses.
  if [ -z "$(ls -A "$dir")" ] || [ "$(ls -A "$dir")" = .git ]; then
    status=cloned
  else
    status=adopted
  fi
  cd "$dir"
  git init -q -b "$branch"
  git config core.sshCommand "$ssh_command"
  git remote add origin "$repo" 2>/dev/null || git remote set-url origin "$repo"
  git fetch -q origin "$branch"
  # Pre-existing files the checkout would overwrite are moved aside, not lost.
  backup="$dir.pre-welcome-$(date +%Y%m%d-%H%M%S)"
  while IFS= read -r -d '' path; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      mkdir -p "$backup/$(dirname "$path")"
      mv "$path" "$backup/$path"
      echo "moved aside: $path"
    fi
  done < <(git ls-tree -r -z --name-only "origin/$branch")
  [ ! -d "$backup" ] || echo "pre-existing files kept in $backup"
  git checkout -q -B "$branch" --track "origin/$branch"
  echo "STATUS=$status"
  exit 0
fi

cd "$dir"
git config core.sshCommand "$ssh_command"
# A checkout initialised by hand may have no origin yet.
git remote add origin "$repo" 2>/dev/null || git remote set-url origin "$repo"
git fetch -q origin "$branch"
# ...and so no upstream, which a manual `git pull` there needs.
git branch -q --set-upstream-to="origin/$branch" "$branch" 2>/dev/null || true

# Untracked files are the tool's own runtime state and never block an update.
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  git status --short --untracked-files=no
  echo "STATUS=dirty"
  exit 0
fi

before=$(git rev-parse HEAD)
if ! git merge -q --ff-only "origin/$branch" 2>/dev/null; then
  echo "STATUS=diverged"
  exit 0
fi
if [ "$(git rev-parse HEAD)" = "$before" ]; then
  echo "STATUS=unchanged"
else
  echo "STATUS=updated"
fi
