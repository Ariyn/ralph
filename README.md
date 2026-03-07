# Ralph

![Ralph](ralph.webp)

Ralph is an autonomous AI agent loop that runs AI coding tools ([Claude Code](https://docs.anthropic.com/en/docs/claude-code) or [Codex CLI](https://developers.openai.com/codex/cli)) repeatedly until all PRD items are complete. Each iteration is a fresh instance with clean context. Memory persists via git history, `progress.txt`, `prd.json`, and story plan files.

Based on [Geoffrey Huntley's Ralph pattern](https://ghuntley.com/ralph/).

[Read my in-depth article on how I use Ralph](https://x.com/ryancarson/status/2008548371712135632)

## Prerequisites

- One of the following AI coding tools installed and authenticated:
  - [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (default) (`npm install -g @anthropic-ai/claude-code`)
  - [Codex CLI](https://developers.openai.com/codex/cli) (`npm install -g @openai/codex`)
- `jq` installed (`brew install jq` on macOS)
- A git repository for your project

## Setup

### Option 1: Quick install (`curl | bash`)

From your project root:

```bash
curl -fsSL https://raw.githubusercontent.com/Ariyn/ralph/main/scripts/install.sh | bash
```

This bootstraps:
- `scripts/ralph/ralph.sh`
- `scripts/ralph/PLAN.md`
- `scripts/ralph/CLAUDE.md`
- `scripts/ralph/CODEX.md`
- `scripts/ralph/skills/prd/SKILL.md`
- `scripts/ralph/skills/ralph/SKILL.md`
- `.agents/skills/prd/SKILL.md` (Codex skill discovery path)
- `.agents/skills/ralph/SKILL.md` (Codex skill discovery path)
- `scripts/ralph/.ralph-install-checksums` (체크섬 기준 파일)
- `scripts/ralph/prd.json`
- `scripts/ralph/prd.json.example`
- `scripts/ralph/progress.txt`
- `scripts/ralph/plans/plan-00.md`

The generated `prd.json` starts with a single completed bootstrap story so the file is immediately valid. Replace it with your real feature PRD before your first real Ralph run.

To install into a different folder:

```bash
curl -fsSL https://raw.githubusercontent.com/Ariyn/ralph/main/scripts/install.sh | bash -s -- --dir tooling/ralph
```

To install Codex skills into a custom location (default is `.agents/skills`):

```bash
curl -fsSL https://raw.githubusercontent.com/Ariyn/ralph/main/scripts/install.sh | bash -s -- --codex-skills-dir .agents/skills
```

Re-running the same installer command performs checksum-based updates automatically.

Checksum update behavior (default):
- Checksums are tracked in `scripts/ralph/.ralph-install-checksums`
- If a managed file differs from its recorded checksum, installer keeps that file unchanged
- If a managed file matches its recorded checksum, installer refreshes it to the latest version
- If no checksum baseline exists yet, installer keeps the file and seeds checksum for the next run

### Option 2: Copy to your project

Copy the ralph files into your project:

```bash
# From your project root
mkdir -p scripts/ralph
cp /path/to/ralph/ralph.sh scripts/ralph/

# Copy the shared planning prompt and the prompt template for your AI tool of choice:
cp /path/to/ralph/PLAN.md scripts/ralph/PLAN.md        # Shared plan-generation prompt
cp /path/to/ralph/CLAUDE.md scripts/ralph/CLAUDE.md    # For Claude Code
# OR
cp /path/to/ralph/CODEX.md scripts/ralph/CODEX.md      # For Codex

# Shared skills (available to both tools as local project files)
mkdir -p scripts/ralph/skills
cp -r /path/to/ralph/skills/prd scripts/ralph/skills/
cp -r /path/to/ralph/skills/ralph scripts/ralph/skills/

# Codex skill discovery path (Codex scans .agents/skills)
mkdir -p .agents/skills
cp -r /path/to/ralph/skills/prd .agents/skills/
cp -r /path/to/ralph/skills/ralph .agents/skills/

chmod +x scripts/ralph/ralph.sh
```

### Option 3: Install skills globally (optional, Claude Code)

`curl | bash` installs shared skills into `scripts/ralph/skills`, which keeps them in a project-local location that both Codex and Claude can read.

If you also want Claude global skills for all projects, copy from the installed folder:

For Claude Code (manual):
```bash
cp -r scripts/ralph/skills/prd ~/.claude/skills/
cp -r scripts/ralph/skills/ralph ~/.claude/skills/
```

Codex does not use the Claude skill folders; it discovers skills from `.agents/skills` (or `~/.agents/skills`).

### Option 4: Use as Claude Code Marketplace

Add the Ralph marketplace to Claude Code:

```bash
/plugin marketplace add snarktank/ralph
```

Then install the skills:

```bash
/plugin install ralph-skills@ralph-marketplace
```

Available skills after installation:
- `/prd` - Generate Product Requirements Documents
- `/ralph` - Convert PRDs to prd.json format

Skills are automatically invoked when you ask Claude to:
- "create a prd", "write prd for", "plan this feature"
- "convert this prd", "turn into ralph format", "create prd.json"

## Workflow

### 1. Create a PRD

Use the PRD skill to generate a detailed requirements document:

```
Load the prd skill and create a PRD for [your feature description]
```

Answer the clarifying questions. The skill saves output to `tasks/prd-[feature-name].md`.

### 2. Convert PRD to Ralph format

Use the Ralph skill to convert the markdown PRD to JSON:

```
Load the ralph skill and convert tasks/prd-[feature-name].md to prd.json
```

This creates `prd.json` with user stories structured for autonomous execution.

### 3. Run Ralph

```bash
# Using Claude Code (default)
./scripts/ralph/ralph.sh [max_iterations]

# Using Claude Code with explicit model overrides
./scripts/ralph/ralph.sh --plan-model claude-opus-4-6 --exec-model claude-sonnet-4-6 [max_iterations]

# Using Codex
./scripts/ralph/ralph.sh --tool codex [max_iterations]

# Using Codex with explicit model and reasoning overrides
./scripts/ralph/ralph.sh --tool codex --plan-model gpt-5.4 --plan-reasoning xhigh --exec-model gpt-5.4 --exec-reasoning medium [max_iterations]

# Using Claude Code explicitly
./scripts/ralph/ralph.sh --tool claude [max_iterations]
```

Default is 10 iterations. Use `--tool claude` or `--tool codex` to select your AI coding tool.

### Planning-first execution

Before every implementation run, Ralph checks the next pending story:

1. If the story's `plan` field is empty, Ralph assigns a default plan path in `plans/`.
2. If the plan file is missing or empty, Ralph runs a **planning-only** pass and exits immediately.
3. If the plan file exists, Ralph appends that plan to the implementation prompt and runs the story.

Default planning/execution models:

- Claude Code: planning with `claude-opus-4-6`, implementation with `claude-sonnet-4-6`
- Codex: planning with `gpt-5.4` + `xhigh` reasoning, implementation with `gpt-5.4` + `medium` reasoning

Ralph will:
1. Create a feature branch (from PRD `branchName`)
2. Pick the highest priority story where `passes: false`
3. Generate the story plan first if the plan file is missing, then exit
4. Read the existing plan file and implement that single story
5. Run quality checks (typecheck, tests)
6. Commit if checks pass
7. Update `prd.json` to mark story as `passes: true`
8. Append learnings to `progress.txt`
9. Repeat until all stories pass or max iterations reached

## Key Files

| File | Purpose |
|------|---------|
| `scripts/install.sh` | Bootstrap script for `curl | bash` setup in another project |
| `ralph.sh` | The bash loop that spawns fresh AI instances (supports `--tool claude` or `--tool codex`) |
| `PLAN.md` | Shared prompt template for plan-generation runs |
| `CLAUDE.md` | Prompt template for Claude Code |
| `CODEX.md` | Prompt template for Codex |
| `prd.json` | User stories with `passes` status (the task list) |
| `prd.json.example` | Example PRD format for reference |
| `plans/` | Story plan documents referenced by each PRD item's `plan` field |
| `progress.txt` | Append-only learnings for future iterations |
| `skills/prd/` | Skill for generating PRDs for Claude Code workflows |
| `skills/ralph/` | Skill for converting PRDs to JSON for Claude Code workflows |
| `.claude-plugin/` | Plugin manifest for Claude Code marketplace discovery |
| `flowchart/` | Interactive visualization of how Ralph works |

## Flowchart

[![Ralph Flowchart](ralph-flowchart.png)](https://snarktank.github.io/ralph/)

**[View Interactive Flowchart](https://snarktank.github.io/ralph/)** - Click through to see each step with animations.

The `flowchart/` directory contains the source code. To run locally:

```bash
cd flowchart
npm install
npm run dev
```

## Critical Concepts

### Each Iteration = Fresh Context

Each iteration spawns a **new AI instance** (Claude Code or Codex) with clean context. The only memory between iterations is:
- Git history (commits from previous iterations)
- `progress.txt` (learnings and context)
- `prd.json` (which stories are done)
- `plans/*.md` (the implementation plans for future stories)

### Small Tasks

Each PRD item should be small enough to complete in one context window. If a task is too big, the LLM runs out of context before finishing and produces poor code.

Right-sized stories:
- Add a database column and migration
- Add a UI component to an existing page
- Update a server action with new logic
- Add a filter dropdown to a list

Too big (split these):
- "Build the entire dashboard"
- "Add authentication"
- "Refactor the API"

### AGENTS.md Updates Are Critical

After each iteration, Ralph updates the relevant `AGENTS.md` files with learnings. This is key because AI coding tools automatically read these files, so future iterations (and future human developers) benefit from discovered patterns, gotchas, and conventions.

Examples of what to add to AGENTS.md:
- Patterns discovered ("this codebase uses X for Y")
- Gotchas ("do not forget to update Z when changing W")
- Useful context ("the settings panel is in component X")

### Feedback Loops

Ralph only works if there are feedback loops:
- Typecheck catches type errors
- Tests verify behavior
- CI must stay green (broken code compounds across iterations)

### Browser Verification for UI Stories

Frontend stories must include "Verify in browser using dev-browser skill" in acceptance criteria. Ralph will use the dev-browser skill to navigate to the page, interact with the UI, and confirm changes work.

### Stop Condition

Ralph treats `prd.json` as the source of truth and exits when no stories remain with `passes: false`.

The agent may still emit `<promise>COMPLETE</promise>` when everything is done, but Ralph no longer trusts that marker by itself because some CLIs can echo or quote it while there is still pending work.

## Debugging

Check current state:

```bash
# See which stories are done
cat prd.json | jq '.userStories[] | {id, title, passes}'

# See learnings from previous iterations
cat progress.txt

# Check git history
git log --oneline -10
```

## Customizing the Prompt

After copying `PLAN.md`, `CLAUDE.md`, or `CODEX.md` to your project, customize them for your project:
- Add project-specific quality check commands
- Include codebase conventions
- Add common gotchas for your stack

## Archiving

Ralph automatically archives previous runs when you start a new feature (different `branchName`). Archives are saved to `archive/YYYY-MM-DD-feature-name/`.

## References

- [Geoffrey Huntley's Ralph article](https://ghuntley.com/ralph/)
- [Claude Code documentation](https://docs.anthropic.com/en/docs/claude-code)
- [Codex CLI documentation](https://developers.openai.com/codex/cli)
