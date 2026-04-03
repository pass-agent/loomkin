defmodule Loomkin.Teams.QueuedMessageTest do
  use ExUnit.Case, async: true

  alias Loomkin.Teams.QueuedMessage

  describe "new/2" do
    test "creates struct with generated ID and defaults" do
      qm = QueuedMessage.new("hello")

      assert is_binary(qm.id)
      assert String.starts_with?(qm.id, "qm_")
      assert qm.content == "hello"
      assert qm.source == :system
      assert qm.priority == :normal
      assert qm.status == :pending
      assert %DateTime{} = qm.queued_at
      assert qm.metadata == %{}
    end

    test "accepts custom options" do
      qm =
        QueuedMessage.new({:inject_system_message, "test"},
          priority: :high,
          source: :user,
          status: :editing,
          metadata: %{from: "researcher"}
        )

      assert qm.content == {:inject_system_message, "test"}
      assert qm.priority == :high
      assert qm.source == :user
      assert qm.status == :editing
      assert qm.metadata == %{from: "researcher"}
    end

    test "generates unique IDs" do
      ids =
        1..100
        |> Enum.map(fn _ -> QueuedMessage.new("msg").id end)
        |> MapSet.new()

      assert MapSet.size(ids) == 100
    end
  end

  describe "to_dispatchable/1" do
    test "extracts original content from a string" do
      qm = QueuedMessage.new("hello world")
      assert QueuedMessage.to_dispatchable(qm) == "hello world"
    end

    test "extracts original content from a tuple" do
      content = {:inject_system_message, "[User Guidance]: do X"}
      qm = QueuedMessage.new(content)
      assert QueuedMessage.to_dispatchable(qm) == content
    end

    test "extracts original content from a complex tuple" do
      content = {:task_assigned, "t1", "coder-1"}
      qm = QueuedMessage.new(content, priority: :high)
      assert QueuedMessage.to_dispatchable(qm) == content
    end
  end
end
