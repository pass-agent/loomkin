defmodule Loomkin.Channels.AdapterTest do
  use ExUnit.Case, async: true

  alias Loomkin.Channels.Adapter

  describe "behaviour callbacks" do
    test "defines send_text/3 callback" do
      callbacks = Adapter.behaviour_info(:callbacks)
      assert {:send_text, 3} in callbacks
    end

    test "defines send_question/4 callback" do
      callbacks = Adapter.behaviour_info(:callbacks)
      assert {:send_question, 4} in callbacks
    end

    test "defines send_activity/2 callback" do
      callbacks = Adapter.behaviour_info(:callbacks)
      assert {:send_activity, 2} in callbacks
    end

    test "defines format_agent_message/2 callback" do
      callbacks = Adapter.behaviour_info(:callbacks)
      assert {:format_agent_message, 2} in callbacks
    end

    test "defines parse_inbound/1 callback" do
      callbacks = Adapter.behaviour_info(:callbacks)
      assert {:parse_inbound, 1} in callbacks
    end

    test "has exactly 5 callbacks" do
      callbacks = Adapter.behaviour_info(:callbacks)
      assert length(callbacks) == 5
    end
  end

  describe "Telegram adapter implements behaviour" do
    test "implements all callbacks" do
      behaviours = Loomkin.Channels.Telegram.Adapter.__info__(:attributes)[:behaviour]
      assert Loomkin.Channels.Adapter in behaviours
    end
  end

  describe "Discord adapter implements behaviour" do
    test "implements all callbacks" do
      behaviours = Loomkin.Channels.Discord.Adapter.__info__(:attributes)[:behaviour]
      assert Loomkin.Channels.Adapter in behaviours
    end
  end

  describe "Mox mock implements behaviour" do
    test "MockAdapter responds to all adapter callbacks" do
      import Mox

      Loomkin.MockAdapter
      |> expect(:send_text, fn _binding, _text, _opts -> :ok end)
      |> expect(:send_question, fn _binding, _question_id, _question, _options -> :ok end)
      |> expect(:send_activity, fn _binding, _event -> :ok end)
      |> expect(:format_agent_message, fn _name, _content -> "formatted" end)
      |> expect(:parse_inbound, fn _raw -> :ignore end)

      binding = %{channel_id: "test"}

      assert :ok = Loomkin.MockAdapter.send_text(binding, "hi", [])
      assert :ok = Loomkin.MockAdapter.send_question(binding, "q-1", "q?", ["a"])
      assert :ok = Loomkin.MockAdapter.send_activity(binding, %{})
      assert "formatted" = Loomkin.MockAdapter.format_agent_message("agent", "msg")
      assert :ignore = Loomkin.MockAdapter.parse_inbound(%{})
    end
  end
end
