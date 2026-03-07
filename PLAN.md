# Ralph Planning Instructions

You are generating the implementation plan for the next Ralph story.

## Your Task

1. Read the PRD at `prd.json` (in the same directory as this file)
2. Read the progress log at `progress.txt` (check Codebase Patterns section first)
3. Check you're on the correct branch from PRD `branchName`. If not, check it out or create from main.
4. Use the selected story from the Ralph Runtime Context if it is provided. Otherwise, pick the **highest priority** user story where `passes: false`.
5. Create or update the markdown plan file referenced by that story's `plan` field.
6. Stop after the plan file is written.

## Plan Requirements

Write a concrete execution plan that a later Ralph implementation run can follow with minimal ambiguity.

Each plan should include:

1. **Story summary**
2. **Acceptance criteria breakdown**
3. **Code areas to inspect**
4. **Implementation steps**
5. **Validation steps**
6. **Risks or open questions**

Prefer short, actionable bullets over long prose.

## Constraints

- Do NOT implement the feature itself
- Do NOT modify `passes`
- Do NOT commit changes
- Do NOT append to `progress.txt`
- Only edit the plan file, plus `prd.json` if the `plan` field absolutely must be corrected
- If the plan directory does not exist, create it

## Important

- Work on ONE story only
- The Ralph Runtime Context, when present, is authoritative
- The goal is to leave behind a high-quality plan for the implementation model
