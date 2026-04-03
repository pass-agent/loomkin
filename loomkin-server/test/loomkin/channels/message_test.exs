defmodule Loomkin.Channels.MessageTest do
  use ExUnit.Case, async: true

  alias Loomkin.Channels.Message

  describe "struct" do
    test "enforces :direction and :channel keys" do
      assert_raise ArgumentError, ~r/keys must also be given/, fn ->
        struct!(Message, %{})
      end
    end

    test "creates struct with all fields" do
      msg = %Message{
        direction: :inbound,
        channel: :telegram,
        binding_id: "bind-1",
        sender: "user123",
        content: "hello",
        metadata: %{from_id: 42},
        timestamp: ~U[2026-01-01 00:00:00Z]
      }

      assert msg.direction == :inbound
      assert msg.channel == :telegram
      assert msg.binding_id == "bind-1"
      assert msg.sender == "user123"
      assert msg.content == "hello"
      assert msg.metadata == %{from_id: 42}
      assert msg.timestamp == ~U[2026-01-01 00:00:00Z]
    end

    test "defaults metadata to empty map and timestamp to nil" do
      msg = %Message{direction: :outbound, channel: :discord}
      assert msg.metadata == %{}
      assert msg.timestamp == nil
      assert msg.binding_id == nil
      assert msg.sender == nil
      assert msg.content == nil
    end
  end

  describe "inbound/4" do
    test "creates an inbound message with required fields" do
      msg = Message.inbound(:telegram, "user1", "hello world")

      assert msg.direction == :inbound
      assert msg.channel == :telegram
      assert msg.sender == "user1"
      assert msg.content == "hello world"
      assert msg.metadata == %{}
      assert %DateTime{} = msg.timestamp
    end

    test "accepts optional metadata" do
      meta = %{chat_id: 123, from_username: "bob"}
      msg = Message.inbound(:discord, "bob", "hi", meta)

      assert msg.metadata == meta
    end
  end

  describe "outbound/4" do
    test "creates an outbound message with required fields" do
      msg = Message.outbound(:telegram, "bind-abc", "response text")

      assert msg.direction == :outbound
      assert msg.channel == :telegram
      assert msg.binding_id == "bind-abc"
      assert msg.content == "response text"
      assert msg.metadata == %{}
      assert %DateTime{} = msg.timestamp
    end

    test "accepts optional metadata" do
      meta = %{message_id: 456}
      msg = Message.outbound(:discord, "bind-xyz", "ok", meta)

      assert msg.metadata == meta
    end
  end
end
