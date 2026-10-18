#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${RUNNER_DEBUG}" ]]; then set -x; fi

# Create branch sync PR.


# Determine What branch we are running on.
if [ "${GITHUB_EVENT_NAME}" = "schedule" ]
then
    # Scheduled runs operate on the oldest supported release branch,
    # determined via cylc-admin status page metadata.
    meta="$(curl -sSf -- "${STATUS_JSON_URL}" | jq .meta_releases)"
    min_version="$(echo "${meta}" | jq -r 'keys_unsorted.[]' | sort -V | head -1)"
    HEAD_BRANCH="$(echo "${meta}" | jq -r ".\"${min_version}\".\"${GITHUB_REPOSITORY}\"")"
elif [ -z "${HEAD_BRANCH:-}" ];
then
    HEAD_BRANCH="${GITHUB_REF_NAME}"
fi
if [[ "${HEAD_BRANCH}" = *-sync ]]
then
    echo "::error::Do not run this workflow on already-created sync branches."
    exit 1
fi
SYNC_BRANCH="${HEAD_BRANCH}-sync"


# Determine which branch to merge into, e.g:
# * if a change is made to 1.2.x, merge it into 1.3.x;
# * if a change is made to 1.3.x, merge it into 1.4.x;
# * if a change is made to 1.4.x, merge it into master.
# Default to the remote HEAD branch (typically either master or main).
BASE_BRANCH="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)"
is_next=false

# Run through bugfix branches in order, e.g. 1.2.x, 1.3.x, 1.4.x.
for branch in $(git branch --remotes --list origin/*.x | sed 's|^ *origin/||' | sort -V)
do
    if [ "${branch}" = "${HEAD_BRANCH}" ]
    then
        # This is the HEAD branch (the one with the new changes),
        # we should merge into the following bugfix branch.
        is_next=true
    elif [ -n "${IGNORE_BRANCH_PATTERN:-}" ] && grep -qE "${IGNORE_BRANCH_PATTERN}" <<< "${branch}"
    then
        # This branch is excluded by the provided pattern
        continue
    elif ${is_next}
    then
        # Merge into this branch.
        BASE_BRANCH="${branch}"
        break
    fi
done
echo "Determined base branch: ${BASE_BRANCH}."


git switch "${BASE_BRANCH}"
if git switch -c "${SYNC_BRANCH}" "origin/${SYNC_BRANCH}"
then
    echo "Pre-existing branch origin/${SYNC_BRANCH} found."
else
    echo "origin/${SYNC_BRANCH} does not currently exist."
fi

# Try a fast-forward merge.
current_branch="$(git branch --show-current)"
if git merge "origin/${HEAD_BRANCH}" --ff-only
then
    if [[ "$(git rev-parse --verify HEAD)" == "$(git rev-parse --verify "origin/${current_branch}")" ]]
    then
        echo "::notice::${current_branch} is up to date with ${HEAD_BRANCH}."
        exit 0
    elif [[ "${current_branch}" == "${SYNC_BRANCH}" ]]
    then
        git push origin "${SYNC_BRANCH}"
        echo "::notice::Fast-forwarded ${SYNC_BRANCH} to ${HEAD_BRANCH}."
        exit 0
    fi
elif [[ "${current_branch}" == "${SYNC_BRANCH}" ]]
then
    echo "::warning::Cannot fast-forward ${current_branch} to ${HEAD_BRANCH}; merge existing PR first."
    exit 0
fi

# Try a regular merge.
git switch "${BASE_BRANCH}"
if git merge "origin/${HEAD_BRANCH}"
then
    if git diff HEAD^ --exit-code --stat
    then
        echo "::notice::No difference between ${BASE_BRANCH} and ${HEAD_BRANCH}."
        exit 0
    fi
else
    git merge --abort
fi

# If a merge produces a difference, reset and open a pull request.
# A developer can do the merge on GitHub.
git switch -c "${SYNC_BRANCH}" "origin/${HEAD_BRANCH}"
git push origin "${SYNC_BRANCH}"

cat > "${TMPDIR}/pr_body.md" << EOF
**This is an automated "sync" PR**

We maintain bugfix branches in this repository in order to allow us to continue developing bugfixes for older versions, while simultaneously developing features for newer versions.

When bugfix PRs are merged into a bugfix branch, a "sync" PR is automatically created to merge a copy of the bugfix branch into the next feature branch (usually master). The author of the bugfix typically reviews and merges this PR.

What you are reviewing here are the original bugfix(es) in the context of the new branch. Sometimes changes need to be made as part of this porting:

- To resolve conflicts.
- If there are (non-conflicting) incompatible changes in different parts of the codebase.

**If any changes are required** -> please push new commits to this branch and assign someone else to review them.

**Otherwise** -> please approve and merge this PR.

> [!IMPORTANT]
> Please do a **normal merge**, not squash merge.

---

<small>
Triggered by \`${GITHUB_EVENT_NAME}\` in Actions run ${GITHUB_RUN_ID}.
</small>
EOF

url="$(
    gh pr create \
        --head "${SYNC_BRANCH}" \
        --base "${BASE_BRANCH}" \
        --title "🤖 Merge ${SYNC_BRANCH} into ${BASE_BRANCH}" \
        --body-file "${TMPDIR}/pr_body.md"
)"
echo "::notice::Pull request opened at ${url}"
# Attempt to add sync label.
gh pr edit "${url}" --add-label "sync" || true
