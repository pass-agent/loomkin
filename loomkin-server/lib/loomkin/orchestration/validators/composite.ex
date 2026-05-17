defmodule Loomkin.Orchestration.Validators.Composite do
  @moduledoc """
  Runs a list of validators against a payload in parallel, collating
  diagnostics.

  Return semantics:

    * `:ok` — every child returned `:ok` (no warnings, no errors).
    * `{:ok, warnings}` — every child returned `:ok` or `{:ok, [...]}` and at
      least one warning was collected. Warnings are prefixed with the
      emitting validator's `name()` so downstream consumers can attribute
      them.
    * `{:error, errors}` — at least one child failed. The returned list is
      the flattened union of every failing child's diagnostics, prefixed
      with the validator name. Warnings from passing children are NOT
      merged into the error list (the pipeline is going to retry; the
      warnings have no audience on the failure path).

  Example:

      Composite.validate(%{worktree_path: "/tmp/foo"},
        validators: [
          Loomkin.Orchestration.Validators.ElixirFormat,
          Loomkin.Orchestration.Validators.ElixirCompile,
          Loomkin.Orchestration.Validators.ElixirTest
        ])
  """
  @behaviour Loomkin.Orchestration.Validators.Validator

  @default_validators [
    Loomkin.Orchestration.Validators.ElixirFormat,
    Loomkin.Orchestration.Validators.ElixirCompile,
    Loomkin.Orchestration.Validators.ElixirTest
  ]

  @impl true
  def name, do: :composite

  @impl true
  def validate(payload, opts \\ []) do
    validators = Keyword.get(opts, :validators, @default_validators)
    timeout = Keyword.get(opts, :per_validator_timeout, :timer.minutes(10))

    results =
      validators
      |> Task.async_stream(fn mod -> {mod, mod.validate(payload, opts)} end,
        max_concurrency: length(validators),
        timeout: timeout,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.map(fn
        {:ok, {_mod, :ok}} ->
          :ok

        {:ok, {mod, {:ok, warnings}}} when is_list(warnings) ->
          {:warning, prefix(warnings, mod)}

        {:ok, {mod, {:error, diags}}} ->
          {:error, prefix(diags, mod)}

        {:exit, reason} ->
          {:error, ["validator:composite:0: subtask exited #{inspect(reason)}"]}
      end)

    errors =
      Enum.flat_map(results, fn
        {:error, errs} -> errs
        _ -> []
      end)

    warnings =
      Enum.flat_map(results, fn
        {:warning, warns} -> warns
        _ -> []
      end)

    cond do
      errors != [] -> {:error, errors}
      warnings != [] -> {:ok, warnings}
      true -> :ok
    end
  end

  defp prefix(diags, mod) do
    Enum.map(diags, &("[#{mod.name()}] " <> &1))
  end
end
