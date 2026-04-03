# Clack Example Patterns

Use these patterns as templates when generating code.

## 1. Basic CLI Flow

- Start with `intro(...)`
- Ask 1-3 core prompts
- Handle cancellation after each prompt
- End with `outro(...)`

## 2. Spinner for One Long Task

- Create `const s = spinner()`
- `s.start("...")`
- Update with `s.message("...")` as needed
- `s.stop("...")` on completion

## 3. Task Runner for Multiple Async Steps

- Use `tasks([...])`
- Give each task a short, meaningful title
- Use task message updates for visibility

## 4. Grouped Data Collection

- Collect related fields with `group(...)`
- Validate each field independently
- Run side effects only after successful group completion

## 5. Conditional Prompt Chains

- Ask a branch selector first (e.g., mode/environment)
- Ask follow-up prompts only for the chosen branch
- Keep each branch shallow and explicit

## 6. Progress-Heavy Workflows

- Prefer structured status updates over verbose logs
- Combine spinner/tasks with concise success/failure summaries

## 7. Safe Exit Behavior

- On cancellation, call `cancel("...")` and terminate cleanly
- Do not continue writes/network calls after a canceled prompt

## 8. Streamed Output

- Use `stream()` when incremental rendering improves UX
- Finalize with a clear completion state and next step note
