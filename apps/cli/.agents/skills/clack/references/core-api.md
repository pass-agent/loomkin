# @clack/core Reference

## Install

```bash
npm i @clack/core
pnpm add @clack/core
yarn add @clack/core
bun add @clack/core
```

## When To Use

Use `@clack/core` when `@clack/prompts` is too high-level and you need:

- Custom prompt rendering
- Lifecycle/state control
- Framework-level abstractions on top of Clack

## Main Building Blocks

- `InputPrompt`
- `ConfirmPrompt`
- `SelectPrompt`
- `MultiSelectPrompt`
- `tasks(...)` task runner helper
- Shared color and formatting helpers from `@clack/core`

## Custom Prompt Shape

Core prompts are class-based and support:

- Constructor config (messages, options, defaults)
- Custom `render()` logic
- Fine-grained behavior for validation and state transitions

Use this package to build opinionated internal prompt abstractions, then expose simpler helpers to end users.

## Tasks Helper

Use `tasks([...])` for async operations with progress messaging:

- Provide `title`
- Provide async `task(message, signal)` function
- Update status via `message("...")`
- Honor `signal` for cancellation-aware work where possible

## Recommendation

- Start with `@clack/prompts`.
- Move to `@clack/core` only for customization needs that cannot be solved with prompt composition alone.
