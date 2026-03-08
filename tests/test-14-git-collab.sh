#!/bin/bash
# test-14-git-collab.sh - Case 14: Non-linear multi-Worker local git collaboration
# Verifies: 4-phase PR-style collaboration using local bare git repo (no GitHub required):
#   Phase 1 (alice): implement feature on a branch
#   Phase 2 (bob): review and request changes via a review branch
#   Phase 3 (alice): fix based on review, update branch
#   Phase 4 (charlie): add tests on a test branch

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/test-helpers.sh"
source "${SCRIPT_DIR}/lib/matrix-client.sh"
source "${SCRIPT_DIR}/lib/agent-metrics.sh"

test_setup "14-git-collab"

if ! require_llm_key; then
    test_teardown "14-git-collab"
    test_summary
    exit 0
fi

ADMIN_LOGIN=$(matrix_login "${TEST_ADMIN_USER}" "${TEST_ADMIN_PASSWORD}")
ADMIN_TOKEN=$(echo "${ADMIN_LOGIN}" | jq -r '.access_token')

MANAGER_USER="@manager:${TEST_MATRIX_DOMAIN}"

# Generate unique branch names for this test run
TEST_RUN_ID=$(date +%s)
REPO_PATH="/root/git-repos/collab-test-${TEST_RUN_ID}"
FEATURE_BRANCH="feature/proposal-${TEST_RUN_ID}"
REVIEW_BRANCH="review/proposal-${TEST_RUN_ID}"
TEST_BRANCH="verify/proposal-${TEST_RUN_ID}"

log_section "Setup: Initialize Bare Git Repo"

docker exec "${TEST_MANAGER_CONTAINER}" bash -c "
    set -e
    mkdir -p '${REPO_PATH}.git'
    git init --bare '${REPO_PATH}.git'
    tmpdir=\$(mktemp -d)
    git -C \"\$tmpdir\" init
    git -C \"\$tmpdir\" remote add origin '${REPO_PATH}.git'
    echo '# Collab Test Project' > \"\$tmpdir/README.md\"
    git -C \"\$tmpdir\" add .
    git -C \"\$tmpdir\" -c user.email='setup@hiclaw.io' -c user.name='Setup' -c core.hooksPath=/dev/null commit -m 'Initial commit'
    git -C \"\$tmpdir\" push origin HEAD:main
    rm -rf \"\$tmpdir\"
" || {
    log_fail "Failed to initialize bare git repo"
    test_teardown "14-git-collab"
    test_summary
    exit 1
}
log_pass "Bare git repo initialized at ${REPO_PATH}.git"

# Start git daemon so worker containers can access the repo via git:// protocol
MANAGER_IP=$(docker inspect "${TEST_MANAGER_CONTAINER}" \
    --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null | head -1)
docker exec "${TEST_MANAGER_CONTAINER}" bash -c "
    git daemon --base-path=/root/git-repos \
        --export-all --enable=receive-pack \
        --reuseaddr --port=9418 \
        --pid-file=/tmp/git-daemon.pid \
        --detach 2>/dev/null || true
"
sleep 2
GIT_REPO_URL="git://${MANAGER_IP}/collab-test-${TEST_RUN_ID}"
log_info "Git daemon started; repo URL for workers: ${GIT_REPO_URL}"

log_section "Setup: Find or Create DM Room"

DM_ROOM=$(matrix_find_dm_room "${ADMIN_TOKEN}" "${MANAGER_USER}" 2>/dev/null || true)

if [ -z "${DM_ROOM}" ]; then
    log_info "Creating DM room with Manager..."
    DM_ROOM=$(matrix_create_dm_room "${ADMIN_TOKEN}" "${MANAGER_USER}")
    sleep 5
fi

assert_not_empty "${DM_ROOM}" "DM room with Manager exists"

wait_for_manager_agent_ready 300 "${DM_ROOM}" "${ADMIN_TOKEN}" || {
    log_fail "Manager Agent not ready in time"
    docker exec "${TEST_MANAGER_CONTAINER}" rm -rf "${REPO_PATH}.git" 2>/dev/null || true
    test_teardown "14-git-collab"
    test_summary
    exit 1
}

log_section "Phase 1-4: Assign 4-Phase Git Collaboration Task"

TASK_DESCRIPTION="Please coordinate a 4-phase git collaboration workflow to test non-linear multi-worker coordination.

Git repo URL (reachable from all worker containers): ${GIT_REPO_URL}
The repo has a 'main' branch with an initial commit.

⚠️ CRITICAL WORKER ASSIGNMENT TABLE — MUST FOLLOW EXACTLY, NO EXCEPTIONS:

| Phase | Assigned Worker | Trigger condition                     |
|-------|-----------------|---------------------------------------|
| 1     | alice           | start immediately                     |
| 2     | bob             | ONLY after alice reports PHASE1_DONE  |
| 3     | alice           | ONLY after bob reports REVISION_NEEDED|
| 4     | charlie         | ONLY after alice reports PHASE3_DONE  |

DO NOT assign any phase to a different worker. DO NOT give alice phase 2 or phase 4. DO NOT give bob phase 1 or phase 3. DO NOT give charlie any phase except phase 4. Each phase must be done by the worker listed above and no one else.

IMPORTANT: You MUST use the EXACT branch names and file paths specified below. Do not rename, substitute, or simplify them. The verification system checks these exact names.

Ensure workers alice, bob, and charlie exist with the git-delegation skill. Run the phases strictly in order, waiting for each phase's report before starting the next.

**Phase 1 — alice (and only alice)**:
- Clone ${GIT_REPO_URL}
- Create branch named EXACTLY '${FEATURE_BRANCH}' from main (do not use any other name)
- Create file at path EXACTLY 'doc/proposal.md' with this content:
  # Project Proposal

  ## Background
  This project aims to improve team collaboration.

  ## Goals
  - Faster delivery
  - Better quality
- Commit with message 'feat: add proposal' and push branch '${FEATURE_BRANCH}' to ${GIT_REPO_URL}
- Report PHASE1_DONE

**Phase 2 — bob and only bob** (assign to bob, NOT alice, only after alice reports PHASE1_DONE):
- Clone ${GIT_REPO_URL}, check out branch '${FEATURE_BRANCH}', read doc/proposal.md
- Create branch named EXACTLY '${REVIEW_BRANCH}' from '${FEATURE_BRANCH}' (do not use any other name)
- Create file at path EXACTLY 'reviews/proposal-review.md' with this content:
  # Review

  The proposal looks good. Please add a ## Summary section at the top that briefly describes the project in one sentence.
- Commit 'review: request summary section' and push branch '${REVIEW_BRANCH}' to ${GIT_REPO_URL}
- Report REVISION_NEEDED

**Phase 3 — alice and only alice** (assign back to alice, NOT bob, only after bob reports REVISION_NEEDED):
- Work on branch '${FEATURE_BRANCH}' (not a new branch)
- Read bob's review file at path 'reviews/proposal-review.md' on branch '${REVIEW_BRANCH}'
- Edit 'doc/proposal.md' on branch '${FEATURE_BRANCH}': add a '## Summary' section immediately after the '# Project Proposal' title line, with one sentence describing the project
- Commit 'fix: add summary section per review' and push branch '${FEATURE_BRANCH}' to ${GIT_REPO_URL}
- Report PHASE3_DONE

**Phase 4 — charlie and only charlie** (assign to charlie, NOT alice or bob, only after alice reports PHASE3_DONE):
- Clone ${GIT_REPO_URL}, create branch named EXACTLY '${TEST_BRANCH}' from '${FEATURE_BRANCH}' (do not use any other name)
- Create file at path EXACTLY 'verify/checklist.md' confirming: (1) proposal.md has a Summary section, (2) Goals section is present, (3) review was addressed
- Commit 'verify: proposal review checklist' and push branch '${TEST_BRANCH}' to ${GIT_REPO_URL}
- Report PHASE4_DONE

When all 4 phases are done, post a final summary in the project room."

# Snapshot before first LLM interaction
METRICS_BASELINE=$(snapshot_baseline "alice" "bob" "charlie")

matrix_send_message "${ADMIN_TOKEN}" "${DM_ROOM}" "${TASK_DESCRIPTION}"

log_info "Waiting for Manager to acknowledge and start coordination..."
REPLY=$(matrix_wait_for_reply "${ADMIN_TOKEN}" "${DM_ROOM}" "@manager" 300)

if [ -n "${REPLY}" ]; then
    log_pass "Manager acknowledged the git collaboration task"
else
    log_info "No explicit acknowledgment (Manager may have started processing directly)"
fi

log_section "Wait for Workflow Completion (up to 30 minutes)"

log_info "Polling git branches for phase completion (timeout: 1800s, interval: 30s)..."
WORKFLOW_DONE=false
DEADLINE=$(( $(date +%s) + 1800 ))
while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
    P1=$(docker exec "${TEST_MANAGER_CONTAINER}" \
        git -C "${REPO_PATH}.git" show "${FEATURE_BRANCH}:doc/proposal.md" 2>/dev/null | wc -c)
    P2=$(docker exec "${TEST_MANAGER_CONTAINER}" \
        git -C "${REPO_PATH}.git" show "${REVIEW_BRANCH}:reviews/proposal-review.md" 2>/dev/null | wc -c)
    P3=$(docker exec "${TEST_MANAGER_CONTAINER}" \
        git -C "${REPO_PATH}.git" show "${FEATURE_BRANCH}:doc/proposal.md" 2>/dev/null | grep -ci "summary" || true)
    P4=$(docker exec "${TEST_MANAGER_CONTAINER}" \
        git -C "${REPO_PATH}.git" show "${TEST_BRANCH}:verify/checklist.md" 2>/dev/null | wc -c)
    log_info "Phase progress — P1:${P1}B P2:${P2}B P3_summary:${P3} P4:${P4}B"
    if [ "${P1}" -gt 0 ] && [ "${P2}" -gt 0 ] && [ "${P3}" -gt 0 ] && [ "${P4}" -gt 0 ]; then
        WORKFLOW_DONE=true
        log_pass "All 4 phases detected in git — workflow complete"
        break
    fi
    sleep 30
done

if [ "${WORKFLOW_DONE}" != "true" ]; then
    log_info "Git polling timed out; proceeding with verification (some phases may have partial results)"
fi

MESSAGES=$(matrix_read_messages "${ADMIN_TOKEN}" "${DM_ROOM}" 100)
MSG_BODIES=$(echo "${MESSAGES}" | jq -r '[.chunk[].content.body] | join("\n---\n")' 2>/dev/null)

log_section "Verify Phase Results via Git"

# Phase 1: alice's feature branch has proposal.md with Goals section
PROPOSAL=$(docker exec "${TEST_MANAGER_CONTAINER}" \
    git -C "${REPO_PATH}.git" show "${FEATURE_BRANCH}:doc/proposal.md" 2>/dev/null)
assert_not_empty "${PROPOSAL}" "Phase 1: doc/proposal.md exists on ${FEATURE_BRANCH}"
assert_contains_i "${PROPOSAL}" "Goals" "Phase 1: proposal.md has Goals section"

# Phase 2: bob's review branch has review file requesting summary
REVIEW=$(docker exec "${TEST_MANAGER_CONTAINER}" \
    git -C "${REPO_PATH}.git" show "${REVIEW_BRANCH}:reviews/proposal-review.md" 2>/dev/null)
assert_not_empty "${REVIEW}" "Phase 2: reviews/proposal-review.md exists on ${REVIEW_BRANCH}"
assert_contains_i "${REVIEW}" "summary" "Phase 2: review requests a Summary section"

# Phase 3: alice's updated proposal has the Summary section bob requested (non-linear dependency)
UPDATED_PROPOSAL=$(docker exec "${TEST_MANAGER_CONTAINER}" \
    git -C "${REPO_PATH}.git" show "${FEATURE_BRANCH}:doc/proposal.md" 2>/dev/null)
assert_contains_i "${UPDATED_PROPOSAL}" "Summary" "Phase 3: Summary section added per bob's review (non-linear: A→B→A)"

# Verify Phase 3 is a NEW commit on top of Phase 1 (alice updated the branch)
P1_COMMIT=$(docker exec "${TEST_MANAGER_CONTAINER}" \
    git -C "${REPO_PATH}.git" log "${FEATURE_BRANCH}" --oneline 2>/dev/null | wc -l)
assert_not_empty "${P1_COMMIT}" "Phase 3: ${FEATURE_BRANCH} has commits"
if [ "${P1_COMMIT}" -ge 2 ] 2>/dev/null; then
    log_pass "Phase 3: feature branch has multiple commits (alice updated after bob's review)"
else
    log_info "Phase 3: commit count on feature branch: ${P1_COMMIT}"
fi

# Phase 4: charlie's verify branch has checklist confirming the review was addressed
CHECKLIST=$(docker exec "${TEST_MANAGER_CONTAINER}" \
    git -C "${REPO_PATH}.git" show "${TEST_BRANCH}:verify/checklist.md" 2>/dev/null)
assert_not_empty "${CHECKLIST}" "Phase 4: verify/checklist.md exists on ${TEST_BRANCH}"
assert_contains_i "${CHECKLIST}" "summary\|review" "Phase 4: checklist confirms review was addressed"

# Matrix message phase reports
if echo "${MSG_BODIES}" | grep -qi "PHASE1_DONE"; then
    log_pass "Phase 1 completion reported in Matrix"
fi
if echo "${MSG_BODIES}" | grep -qi "REVISION_NEEDED"; then
    log_pass "Phase 2 review reported in Matrix"
fi
if echo "${MSG_BODIES}" | grep -qi "PHASE3_DONE"; then
    log_pass "Phase 3 fix reported in Matrix"
fi
if echo "${MSG_BODIES}" | grep -qi "PHASE4_DONE"; then
    log_pass "Phase 4 verification reported in Matrix"
fi

log_section "Collect Metrics"

wait_for_session_stable 5 60
METRICS=$(collect_delta_metrics "14-git-collab" "$METRICS_BASELINE" "alice" "bob" "charlie")
save_metrics_file "$METRICS" "14-git-collab"
print_metrics_report "$METRICS"

log_section "Cleanup"

# Stop git daemon
docker exec "${TEST_MANAGER_CONTAINER}" bash -c "
    if [ -f /tmp/git-daemon.pid ]; then
        kill \$(cat /tmp/git-daemon.pid) 2>/dev/null || true
        rm -f /tmp/git-daemon.pid
    fi
" 2>/dev/null || true
docker exec "${TEST_MANAGER_CONTAINER}" rm -rf "${REPO_PATH}.git" 2>/dev/null || true
log_info "Removed bare git repo and stopped git daemon"

test_teardown "14-git-collab"
test_summary
