defmodule Loomkin.Permissions.Hook do
  @moduledoc """
  Behaviour for pre/post-tool validation hooks.

  Hooks run before and after tool execution to validate, gate, or respond to
  tool invocations. Only applies to `:write` and `:execute` category tools —
  `:read` and `:coordination` tools are always skipped.

  ## Implementing a hook

  Define a module that adopts this behaviour:

      defmodule MyApp.Permissions.Hooks.MyHook do
        @behaviour Loomkin.Permissions.Hook

        @impl true
        def name, do: "my_hook"

        @impl true
        def description, do: "Does something useful"

        @impl true
        def pre_tool(_tool_name, _tool_args), do: :allow

        @impl true
        def post_tool(_tool_name, _tool_args, _result), do: :ok
      end

  Both `pre_tool/2` and `post_tool/3` are optional callbacks. If a hook only
  needs to run in one phase, it can omit the other.

  ## Activation

  Hooks are opt-in. Configure them in application env:

      config :loomkin, :permission_hooks, %{
        pre_tool: [MyApp.Permissions.Hooks.MyHook],
        post_tool: [MyApp.Permissions.Hooks.MyHook]
      }
  """

  @type pre_result :: :allow | :deny | {:ask, reason :: String.t()}
  @type post_result :: :ok | {:warn, message :: String.t()} | {:rollback, reason :: String.t()}

  @callback name() :: String.t()
  @callback description() :: String.t()

  @callback pre_tool(tool_name :: String.t(), tool_args :: map()) :: pre_result()
  @callback post_tool(tool_name :: String.t(), tool_args :: map(), result :: term()) ::
              post_result()

  @optional_callbacks [pre_tool: 2, post_tool: 3]
end
