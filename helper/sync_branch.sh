#!/bin/sh
# sync_branch.sh - Sync this fork with the upstream zsh repo it was forked
# from, then rebase our work on top of it.
#
# Usage (from Git Bash or any POSIX shell):
#   sh helper/sync_branch.sh [--push-develop]
#
# Remote layout this assumes (see "Remotes" in helper/README-win.md):
#   origin  -> the repo we forked FROM (zsh-users/zsh), fetch-only for us
#   ralic   -> OUR fork (raliclo/zsh), where everything gets pushed
#
# What it does:
#   1. Fetches upstream master from 'origin'.
#   2. Fast-forwards local master to it (ff-only: master is a pure mirror of
#      upstream and must never carry local commits -- if it somehow does,
#      this fails loudly instead of rewriting them).
#   3. Pushes the updated master to 'ralic', so our fork's master matches
#      upstream on GitHub too.
#   4. Rebases local develop onto the refreshed master, so our Windows work
#      sits on top of current upstream.
#
# The develop rebase REWRITES published history, so pushing it needs
# --force-with-lease. That is not done unless you pass --push-develop,
# because a force-push to develop also desyncs the scoop bucket clone at
# ~/scoop/buckets/zsh (it has to be reset to match afterwards).

set -e

PUSH_DEVELOP=
if [ "$1" = "--push-develop" ]; then
    PUSH_DEVELOP=1
    shift
fi

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO"

UPSTREAM_REMOTE=origin   # the repo we forked from
FORK_REMOTE=ralic        # our own fork
MASTER=master
DEVELOP=develop

# --- 0. Preconditions --------------------------------------------------------
for r in "$UPSTREAM_REMOTE" "$FORK_REMOTE"; do
    git remote get-url "$r" >/dev/null 2>&1 || {
        echo "error: no git remote named '$r'." >&2
        echo "       expected '$UPSTREAM_REMOTE' = the repo we forked from," >&2
        echo "       and '$FORK_REMOTE' = our own fork. Current remotes:" >&2
        git remote -v >&2
        exit 1
    }
done

# A rebase rewrites tracked files across a branch switch; refuse to start on
# top of uncommitted work rather than leaving it half-applied. Untracked
# files are deliberately ignored -- a rebase never touches them, and this
# repo normally has untracked helper/build leftovers lying around.
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "error: tracked files have uncommitted changes; commit or stash first." >&2
    git status --short --untracked-files=no >&2
    exit 1
fi

START_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# --- 1. Fetch upstream -------------------------------------------------------
echo "==> Fetching $MASTER from $UPSTREAM_REMOTE ($(git remote get-url "$UPSTREAM_REMOTE"))"
git fetch "$UPSTREAM_REMOTE" "$MASTER"

BEHIND=$(git rev-list --count "$MASTER..FETCH_HEAD")
echo "==> $MASTER is $BEHIND commit(s) behind upstream"

# --- 2. Fast-forward local master -------------------------------------------
if [ "$BEHIND" -gt 0 ]; then
    # refspec form updates master without checking it out; it is ff-only, so
    # it fails rather than discarding anything if master ever diverges.
    echo "==> Fast-forwarding local $MASTER"
    git fetch "$UPSTREAM_REMOTE" "$MASTER:$MASTER"
else
    echo "==> Local $MASTER already current"
fi

# --- 3. Push master to our fork ---------------------------------------------
if [ -n "$(git rev-list "$FORK_REMOTE/$MASTER..$MASTER" 2>/dev/null)" ]; then
    echo "==> Pushing $MASTER to $FORK_REMOTE"
    git push "$FORK_REMOTE" "$MASTER"
else
    echo "==> $FORK_REMOTE/$MASTER already current"
fi

# --- 4. Rebase develop onto master ------------------------------------------
echo "==> Rebasing $DEVELOP onto $MASTER"
git checkout "$DEVELOP"

# Pick up anything pushed to our fork's develop from elsewhere first, so the
# rebase below replays a develop that is already current.
git pull --rebase "$FORK_REMOTE" "$DEVELOP"

if ! git rebase "$MASTER"; then
    echo >&2
    echo "error: rebase of $DEVELOP onto $MASTER hit conflicts and stopped." >&2
    echo "       resolve them, then: git rebase --continue" >&2
    echo "       or back out entirely with: git rebase --abort" >&2
    exit 1
fi

AHEAD=$(git rev-list --count "$MASTER..$DEVELOP")
echo "==> $DEVELOP is now $AHEAD commit(s) ahead of $MASTER"

# --- 5. Optionally publish the rewritten develop ----------------------------
if [ -n "$PUSH_DEVELOP" ]; then
    echo "==> Force-pushing $DEVELOP to $FORK_REMOTE (--force-with-lease)"
    git push --force-with-lease "$FORK_REMOTE" "$DEVELOP"
    echo "==> NOTE: the scoop bucket clone now has the pre-rebase history."
    echo "    Resync it with:"
    echo "      git -C ~/scoop/buckets/zsh fetch $FORK_REMOTE $DEVELOP"
    echo "      git -C ~/scoop/buckets/zsh reset --hard $FORK_REMOTE/$DEVELOP"
else
    echo "==> $DEVELOP was rebased locally and NOT pushed."
    echo "    Review it, then publish with either:"
    echo "      sh helper/sync_branch.sh --push-develop"
    echo "      git push --force-with-lease $FORK_REMOTE $DEVELOP"
fi

# Leave the caller on the branch they started on.
if [ "$START_BRANCH" != "$DEVELOP" ]; then
    git checkout "$START_BRANCH"
fi

echo "==> Done."
