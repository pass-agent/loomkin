# Greeter — Loomkin orchestration live-e2e fixture

This is a deliberately broken minimal Elixir project used by the live end-to-end
orchestration smoke run (`mix run priv/orchestration/run_live_e2e.exs`). The
runner copies this tree into a temp dir, `git init`s it, and hands it to an
Epic whose Coder must locate and fix the bug.

The one-line bug: `lib/greeter.ex` defines `greet/1` as
`def greet(_name), do: "hello, anonymous"` — the argument is ignored, so the
test in `test/greeter_test.exs` asserting `Greeter.greet("vincent") ==
"hello, vincent"` fails. A successful orchestration run produces an Epic whose
final commit makes `mix test` green inside this fixture.
