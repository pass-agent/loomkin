defmodule Loomkin.Orchestration.Knowledge.JSONLRoundTripTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Orchestration.Knowledge.{Exporter, Importer}
  alias Loomkin.Orchestration.KnowledgeStore

  setup do
    # KnowledgeStore is started by the application supervisor. The DataCase
    # sandbox covers Repo writes.
    :ok
  end

  test "interoperable JSONL knowledge format round-trips through Importer → Exporter" do
    src = Path.join(System.tmp_dir!(), "knowledge_in_#{System.unique_integer([:positive])}.jsonl")

    dst =
      Path.join(System.tmp_dir!(), "knowledge_out_#{System.unique_integer([:positive])}.jsonl")

    on_exit(fn ->
      File.rm(src)
      File.rm(dst)
    end)

    sample = """
    {"id":"k-1","type":"pattern","fact":"prefer LiveComponent for repeated UI","recommendation":"use LiveComponent when shape appears 2+","confidence":"high","provenance":[{"source":"human","reference":"design review"}],"tags":["phoenix","liveview"],"affectedFiles":["lib/loomkin_web/components/foo.ex"],"createdAt":"2026-04-03T10:00:00Z"}
    {"id":"k-2","type":"gotcha","fact":"gen_statem state-enter cannot return :next_event","recommendation":"use state_timeout 0","confidence":"high","provenance":[{"source":"agent","reference":"orchestration build"}],"tags":["elixir","gen_statem"],"affectedFiles":["lib/loomkin/orchestration/issue_orchestrator.ex"],"createdAt":"2026-05-16T00:00:00Z"}
    """

    File.write!(src, sample)

    assert {:ok, %{imported: 2, errors: []}} = Importer.import_file(src)

    k1 = KnowledgeStore.get_by_external_id("k-1")
    k2 = KnowledgeStore.get_by_external_id("k-2")
    assert k1.confidence == :high
    assert k2.type == :gotcha

    {:ok, 2} = Exporter.write_facts(dst, [k1, k2])

    [line1, line2] =
      dst
      |> File.read!()
      |> String.trim()
      |> String.split("\n", trim: true)

    decoded1 = Jason.decode!(line1)
    decoded2 = Jason.decode!(line2)

    assert decoded1["id"] == "k-1"
    assert decoded1["affectedFiles"] == ["lib/loomkin_web/components/foo.ex"]
    assert decoded1["confidence"] == "high"
    assert decoded2["type"] == "gotcha"
  end
end
