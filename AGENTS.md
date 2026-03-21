# Ralph Agent Instructions

## Overview

Ralph is an autonomous AI agent loop that runs AI coding tools (Claude Code or Codex) repeatedly until all PRD items are complete. Each iteration is a fresh instance with clean context.

## Commands

```bash
# Run the flowchart dev server
cd flowchart && npm run dev

# Build the flowchart
cd flowchart && npm run build

# Run Ralph with Claude Code (default)
./ralph.sh [max_iterations]

# Run Ralph with Claude Code
./ralph.sh --tool claude [max_iterations]

# Run Ralph with Codex
./ralph.sh --tool codex [max_iterations]
```

## Key Files

- `ralph.sh` - The bash loop that spawns fresh AI instances (supports `--tool claude` or `--tool codex`)
- `PLAN.md` - Shared instructions for planning-only runs
- `CLAUDE.md` - Instructions given to each Claude Code instance
- `CODEX.md` - Instructions given to each Codex instance
- `prd.json.example` - Example PRD format
- `flowchart/` - Interactive React Flow diagram explaining how Ralph works

## Flowchart

The `flowchart/` directory contains an interactive visualization built with React Flow. It's designed for presentations - click through to reveal each step with animations.

To run locally:
```bash
cd flowchart
npm install
npm run dev
```

## Patterns

- Each iteration spawns a fresh AI instance (Claude Code or Codex) with clean context
- Memory persists via git history, `progress.txt`, and `prd.json`
- Future stories should have plan files in `plans/`; missing plans are generated in a separate planning run before implementation
- Ralph control files (`prd.json`, `progress.txt`, `plans/*.md`) are resolved relative to the Ralph directory, and runtime prompts should include explicit paths because the generated prompt file itself lives in a temporary location
- Codex skills should be installed in `.agents/skills` (repo-local) or `~/.agents/skills` (user-level); placing skills only under `scripts/ralph/skills` is not enough for Codex auto-discovery
- `scripts/install.sh` uses checksum manifest (`scripts/ralph/.ralph-install-checksums`) and keeps locally modified managed files unchanged
- Stories should be small enough to complete in one context window
- Treat `prd.json` as the completion source of truth; agent output markers can be echoed or quoted and should not alone end the loop
- Always update AGENTS.md with discovered patterns for future iterations

## Validation Architecture

Ralph enforces a validation cascade after each agent execution:

1. **Common guards** (harness-enforced, language-independent):
   - Scope: `allowPaths` / `denyPaths` checked against `git diff`
   - Budget: `maxChangedFiles` / `maxAddedLines` (warning by default, enforced with `budgetEnforced: true`)
2. **Project verification** (priority order):
   - Story or default `verification` commands from PRD
   - `.ralph/validate.sh` in the repo root (fallback)
   - If neither exists → `weakValidation` status
3. **Result files**: Written to `.ralph/runs/<run-id>/result.json` per iteration

Repositories can provide `.ralph/validate.sh` as their default validation entrypoint (e.g., `go test ./...`, `pytest`, `pnpm lint && pnpm test`). Ralph executes it and judges by exit code.
