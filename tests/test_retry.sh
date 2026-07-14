#!/usr/bin/env bash
# Unit tests for api()/dispatch retry behavior in entrypoint.sh
set +e

TESTS_PASSED=0
TESTS_FAILED=0

# Required env vars
export INPUT_OWNER="test-owner"
export INPUT_REPO="test-repo"
export INPUT_GITHUB_TOKEN="fake-token"
export INPUT_WORKFLOW_FILE_NAME="test.yml"
export GITHUB_OUTPUT=$(mktemp)

# Source functions without running main
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source <(sed '/^main$/d' "$REPO_ROOT/entrypoint.sh")
set +e  # Re-disable set -e (entrypoint.sh enables it)

# Use short wait interval for fast tests
wait_interval=0
propagate_failure=true
ref="main"
client_payload="{}"

# Helper: set up a mock `gh` using a file-based call counter (needed because
# api() invokes gh inside a command substitution / subshell). The code under
# test calls `gh api <path> ...`, so the mock ignores the leading `api` arg.
setup_mock_gh() {
  local fail_count=$1
  local fail_exit_code=$2
  local fail_response=$3
  local success_response=${4:-'{"conclusion": "success", "status": "completed"}'}

  CALL_COUNT_FILE=$(mktemp)
  echo 0 > "$CALL_COUNT_FILE"

  export CALL_COUNT_FILE FAIL_COUNT="$fail_count" FAIL_EXIT_CODE="$fail_exit_code" \
    FAIL_RESPONSE="$fail_response" SUCCESS_RESPONSE="$success_response"

  gh() {
    local count=$(($(cat "$CALL_COUNT_FILE") + 1))
    echo $count > "$CALL_COUNT_FILE"
    if [ $count -le $FAIL_COUNT ]; then
      if [ -n "$FAIL_RESPONSE" ]; then
        echo "$FAIL_RESPONSE"
      fi
      return "$FAIL_EXIT_CODE"
    fi
    if [ -n "$SUCCESS_RESPONSE" ]; then
      echo "$SUCCESS_RESPONSE"
    fi
    return 0
  }
  export -f gh
}

get_call_count() {
  cat "$CALL_COUNT_FILE"
}

cleanup_mock() {
  rm -f "$CALL_COUNT_FILE"
  # Reset state between tests
  NOT_FOUND_RETRIES=0
  RUN_IDS=
  unset -f gh
}

assert_result() {
  local name=$1
  local expected_exit=$2
  local expected_calls=$3
  local actual_exit=$4
  local actual_calls=$5

  if [ $actual_exit -eq $expected_exit ] && [ $actual_calls -eq $expected_calls ]; then
    echo "PASS $name"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    return 0
  else
    echo "FAIL $name: expected exit=$expected_exit calls=$expected_calls, got exit=$actual_exit calls=$actual_calls"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return 1
  fi
}

# Run wait_for_workflow_to_finish in a subshell so that exit 1 from
# non-retryable errors doesn't kill the test harness.
run_wait_test() {
  local name=$1
  local expected_exit=$2
  local expected_calls=$3

  > "$GITHUB_OUTPUT"
  local output_file=$(mktemp)

  (wait_for_workflow_to_finish "12345") > "$output_file" 2>&1
  local actual_exit=$?
  local actual_calls=$(get_call_count)
  cleanup_mock

  if ! assert_result "$name" "$expected_exit" "$expected_calls" "$actual_exit" "$actual_calls"; then
    cat "$output_file"
  fi
  rm -f "$output_file"
}

# Run dispatch_workflow and assert on its classification (DISPATCH_OUTCOME).
# dispatch_workflow makes exactly one gh call, so we assert calls=1 always.
run_dispatch_test() {
  local name=$1
  local expected_outcome=$2

  local output_file=$(mktemp)
  DISPATCH_OUTCOME=
  dispatch_workflow > "$output_file" 2>&1
  local actual_outcome=$DISPATCH_OUTCOME
  local actual_calls=$(get_call_count)
  cleanup_mock

  if [ "$actual_outcome" = "$expected_outcome" ] && [ "$actual_calls" -eq 1 ]; then
    echo "PASS $name"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "FAIL $name: expected outcome=$expected_outcome calls=1, got outcome=$actual_outcome calls=$actual_calls"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    cat "$output_file"
  fi
  rm -f "$output_file"
}

# --- Mock for trigger_workflow orchestration tests ---
# Distinguishes dispatch POSTs (path contains "/dispatches") from run-list
# queries (path contains "/runs?"). Driven by env:
#   DISPATCH_SCRIPT : space-separated outcomes per dispatch attempt, each one of
#                     ok|500|net|422 (ok = HTTP 204 success).
#   RUNS_APPEAR_ON  : the get_workflow_runs call index (1-based) at/after which a
#                     NEW run id appears. 0 = never appears.
# A separate counter tracks run-list calls so RUNS_APPEAR_ON is deterministic.
setup_mock_orchestration() {
  export DISPATCH_SCRIPT="$1"
  export RUNS_APPEAR_ON="$2"

  CALL_COUNT_FILE=$(mktemp)          # dispatch attempts
  RUNS_CALL_FILE=$(mktemp)           # get_workflow_runs calls
  echo 0 > "$CALL_COUNT_FILE"
  echo 0 > "$RUNS_CALL_FILE"
  export CALL_COUNT_FILE RUNS_CALL_FILE

  # trigger_workflow uses `date +%s` and GNU `date -d` (present in the action's
  # Alpine image but not on BSD/macOS). Stub both forms so timestamps resolve
  # regardless of platform.
  date() {
    if [ "$1" = "+%s" ]; then echo 1577836800; else echo "2020-01-01T00:00:00+00:00"; fi
  }
  export -f date

  gh() {
    # gh api <path> ...  -> $2 is the repos/.../actions/<path> string
    local path="$2"
    if [[ "$path" == *"/dispatches" ]]; then
      local n=$(($(cat "$CALL_COUNT_FILE") + 1))
      echo $n > "$CALL_COUNT_FILE"
      local outcome=$(echo "$DISPATCH_SCRIPT" | cut -d' ' -f"$n")
      case "$outcome" in
        ok|"") return 0 ;;  # HTTP 204, empty body
        500) echo 'gh: Failed to run workflow dispatch (HTTP 500)'; return 1 ;;
        net) echo 'Post "https://api.github.com/...": dial tcp: connection refused'; return 1 ;;
        422) echo 'gh: Reference does not exist (HTTP 422)'; return 1 ;;
      esac
      return 1
    fi
    # Otherwise it's a runs list query.
    local r=$(($(cat "$RUNS_CALL_FILE") + 1))
    echo $r > "$RUNS_CALL_FILE"
    if [ "$RUNS_APPEAR_ON" -ne 0 ] && [ "$r" -ge "$RUNS_APPEAR_ON" ]; then
      echo '{"workflow_runs":[{"id":111},{"id":999}]}'
    else
      echo '{"workflow_runs":[{"id":111}]}'
    fi
    return 0
  }
  export -f gh
}

cleanup_orchestration() {
  rm -f "$CALL_COUNT_FILE" "$RUNS_CALL_FILE"
  RUN_IDS=
  DISPATCH_OUTCOME=
  unset -f gh date
}

# Run trigger_workflow and assert exit status, resulting RUN_IDS, and number of
# dispatch attempts made.
run_trigger_test() {
  local name=$1
  local expected_exit=$2
  local expected_run_ids=$3
  local expected_dispatches=$4

  local output_file=$(mktemp)
  local run_ids_file=$(mktemp)
  # Run in a subshell (exit 1 must not kill the harness); capture RUN_IDS via file.
  ( trigger_workflow; echo "$RUN_IDS" > "$run_ids_file" ) > "$output_file" 2>&1
  local actual_exit=$?
  local actual_run_ids=$(cat "$run_ids_file" 2>/dev/null | tr -d '[:space:]')
  local actual_dispatches=$(cat "$CALL_COUNT_FILE")
  cleanup_orchestration

  if [ "$actual_exit" -eq "$expected_exit" ] && \
     [ "$actual_run_ids" = "$expected_run_ids" ] && \
     [ "$actual_dispatches" -eq "$expected_dispatches" ]; then
    echo "PASS $name"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "FAIL $name: expected exit=$expected_exit run_ids=$expected_run_ids dispatches=$expected_dispatches, got exit=$actual_exit run_ids=$actual_run_ids dispatches=$actual_dispatches"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    cat "$output_file"
  fi
  rm -f "$output_file" "$run_ids_file"
}

# --- wait_for_workflow_to_finish: api() retry behavior ---

# Transient network errors: fail twice then succeed. api() classifies these by
# matching gh's textual error output, so the mock emits representative messages.
setup_mock_gh 2 1 'error connecting to api.github.com'
run_wait_test "DNS resolution failure retries" 0 3

setup_mock_gh 2 1 'Post "https://api.github.com/...": dial tcp: connection refused'
run_wait_test "Connection refused retries" 0 3

setup_mock_gh 2 1 'Get "https://api.github.com/...": context deadline exceeded'
run_wait_test "Timeout retries" 0 3

# HTTP errors surfaced by gh
setup_mock_gh 2 1 'gh: Server Error (HTTP 500)'
run_wait_test "Server error retries" 0 3

setup_mock_gh 2 1 'gh: Not Found (HTTP 404)'
run_wait_test "Not found retries" 0 3

# Happy path
setup_mock_gh 0 0 ""
run_wait_test "Immediate success" 0 1

# Non-retryable errors exit immediately
setup_mock_gh 100 1 'gh: Bad credentials (HTTP 401)'
run_wait_test "Non-retryable error (401) exits" 1 1

# --- dispatch_workflow: outcome classification ---

# HTTP 204 (empty body) success
setup_mock_gh 0 0 "" ""
run_dispatch_test "Dispatch 204 -> success" success

# 5xx server error -> ambiguous (may have created a run)
setup_mock_gh 1 1 'gh: Failed to run workflow dispatch (HTTP 500)' ""
run_dispatch_test "Dispatch 500 -> ambiguous" ambiguous

# Network error (no response received) -> ambiguous
setup_mock_gh 1 1 'Post "https://api.github.com/...": dial tcp: connection refused' ""
run_dispatch_test "Dispatch network error -> ambiguous" ambiguous

# 4xx client error -> fatal (no run created)
setup_mock_gh 1 1 'gh: Reference does not exist (HTTP 422)' ""
run_dispatch_test "Dispatch 422 -> fatal" fatal

# --- trigger_workflow: poll-first / re-dispatch-once orchestration ---

# 204 success, new run surfaces on first poll -> wait on it, 1 dispatch.
# runs call #1 is OLD_RUNS (no new run); the new run appears on poll call #2.
setup_mock_orchestration "ok" 2
run_trigger_test "Success then run appears" 0 999 1

# 5xx, but a run was created and appears within the 3-poll window ->
# wait on it WITHOUT re-dispatching (avoids double-dispatch)
setup_mock_orchestration "500" 2
run_trigger_test "Ambiguous but run appeared -> no re-dispatch" 0 999 1

# 5xx, no run appears -> re-dispatch once; second attempt also 5xx with no
# run -> abort. Runs never appear, so 2 total dispatches then exit 1.
setup_mock_orchestration "500 500" 0
run_trigger_test "Ambiguous, no run, re-dispatch once then fail" 1 "" 2

# 5xx with no run, then re-dispatch succeeds (204) and run appears ->
# wait on it, 2 dispatches
setup_mock_orchestration "500 ok" 5
run_trigger_test "Ambiguous then re-dispatch succeeds" 0 999 2

# 4xx fatal -> abort immediately, 1 dispatch, no run
setup_mock_orchestration "422" 0
run_trigger_test "Fatal dispatch aborts immediately" 1 "" 1

# Cleanup
rm -f "$GITHUB_OUTPUT"

# Summary
echo "=== Results: $TESTS_PASSED passed, $TESTS_FAILED failed ==="
[ $TESTS_FAILED -eq 0 ]
