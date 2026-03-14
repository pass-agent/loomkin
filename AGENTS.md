# Loomkin - AI Instructions

Read and follow [CONTRIBUTING.md](CONTRIBUTING.md) for all conventions, including commit message format, build commands, and code style.

Key reminders:
- Commit subjects must be **fully lowercase** (no acronyms like UI or API — use `ui`, `api`)
- Run `mix format` before committing
- Run `mix precommit` to validate everything before pushing
- **Never run slow commands** (e.g. `mix test`, `mix precommit`, `mix compile`) without piping output to a `/tmp` log file (e.g. `mix test 2>&1 | tee /tmp/mix_test.log`). This avoids rerunning the entire command just to grep for a specific string — search the log file instead.
