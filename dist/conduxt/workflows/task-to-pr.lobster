# =============================================================================
# Task-to-PR Deterministic Workflow
# =============================================================================
# This Lobster workflow defines the deterministic pipeline from any coding task
# to Pull Request. Supports dual backends (ACPX preferred, tmux fallback).
# Task sources: natural language description, GitHub issue, doc link, etc.
# =============================================================================

name: task-to-pr
description: >
  End-to-end workflow: parse task → create branch → launch coding agent
  (ACPX or tmux) → verify tests → create PR → notify user.
version: "1.0.0"

# ---------------------------------------------------------------------------
# Input Parameters
# ---------------------------------------------------------------------------
inputs:
  task_description:
    type: string
    required: true
    description: "Task description (natural language, issue body, requirement text)"
  task_id:
    type: string
    required: true
    description: "Unique task identifier (e.g., add-pagination, perf-analysis)"
  branch:
    type: string
    required: true
    description: "Git branch name (e.g., feat/add-pagination)"
  base_branch:
    type: string
    default: "main"
    description: "Base branch to create feature branch from"
  backend:
    type: string
    default: "auto"
    description: "Agent backend: acpx (preferred), tmux (fallback), auto (detect)"
  agent:
    type: string
    default: "auto"
    description: "Coding agent: claude, gemini, codex, aider, auto (detect)"
  auto_pr:
    type: boolean
    default: true
    description: "Automatically create PR on completion"
  require_approval:
    type: boolean
    default: false
    description: "Require human approval before creating PR"
  notify_channel:
    type: string
    default: "system"
    description: "Notification channel (system|telegram|slack)"

# ---------------------------------------------------------------------------
# Stages
# ---------------------------------------------------------------------------
stages:

  # -------------------------------------------------------------------------
  # Stage 1: Setup Environment
  # -------------------------------------------------------------------------
  - name: setup
    description: "Create branch, worktree, and initialize tracking"
    action: shell
    command: |
      TASK_ID="{{ inputs.task_id }}"
      BRANCH="{{ inputs.branch }}"
      WORKTREE_DIR="../worktrees/${TASK_ID}"
      TASK_DESC="{{ inputs.task_description }}"
      BACKEND="{{ inputs.backend }}"

      bash skills/conduxt/scripts/setup.sh \
        "$TASK_ID" "$BRANCH" "$WORKTREE_DIR" "$TASK_DESC" "$BACKEND"
    outputs:
      task_id: "{{ inputs.task_id }}"
      branch: "{{ inputs.branch }}"
      worktree: "../worktrees/{{ inputs.task_id }}"
    on_failure:
      - action: notify
        message: "Setup failed for task '{{ inputs.task_id }}'"
      - action: abort

  # -------------------------------------------------------------------------
  # Stage 2: Launch Agent
  # -------------------------------------------------------------------------
  - name: launch-agent
    description: "Start coding agent via ACPX (preferred) or tmux (fallback)"
    depends_on: [setup]
    action: shell
    command: |
      TASK_ID="{{ stages.setup.outputs.task_id }}"
      WORKTREE="{{ stages.setup.outputs.worktree }}"
      BACKEND="{{ inputs.backend }}"
      AGENT="{{ inputs.agent }}"

      # Build prompt file from task description
      PROMPT_FILE="/tmp/${TASK_ID}-prompt.md"
      cat > "$PROMPT_FILE" <<EOF
      ## Task: {{ inputs.task_id }}

      ### Description
      {{ inputs.task_description }}

      ### Requirements
      1. Read the codebase to understand the relevant code
      2. Implement the changes as described
      3. Write or update tests
      4. Ensure all tests pass
      5. Commit your changes with a descriptive message
      EOF

      bash skills/conduxt/scripts/launch.sh \
        "$TASK_ID" "$WORKTREE" "$PROMPT_FILE" "$BACKEND" "$AGENT"
    on_failure:
      - action: notify
        message: "Agent launch failed for task '{{ inputs.task_id }}'"
      - action: abort

  # -------------------------------------------------------------------------
  # Stage 3: Wait for Completion
  # -------------------------------------------------------------------------
  - name: wait-for-completion
    description: "Monitor agent until callback received (backend-aware)"
    depends_on: [launch-agent]
    action: wait
    condition: |
      TASK_ID="{{ stages.setup.outputs.task_id }}"
      CALLBACK_FILE=".clawdbot/${TASK_ID}-callback.json"
      test -f "$CALLBACK_FILE"
    timeout: 3600  # 1 hour max
    poll_interval: 30  # Check every 30 seconds
    on_timeout:
      - action: notify
        message: "Agent timed out on task '{{ inputs.task_id }}' (1 hour limit)"
      - action: shell
        command: |
          TASK_ID="{{ stages.setup.outputs.task_id }}"
          # Capture final state for debugging (try ACPX first, then tmux)
          acpx sessions show -s "$TASK_ID" \
            > ".clawdbot/${TASK_ID}-timeout-capture.txt" 2>/dev/null || \
          tmux -S /tmp/openclaw-tmux/openclaw.sock capture-pane -p \
            -t "$TASK_ID" -S -100 \
            > ".clawdbot/${TASK_ID}-timeout-capture.txt" 2>/dev/null || true

  # -------------------------------------------------------------------------
  # Stage 4: Verify Results
  # -------------------------------------------------------------------------
  - name: verify
    description: "Validate callback and run independent test verification"
    depends_on: [wait-for-completion]
    action: shell
    command: |
      TASK_ID="{{ stages.setup.outputs.task_id }}"
      CALLBACK_FILE=".clawdbot/${TASK_ID}-callback.json"
      WORKTREE="{{ stages.setup.outputs.worktree }}"

      # Read callback
      STATUS=$(jq -r '.status' "$CALLBACK_FILE")
      FAILED=$(jq -r '.test_results.failed // 0' "$CALLBACK_FILE")

      if [ "$STATUS" != "completed" ]; then
        echo "VERIFY_RESULT=not_completed"
        exit 1
      fi

      if [ "$FAILED" -gt 0 ]; then
        echo "VERIFY_RESULT=tests_failing"
        exit 1
      fi

      # Independent test verification (auto-detect runner)
      cd "$WORKTREE"
      if [ -f package.json ]; then
        npm test || { echo "VERIFY_RESULT=independent_tests_failed"; exit 1; }
      elif [ -f Makefile ] && grep -q '^test:' Makefile; then
        make test || { echo "VERIFY_RESULT=independent_tests_failed"; exit 1; }
      elif [ -f pytest.ini ] || [ -d tests ] || [ -f setup.py ]; then
        pytest || { echo "VERIFY_RESULT=independent_tests_failed"; exit 1; }
      elif [ -f go.mod ]; then
        go test ./... || { echo "VERIFY_RESULT=independent_tests_failed"; exit 1; }
      fi

      echo "VERIFY_RESULT=passed"
    outputs:
      verify_result: "passed"
    on_failure:
      - action: notify
        message: "Verification failed for task '{{ inputs.task_id }}'"

  # -------------------------------------------------------------------------
  # Stage 5: Approval Gate (Optional)
  # -------------------------------------------------------------------------
  - name: approval-gate
    description: "Optional human approval before PR creation"
    depends_on: [verify]
    skip_if: "{{ not inputs.require_approval }}"
    action: approval
    prompt: |
      Task '{{ inputs.task_id }}' has been completed by the coding agent.

      Callback summary:
      {{ read_file('.clawdbot/' + stages.setup.outputs.task_id + '-callback.json') }}

      Create PR?
    approvers: ["user"]
    timeout: 86400  # 24 hours
    on_denied:
      - action: notify
        message: "PR creation denied for task '{{ inputs.task_id }}'"
      - action: abort

  # -------------------------------------------------------------------------
  # Stage 6: Create PR
  # -------------------------------------------------------------------------
  - name: create-pr
    description: "Create pull request on GitHub"
    depends_on: [approval-gate]
    skip_if: "{{ not inputs.auto_pr }}"
    action: shell
    command: |
      TASK_ID="{{ stages.setup.outputs.task_id }}"
      BRANCH="{{ stages.setup.outputs.branch }}"
      CALLBACK_FILE=".clawdbot/${TASK_ID}-callback.json"

      SUMMARY=$(jq -r '.summary // "No summary"' "$CALLBACK_FILE")
      FILES=$(jq -r '.files_changed // [] | map("- `" + . + "`") | join("\n")' "$CALLBACK_FILE")
      PASSED=$(jq -r '.test_results.passed // 0' "$CALLBACK_FILE")
      FAILED=$(jq -r '.test_results.failed // 0' "$CALLBACK_FILE")
      SKIPPED=$(jq -r '.test_results.skipped // 0' "$CALLBACK_FILE")

      # Push branch
      cd "{{ stages.setup.outputs.worktree }}"
      git push -u origin "$BRANCH"

      # Create PR
      gh pr create \
        --title "${TASK_ID}: ${SUMMARY}" \
        --body "## Summary
      ${SUMMARY}

      ## Changes
      ${FILES}

      ## Test Results
      - Passed: ${PASSED}
      - Failed: ${FAILED}
      - Skipped: ${SKIPPED}

      ---
      *Automated by [conduxt](https://github.com/xuezhouyang/conduxt)*" \
        --base "{{ inputs.base_branch }}" \
        --head "$BRANCH"
    outputs:
      pr_url: "$(gh pr view --json url -q .url)"
    on_failure:
      - action: notify
        message: "PR creation failed for task '{{ inputs.task_id }}'"

  # -------------------------------------------------------------------------
  # Stage 7: Notify
  # -------------------------------------------------------------------------
  - name: notify-completion
    description: "Send completion notification to user"
    depends_on: [create-pr]
    action: notify
    channel: "{{ inputs.notify_channel }}"
    message: |
      Task '{{ inputs.task_id }}' completed!
      PR: {{ stages.create-pr.outputs.pr_url }}
      {{ jq('.summary', read_file('.clawdbot/' + stages.setup.outputs.task_id + '-callback.json')) }}

  # -------------------------------------------------------------------------
  # Stage 8: Cleanup
  # -------------------------------------------------------------------------
  - name: cleanup
    description: "Remove worktree and clean up temporary files"
    depends_on: [notify-completion]
    action: shell
    always_run: true  # Run even if previous stages failed
    command: |
      TASK_ID="{{ stages.setup.outputs.task_id }}"
      WORKTREE="{{ stages.setup.outputs.worktree }}"

      # End ACPX session if exists
      acpx cancel -s "$TASK_ID" 2>/dev/null || true

      # Kill tmux session if exists
      tmux -S /tmp/openclaw-tmux/openclaw.sock kill-session -t "$TASK_ID" 2>/dev/null || true

      # Kill watchdog if running
      WATCHDOG_PID_FILE=".clawdbot/${TASK_ID}-watchdog.pid"
      if [ -f "$WATCHDOG_PID_FILE" ]; then
        kill "$(cat "$WATCHDOG_PID_FILE")" 2>/dev/null || true
        rm -f "$WATCHDOG_PID_FILE"
      fi

      # Remove worktree
      git worktree remove "$WORKTREE" --force 2>/dev/null || true

      # Clean up temp files
      rm -f "/tmp/${TASK_ID}-prompt.md"
      rm -f ".clawdbot/${TASK_ID}-prompt.md"

      # Keep callback JSON and logs for history
      echo "Cleanup complete for ${TASK_ID}"
