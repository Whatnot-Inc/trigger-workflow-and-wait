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

# Run dispatch_workflow in a subshell and assert on exit status + call count.
run_dispatch_test() {
  local name=$1
  local expected_exit=$2
  local expected_calls=$3

  local output_file=$(mktemp)

  (dispatch_workflow) > "$output_file" 2>&1
  local actual_exit=$?
  local actual_calls=$(get_call_count)
  cleanup_mock

  if ! assert_result "$name" "$expected_exit" "$expected_calls" "$actual_exit" "$actual_calls"; then
    cat "$output_file"
  fi
  rm -f "$output_file"
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

# --- dispatch_workflow: dispatch retry/fail behavior ---

# Successful dispatch (HTTP 204, empty body) on first try
setup_mock_gh 0 0 "" ""
run_dispatch_test "Dispatch success (204) does not retry" 0 1

# Server error every time: retries up to max_attempts (3) then fails
setup_mock_gh 100 1 'gh: Failed to run workflow dispatch (HTTP 500)' ""
run_dispatch_test "Dispatch 500 retries then fails" 1 3

# Server error twice then success: proceeds
setup_mock_gh 2 1 'gh: Failed to run workflow dispatch (HTTP 500)' ""
run_dispatch_test "Dispatch 500 twice then succeeds" 0 3

# Non-retryable dispatch error (e.g. bad ref / 422) fails immediately
setup_mock_gh 100 1 'gh: Reference does not exist (HTTP 422)' ""
run_dispatch_test "Dispatch non-retryable error fails immediately" 1 1

# Cleanup
rm -f "$GITHUB_OUTPUT"

# Summary
echo "=== Results: $TESTS_PASSED passed, $TESTS_FAILED failed ==="
[ $TESTS_FAILED -eq 0 ]
