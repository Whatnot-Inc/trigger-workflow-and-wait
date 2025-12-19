# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a GitHub Action that triggers a workflow in another repository and waits for it to complete. It's implemented as a Docker-based action using a bash entrypoint script.

## Architecture

### Core Components

- **action.yml**: GitHub Action definition with input/output specifications
- **entrypoint.sh**: Main bash script that handles the workflow triggering and polling logic
- **Dockerfile**: Alpine-based container with curl, jq, and coreutils dependencies

### Key Implementation Details

**entrypoint.sh** contains the core logic:
- `trigger_workflow()`: Dispatches workflow via GitHub API, identifies new run by comparing workflow runs before/after dispatch
- `wait_for_workflow_to_finish()`: Polls workflow status until completion, optionally propagates failures upstream
- `get_workflow_runs()`: Queries recent workflow runs, optionally filtered by actor
- `api()`: Wrapper for GitHub API calls with retry logic (3 retries for 404s, retries for server errors)
- Uses ISO-8601 timestamps with 2-minute clock skew tolerance when identifying triggered runs

**Run identification strategy**: Compares workflow run IDs before and after triggering to identify the newly created run, using `join -v2` to find the difference.

**Retry behavior**: The `api()` function retries 404 responses up to 3 times (tracked via `NOT_FOUND_RETRIES`) and automatically retries server errors.

## Testing

### Local Testing
Test the action locally without GitHub Actions:
```bash
INPUT_OWNER="owner" \
INPUT_REPO="repo" \
INPUT_GITHUB_TOKEN="<token>" \
INPUT_WORKFLOW_FILE_NAME="workflow.yml" \
INPUT_REF="main" \
INPUT_WAIT_INTERVAL=10 \
INPUT_CLIENT_PAYLOAD='{}' \
INPUT_PROPAGATE_FAILURE=true \
INPUT_TRIGGER_WORKFLOW=true \
INPUT_WAIT_WORKFLOW=true \
busybox sh entrypoint.sh
```

### Self-Test Workflow
The `.github/workflows/build.yaml` includes a self-test job that:
1. Triggers the `selftest.yaml` workflow (which sleeps for 30 seconds)
2. Waits for completion
3. Validates the action works end-to-end

Run the self-test workflow manually via workflow_dispatch or by pushing to master/tags.

## Development Guidelines

### Bash Script Modifications
- The script uses `set -e` for fail-fast behavior
- All API calls should go through the `api()` function for consistent error handling and retries
- Use `>&2` for logging to stderr to keep stdout clean for data piping
- The script depends on `jq` for JSON parsing and `date -u -Iseconds` for timestamp formatting

### Docker Image
- Based on Alpine 3.15.0 for minimal size
- Required packages: curl (API calls), jq (JSON parsing), coreutils (GNU date command)
- Rebuilding the Docker image is required for any changes to entrypoint.sh

### API Interactions
- Uses GitHub Actions API v3 (`application/vnd.github.v3+json`)
- Configurable API URL via `API_URL` env var (defaults to `https://api.github.com`)
- Configurable server URL via `SERVER_URL` env var (defaults to `https://github.com`)
- All API paths are under `/repos/{owner}/{repo}/actions/`

### Output Variables
The action sets these outputs in `$GITHUB_OUTPUT`:
- `workflow_id`: ID of the triggered workflow run
- `workflow_url`: Browser URL to view the workflow run
- `conclusion`: Final conclusion (success, failure, etc.)

## Common Patterns

### Adding New Input Parameters
1. Add to `inputs` section in action.yml
2. Add validation/default value logic in `validate_args()` function
3. Access via `INPUT_<UPPERCASE_NAME>` environment variable

### Modifying Retry Logic
The `api()` function tracks retries in `NOT_FOUND_RETRIES` global variable. Server errors always retry. Modify retry counts or add new retry conditions in the `api()` function's error handling block.

### Adding Comment Functionality
See `comment_downstream_link()` for an example of posting comments to GitHub. Uses `INPUT_COMMENT_GITHUB_TOKEN` (defaults to `${{github.token}}`) for authentication.
