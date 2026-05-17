defmodule Loomkin.Orchestration.Reviewer do
  @moduledoc """
  Behaviour for a single review participant inside a gate.

  Reviewers are stateless — each call to `c:review/1` produces one
  `Loomkin.Orchestration.Schema.ReviewVerdict`. Adversarial reviewers must cite
  `file:line` evidence; the gate enforces this regardless of the reviewer's
  intent (see `Loomkin.Orchestration.Schema.ReviewVerdict.validate_evidence/1`).
  """

  require Logger

  alias Loomkin.Orchestration.Schema.ReviewVerdict

  @typedoc "Inbound payload for a review run."
  @type payload :: %{
          required(:epic_id) => binary(),
          optional(:work_unit_id) => binary(),
          optional(:artifact) => String.t() | map(),
          optional(:context) => map(),
          optional(:iteration) => pos_integer()
        }

  @callback name() :: atom()
  @callback rubric() :: String.t()

  @doc """
  Optional model override. Returning `nil` falls back to the orchestration
  default model (configured via `Application.get_env(:loomkin, Loomkin.Orchestration)`).
  """
  @callback model() :: String.t() | nil

  @callback review(payload()) :: {:ok, ReviewVerdict.t()} | {:error, term()}

  @optional_callbacks model: 0

  @doc """
  Returns the resolved model name for a reviewer, falling back to the
  configured default.

  When `writer_model` is provided and `:cross_model` is enabled in the
  orchestration config, the reviewer is biased to pick a model from
  `:reviewer_model_pool` that differs from the writer's model — adversarial
  review is strongest when writer and reviewer disagree on substrate.

  Resolution order:

  1. Explicit `.model()` override on the reviewer module wins.
  2. Else, if `cross_model: true` and a `writer_model` is given, pick the
     first entry in `:reviewer_model_pool` that is not equal to
     `writer_model`. If the pool offers no alternative, log a warning and
     fall through to the configured default.
  3. Else, fall back to `:default_model`.
  """
  @spec resolve_model(module(), String.t() | nil) :: String.t()
  def resolve_model(module, writer_model \\ nil) do
    case function_exported?(module, :model, 0) && module.model() do
      model when is_binary(model) and model != "" ->
        model

      _ ->
        cross_model_or_default(writer_model)
    end
  end

  defp cross_model_or_default(writer_model) do
    config = Application.get_env(:loomkin, Loomkin.Orchestration, [])
    default = Keyword.get(config, :default_model, "anthropic:claude-sonnet-4-5")

    cond do
      not Keyword.get(config, :cross_model, false) ->
        default

      is_nil(writer_model) or writer_model == "" ->
        default

      true ->
        pool = Keyword.get(config, :reviewer_model_pool, [])

        case Enum.find(pool, fn m -> m != writer_model end) do
          nil ->
            Logger.warning(
              "cross_model requested but no alternative available, falling back to writer model"
            )

            default

          alternative ->
            alternative
        end
    end
  end
end
