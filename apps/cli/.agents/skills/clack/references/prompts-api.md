# @clack/prompts Reference

## Install

```bash
npm i @clack/prompts
pnpm add @clack/prompts
yarn add @clack/prompts
bun add @clack/prompts
```

## Prompt Types

Use these high-level prompts for most CLI flows:

- `text(...)`
- `password(...)`
- `confirm(...)`
- `select(...)`
- `multiselect(...)`
- `number(...)`
- `group(...)` for grouped prompt collection

## Support Functions

Use these helpers to shape the CLI experience:

- `intro(message)`
- `outro(message)`
- `cancel(message)`
- `isCancel(value)`
- `spinner()` with `start(message)`, `message(message)`, `stop(message)`
- `log.info|success|warn|error|message(...)`
- `note(content, title?)`
- `stream()` for incremental output rendering
- `clear()`
- `setTheme(theme)`

## Baseline Pattern (Cancellation + Validation)

```js
import {
  intro,
  outro,
  text,
  isCancel,
  cancel,
  log,
} from "@clack/prompts";

intro("Create release notes");

const version = await text({
  message: "Version",
  placeholder: "1.2.0",
  validate(value) {
    return /^\d+\.\d+\.\d+$/.test(String(value))
      ? undefined
      : "Use semver (e.g. 1.2.0)";
  },
});

if (isCancel(version)) {
  cancel("Operation canceled.");
  process.exit(0);
}

log.success(`Preparing notes for v${version}`);
outro("Done.");
```

## Grouped Flow Pattern

Use `group(...)` to keep multi-step forms explicit and typed:

- Keep each field independent.
- Validate at field-level.
- Add branch prompts after the grouped result.

## Practical Limits

- Cancellation is typically user-driven via keyboard interrupt.
- For long option lists in select-like prompts, constrain visible options and support filtering where needed.
- Keep prompts focused; deep nested prompt trees degrade usability.
