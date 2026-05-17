defmodule Loomkin.Orchestration.Workers.ResearcherTest do
  use ExUnit.Case, async: false

  alias Loomkin.Orchestration.LLM.Stub
  alias Loomkin.Orchestration.Workers.Researcher

  setup do
    start_supervised!(Stub)
    prev = Application.get_env(:loomkin, Loomkin.Orchestration, [])

    Application.put_env(
      :loomkin,
      Loomkin.Orchestration,
      Keyword.put(prev, :llm_adapter, Stub)
    )

    on_exit(fn -> Application.put_env(:loomkin, Loomkin.Orchestration, prev) end)
    :ok
  end

  test "returns the raw text from the LLM" do
    Stub.queue([
      {:by_reviewer, :researcher,
       "## Constraints\n- elixir 1.20\n\n## Open Questions\n- none\n\n## Related Code\n- lib/loomkin/orchestration\n\n## Risks\n- none\n"}
    ])

    {:ok, text} = Researcher.call(%{epic: %{title: "build a thing"}})
    assert text =~ "Constraints"
  end
end
