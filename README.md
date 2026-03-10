# conduxt

> Unattended coding agent orchestrator — drive Claude Code / Gemini / Codex via ACPX or tmux, end-to-end.

![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)
![works with Claude Code](https://img.shields.io/badge/works%20with-Claude%20Code-orange)
![ACPX ready](https://img.shields.io/badge/ACPX-ready-green)

## About

conduxt is an [OpenClaw](https://github.com/openclaw/openclaw) Skill that turns natural language task descriptions into completed pull requests. It orchestrates unattended coding agent sessions — handling branch creation, agent launch, full-duplex progress monitoring, test verification, and PR creation. It supports Claude Code, Gemini CLI, Codex, and Aider as coding agents, communicating via ACPX (full-duplex JSON-RPC, preferred) or tmux (terminal scraping, fallback). The core logic is a Playbook (`SKILL.md`) that teaches the OpenClaw Main model to use its own tools, not a wrapper around bash scripts.

## Why conduxt?

- **One-liner task input** — Say "implement pagination for /api/users" and walk away. Works with any task source: requirements, bug reports, investigations, refactoring.
- **ACPX full-duplex communication** — Protocol-level prompt queue, structured ndjson output, cooperative cancel, auto crash recovery. No timing hacks.
- **tmux fallback** — Mature, visual split-pane monitoring, broad agent compatibility. Auto-selected when ACPX is unavailable.
- **Structured callback contract** — Agent outputs `callback-json` block on completion. Routing is pure if/else, no LLM interpretation needed.
- **Zero-token background watchdog** — Shell-based monitoring that consumes no LLM tokens. Detects crashes, stalls, and milestones.
- **OpenClaw Skill composability** — Builds on community Skills (`coding-agent`, `tmux`, `gemini`, `resilient-coding-agent`) instead of reinventing them.
- **Parallel multi-agent** — Run multiple named sessions concurrently.

## Architecture — Dual-Backend (ACPX + tmux)

```
                    ┌─ ACPX (preferred) ── JSON-RPC over stdio ── Agent
User ←→ Main Model ─┤
                    └─ tmux (fallback) ── PTY scraping ─────────── Agent
         ↕
      MEMORY.md (cross-session shared state)
```

### Backend Comparison

| | ACPX (Preferred) | tmux (Fallback) |
|-|-------------------|-----------------|
| **Communication** | Full-duplex JSON-RPC | Half-duplex PTY scraping |
| **Mid-task instructions** | Prompt queue (no timing issues) | send-keys (timing conflicts possible) |
| **Completion detection** | Native `[done]` signal | Regex / Callback injection |
| **Crash recovery** | Auto-restart + session restore | Session survives, agent death unnoticed |
| **Cancellation** | Cooperative cancel, preserves state | C-c, may corrupt state |
| **Permissions** | `--approve-all` policy-based | Interactive TTY popups |
| **Visual monitoring** | Needs external tool | Split-pane built-in |

ACPX is strictly superior for communication and observation. tmux wins on maturity and visual monitoring.

## Quick Start — Install & Run Your First Agent Task

### Prerequisites

```bash
# Required
git --version && gh --version

# ACPX backend (recommended)
npm install -g @anthropics/acpx

# tmux backend (fallback)
brew install tmux    # macOS
apt install tmux     # Linux

# At least one coding agent
claude --version     # Claude Code
# or: gemini, codex, aider
```

### As an OpenClaw Skill

Once installed as a Skill, just talk to OpenClaw:

```
"Implement pagination for /api/users"
"Investigate the slow query in OrderService"
"Start a coding session for API refactoring"
"Run three tasks in parallel"
```

The Main model reads `SKILL.md` and orchestrates everything automatically.

### With Helper Scripts

```bash
# 1. Set up workspace (worktree + branch + state tracking)
bash scripts/setup.sh add-pagination feat/add-pagination ../worktrees/add-pagination \
  "Implement pagination for /api/users with page and pageSize params"

# 2. Launch coding agent (auto-selects ACPX or tmux)
bash scripts/launch.sh add-pagination ../worktrees/add-pagination \
  .clawdbot/add-pagination-desc.md

# 3. Background monitoring (optional, zero-token)
bash scripts/watchdog.sh add-pagination
```

## How It Works — Callback Contract & Routing

### Structured Callback

The coding agent outputs a completion signal when done:

````
```callback-json
{
  "task_id": "add-pagination",
  "status": "completed",
  "branch": "feat/add-pagination",
  "files_changed": ["src/api/users.go", "src/api/users_test.go"],
  "test_results": { "passed": 42, "failed": 0, "skipped": 1 },
  "duration_minutes": 15,
  "summary": "Implemented cursor-based pagination with 2 new tests"
}
```
````

### Routing (Pure if/else)

| Status | Action |
|--------|--------|
| `completed` + 0 failures | Verify tests → Create PR → Notify |
| `completed` + N failures | Tell agent to keep fixing |
| `failed` | Notify user |
| `need_clarification` | Forward question to user |

### State Persistence

`MEMORY.md` tracks all in-flight tasks across sessions. It survives gateway restarts and context compaction — the only reliable cross-session shared state.

## Composable Skills

conduxt doesn't reinvent the wheel. It composes existing OpenClaw community Skills:

| Skill | Role |
|-------|------|
| [`coding-agent`](https://clawhub.com) | Agent lifecycle management (tmux backend) |
| [`tmux`](https://clawhub.com) | Low-level tmux operations |
| [`tmux-agents`](https://clawhub.com) | Multi-agent types (Codex, Gemini, local) |
| [`gemini`](https://clawhub.com) | Gemini CLI for long-context coding |
| [`resilient-coding-agent`](https://clawhub.com) | Gateway restart recovery |

When using the ACPX backend, these tmux-based Skills are bypassed in favor of direct `acpx` commands.

## File Structure

```
├── SKILL.md           # OpenClaw Playbook (Main model reads this)
├── CLAUDE.md          # Development guide
├── README.md          # This file
├── scripts/
│   ├── setup.sh       # Worktree + state initialization
│   ├── launch.sh      # Agent launch (ACPX-first, tmux fallback)
│   └── watchdog.sh    # Zero-token background monitoring
└── workflows/
    └── task-to-pr.lobster   # Lobster workflow (planned)
```

## Roadmap

| Version | Goal | Status |
|---------|------|--------|
| v1.0 | Dual-backend composable Playbook (ACPX + tmux) | **Current** |
| v1.1 | Full task automation + parallel multi-agent | Planned |
| v1.2 | Lobster deterministic workflow + approval gates | Planned |

## Contributing

PRs welcome. The core logic lives in `SKILL.md` — it's the Playbook that teaches the OpenClaw Main model how to orchestrate. Helper scripts in `scripts/` are optional utilities.

## License

MIT

<!-- topics: coding-agent, llm-automation, claude-code, acpx, tmux, ai-workflow, unattended-coding, openclaw, coding-agent-orchestrator, worktree-automation -->
