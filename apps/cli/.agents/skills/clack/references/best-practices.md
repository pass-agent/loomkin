# Clack Best Practices

## Reliability

- Always handle cancellation with `isCancel(...)` and `cancel(...)`.
- Exit cleanly after cancellation; do not continue side effects.
- Validate all critical inputs early and return clear correction messages.

## UX Consistency

- Use `intro(...)` and `outro(...)` for clear session boundaries.
- Keep message tone and wording consistent across prompt, log, and errors.
- Prefer short labels and direct verbs in prompt messages.

## Prompt Design

- Apply progressive disclosure: ask only what is needed now.
- Use sensible defaults to minimize typing and prevent invalid states.
- Keep select/multiselect options concise and distinct.
- Break complex flows into grouped or staged prompts.

## Performance

- Batch independent async work when safe.
- Use lazy loading for heavy data needed by later steps.
- Show user-visible progress for operations that take noticeable time.

## Accessibility and Error Clarity

- Use clear labels and unambiguous choice text.
- Surface validation and runtime errors in actionable language.
- Keep terminal feedback readable and avoid noisy output.

## Advanced Patterns

- Use conditional prompts for branch-specific inputs.
- Reuse prompt builder functions for repeated flows.
- Centralize shared validators and message formatters.
