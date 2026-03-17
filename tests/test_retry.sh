#!/usr/bin/env bash
# Unit tests for api() retry behavior in entrypoint.sh
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

# Helper: set up a mock curl using a file-based call counter (needed because
# api() invokes curl inside a command substitution / subshell)
setup_mock_curl() {
  local fail_count=$1
  local fail_exit_code=$2
  local fail_response=$3

  CALL_COUNT_FILE=$(mktemp)
  echo 0 > "$CALL_COUNT_FILE"

  # Export vars so the function can access them in subshells
  export CALL_COUNT_FILE FAIL_COUNT="$fail_count" FAIL_EXIT_CODE="$fail_exit_code" FAIL_RESPONSE="$fail_response"

  curl() {
    local count=$(($(cat "$CALL_COUNT_FILE") + 1))
    echo $count > "$CALL_COUNT_FILE"
    if [ $count -le $FAIL_COUNT ]; then
      if [ -n "$FAIL_RESPONSE" ]; then
        echo "$FAIL_RESPONSE"
      fi
      return "$FAIL_EXIT_CODE"
    fi
    echo '{"conclusion": "success", "status": "completed"}'
    return 0
  }
  export -f curl
}

get_call_count() {
  cat "$CALL_COUNT_FILE"
}

cleanup_mock() {
  rm -f "$CALL_COUNT_FILE"
  # Reset NOT_FOUND_RETRIES between tests
  NOT_FOUND_RETRIES=0
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
run_test() {
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

# Transient network errors: fail twice then succeed
setup_mock_curl 2 6 ""
run_test "DNS resolution failure (exit 6) retries" 0 3

setup_mock_curl 2 7 ""
run_test "Connection refused (exit 7) retries" 0 3

setup_mock_curl 2 28 ""
run_test "Timeout (exit 28) retries" 0 3

setup_mock_curl 2 35 ""
run_test "SSL connect error (exit 35) retries" 0 3

setup_mock_curl 2 56 ""
run_test "Recv failure (exit 56) retries" 0 3

# HTTP errors: --fail-with-body makes curl exit 22, response body is available
setup_mock_curl 2 22 '{"message": "Server Error"}'
run_test "Server error retries" 0 3

setup_mock_curl 2 22 '{"message": "Not Found"}'
run_test "Not found retries" 0 3

# Happy path
setup_mock_curl 0 0 ""
run_test "Immediate success" 0 1

# Non-retryable errors exit immediately
setup_mock_curl 100 22 '{"message": "Bad credentials"}'
run_test "Non-retryable error (403) exits" 1 1

# Cleanup
rm -f "$GITHUB_OUTPUT"

# Summary
echo "=== Results: $TESTS_PASSED passed, $TESTS_FAILED failed ==="
[ $TESTS_FAILED -eq 0 ]
