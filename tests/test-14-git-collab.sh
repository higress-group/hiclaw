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

Ensure workers alice, bob, and charlie exist with the git-delegation skill. Run the phases strictly in order, waiting for each phase's report before starting the next.

**Phase 1 — alice**:
- Clone ${GIT_REPO_URL}, create branch '${FEATURE_BRANCH}' from main
- Create file 'doc/proposal.md' with exactly this content:
  '# Project Proposal\n\n## Background\nThis project aims to improve team collaboration.\n\n## Goals\n- Faster delivery\n- Better quality'
- Commit with message 'feat: add proposal' and push branch to ${GIT_REPO_URL}
- Report PHASE1_DONE

**Phase 2 — bob** (only after alice reports PHASE1_DONE):
- Clone ${GIT_REPO_URL}, check out '${FEATURE_BRANCH}', read doc/proposal.md
- Create branch '${REVIEW_BRANCH}' from '${FEATURE_BRANCH}'
- Create file 'reviews/proposal-review.md' with exactly this content:
  '# Review\n\nThe proposal looks good. Please add a ## Summary section at the top that briefly describes the project in one sentence.'
- Commit 'review: request summary section' and push to ${GIT_REPO_URL}
- Report REVISION_NEEDED

**Phase 3 — alice** (only after bob reports REVISION_NEEDED):
- Check out '${FEATURE_BRANCH}', read bob's review at reviews/proposal-review.md on branch '${REVIEW_BRANCH}'
- Add a '## Summary' section at the top of doc/proposal.md (after the title) with one sentence describing the project
- Commit 'fix: add summary section per review' and push to ${GIT_REPO_URL}
- Report PHASE3_DONE

**Phase 4 — charlie** (only after alice reports PHASE3_DONE):
- Clone ${GIT_REPO_URL}, create branch '${TEST_BRANCH}' from '${FEATURE_BRANCH}'
- Create file 'verify/checklist.md' confirming: (1) proposal.md has a Summary section, (2) Goals section is present, (3) review was addressed
- Commit 'verify: proposal review checklist' and push to ${GIT_REPO_URL}
- Report PHASE4_DONE

Report to me when all 4 phases are done."

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

log_info "Waiting for Manager to report all 4 phases complete (timeout: 1800s)..."
COMPLETION_MSG=$(matrix_wait_for_message_containing \
    "${ADMIN_TOKEN}" "${DM_ROOM}" "@manager" \
    "PHASE4_DONE\|all.*phase.*done\|all 4 phase\|全部完成\|所有阶段" 1800) || true

if [ -n "${COMPLETION_MSG}" ]; then
    log_pass "Manager reported workflow completion"
    log_info "Completion message: $(echo "${COMPLETION_MSG}" | head -c 300)"
else
    log_info "Completion signal not detected (timed out or keyword mismatch); proceeding with git verification"
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
