defmodule Loomkin.Permissions.HookRunner do
  @moduledoc """
  Runs registered hooks before and after tool execution.

  Hook execution is skipped entirely for `:read` and `:coordination` category
  tools. For `:write` and `:execute` tools, hooks run in the order they are
  configured.

  ## Pre-tool hooks

  Pre-tool hooks run sequentially. The first hook to return `:deny` or
  `{:ask, reason}` short-circuits — remaining hooks are not called.

  ## Post-tool hooks

  Post-tool hooks also run sequentially. A `{:rollback, reason}` return
  short-circuits immediately. `{:warn, message}` results are collected but
  do not halt execution — if no rollback occurs, the runner returns `:ok`.
  """

  require Logger

  alias Loomkin.Permissions.Manager

  @skipped_categories [:read, :coordination]

  @doc """
  Run all pre-tool hooks. Returns `:allow` if all pass, or the first
  denial/ask result.

  Skips entirely for `:read` and `:coordination` category tools.
  """
  @spec run_pre_hooks([module()], String.t(), map()) ::
          :allow | :deny | {:ask, String.t()}
  def run_pre_hooks(hooks, tool_name, tool_args) do
    if skip_hooks?(tool_name) do
      :allow
    else
      do_run_pre_hooks(hooks, tool_name, tool_args)
    end
  end

  @doc """
  Run all post-tool hooks. Returns `:ok` if all pass, or the first
  `{:rollback, reason}` result.

  Skips entirely for `:read` and `:coordination` category tools.
  """
  @spec run_post_hooks([module()], String.t(), map(), term()) ::
          :ok | {:rollback, String.t()}
  def run_post_hooks(hooks, tool_name, tool_args, result) do
    if skip_hooks?(tool_name) do
      :ok
    else
      do_run_post_hooks(hooks, tool_name, tool_args, result)
    end
  end

  @doc """
  Load hooks from application config for the given phase.

  Reads from `Application.get_env(:loomkin, :permission_hooks)` which is
  expected to be a map of `%{pre_tool: [module], post_tool: [module]}`.

  Returns an empty list if no hooks are configured.
  """
  @spec load_hooks(atom()) :: [module()]
  def load_hooks(phase) when phase in [:pre_tool, :post_tool] do
    case Application.get_env(:loomkin, :permission_hooks) do
      %{} = hooks_config -> Map.get(hooks_config, phase, [])
      _ -> []
    end
  end

  # -- Private ----------------------------------------------------------------

  defp skip_hooks?(tool_name) do
    Manager.tool_category(tool_name) in @skipped_categories
  end

  defp do_run_pre_hooks([], _tool_name, _tool_args), do: :allow

  defp do_run_pre_hooks([hook | rest], tool_name, tool_args) do
    if has_callback?(hook, :pre_tool, 2) do
      try do
        case hook.pre_tool(tool_name, tool_args) do
          :allow -> do_run_pre_hooks(rest, tool_name, tool_args)
          :deny -> :deny
          {:ask, _reason} = ask -> ask
        end
      rescue
        e ->
          Logger.warning(
            "[Kin:hook] pre_tool hook #{inspect(hook)} crashed: #{Exception.message(e)}"
          )

          do_run_pre_hooks(rest, tool_name, tool_args)
      end
    else
      do_run_pre_hooks(rest, tool_name, tool_args)
    end
  end

  defp do_run_post_hooks([], _tool_name, _tool_args, _result), do: :ok

  defp do_run_post_hooks([hook | rest], tool_name, tool_args, result) do
    if has_callback?(hook, :post_tool, 3) do
      try do
        case hook.post_tool(tool_name, tool_args, result) do
          :ok -> do_run_post_hooks(rest, tool_name, tool_args, result)
          {:warn, _message} -> do_run_post_hooks(rest, tool_name, tool_args, result)
          {:rollback, _reason} = rollback -> rollback
        end
      rescue
        e ->
          Logger.warning(
            "[Kin:hook] post_tool hook #{inspect(hook)} crashed: #{Exception.message(e)}"
          )

          do_run_post_hooks(rest, tool_name, tool_args, result)
      end
    else
      do_run_post_hooks(rest, tool_name, tool_args, result)
    end
  end

  defp has_callback?(module, function, arity) do
    Code.ensure_loaded(module)
    function_exported?(module, function, arity)
  end
end
