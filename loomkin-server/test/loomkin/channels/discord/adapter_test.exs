defmodule Loomkin.Channels.Discord.AdapterTest do
  use ExUnit.Case, async: false

  import Mox

  alias Loomkin.Channels.Discord.Adapter

  setup :verify_on_exit!

  setup do
    Application.put_env(:loomkin, :nostrum_api, Loomkin.MockNostrumApi)
    Mox.set_mox_global()

    on_exit(fn ->
      Application.delete_env(:loomkin, :nostrum_api)
    end)

    binding = %{channel_id: "67890"}
    %{binding: binding}
  end

  describe "send_text/3" do
    test "sends text to integer channel_id", %{binding: binding} do
      expect(Loomkin.MockNostrumApi, :create_message, fn channel_id, opts ->
        assert channel_id == 67890
        assert Keyword.get(opts, :content) == "Hello Discord"
        {:ok, %{}}
      end)

      assert :ok = Adapter.send_text(binding, "Hello Discord", [])
    end

    test "splits long messages", %{binding: binding} do
      long_text = String.duplicate("y", 3000)

      expect(Loomkin.MockNostrumApi, :create_message, 2, fn 67890, opts ->
        chunk = Keyword.get(opts, :content)
        assert byte_size(chunk) <= 2000
        {:ok, %{}}
      end)

      assert :ok = Adapter.send_text(binding, long_text, [])
    end
  end

  describe "send_question/4" do
    test "sends question with button components", %{binding: binding} do
      expect(Loomkin.MockNostrumApi, :create_message, fn 67890, opts ->
        assert Keyword.get(opts, :content) == "Choose one:"

        components = Keyword.get(opts, :components)
        assert length(components) == 1

        [action_row] = components
        assert action_row.type == 1
        buttons = action_row.components
        assert length(buttons) == 2

        [btn_a, btn_b] = buttons
        assert btn_a.label == "A"
        assert btn_a.custom_id == "ask_user:q-99:0"
        assert btn_b.label == "B"
        assert btn_b.custom_id == "ask_user:q-99:1"

        {:ok, %{}}
      end)

      assert :ok = Adapter.send_question(binding, "q-99", "Choose one:", ["A", "B"])
    end

    test "chunks more than 5 options into multiple action rows", %{binding: binding} do
      expect(Loomkin.MockNostrumApi, :create_message, fn 67890, opts ->
        components = Keyword.get(opts, :components)
        # 7 options = 2 action rows (5 + 2)
        assert length(components) == 2
        {:ok, %{}}
      end)

      options = Enum.map(1..7, &"Option #{&1}")
      assert :ok = Adapter.send_question(binding, "q-big", "Pick:", options)
    end
  end

  describe "send_activity/2" do
    test "sends embed for activity event", %{binding: binding} do
      expect(Loomkin.MockNostrumApi, :create_message, fn 67890, opts ->
        embeds = Keyword.get(opts, :embeds)
        assert length(embeds) == 1

        [embed] = embeds
        assert embed.title == "conflict detected"
        assert is_integer(embed.color)
        {:ok, %{}}
      end)

      event = %{type: :conflict_detected, summary: "file overlap", agent_role: :coder}
      assert :ok = Adapter.send_activity(binding, event)
    end
  end

  describe "parse_inbound/1" do
    test "parses MESSAGE_CREATE event" do
      event = %{
        type: :MESSAGE_CREATE,
        content: "Hello bot",
        id: 12345,
        channel_id: 67890,
        guild_id: 11111,
        author: %{id: 99, username: "testuser"},
        bot: false
      }

      assert {:message, "Hello bot", metadata} = Adapter.parse_inbound(event)
      assert metadata.discord_message_id == 12345
      assert metadata.discord_channel_id == 67890
      assert metadata.guild_id == 11111
      assert metadata.user_id == 99
    end

    test "ignores bot messages" do
      event = %{
        type: :MESSAGE_CREATE,
        content: "Bot response",
        id: 1,
        channel_id: 2,
        author: %{id: 99, username: "bot"},
        bot: true
      }

      assert :ignore = Adapter.parse_inbound(event)
    end

    test "parses INTERACTION_CREATE with ask_user custom_id" do
      event = %{
        type: :INTERACTION_CREATE,
        data: %{custom_id: "ask_user:q-abc:2"},
        channel_id: 67890,
        guild_id: 11111,
        token: "interaction-token",
        id: 54321
      }

      assert {:callback, "q-abc", %{index: 2, interaction: ^event}} =
               Adapter.parse_inbound(event)
    end

    test "ignores INTERACTION_CREATE with non-ask_user custom_id" do
      event = %{
        type: :INTERACTION_CREATE,
        data: %{custom_id: "other:something"},
        channel_id: 67890
      }

      assert :ignore = Adapter.parse_inbound(event)
    end

    test "ignores unknown event types" do
      assert :ignore = Adapter.parse_inbound(%{type: :GUILD_CREATE})
      assert :ignore = Adapter.parse_inbound(%{})
      assert :ignore = Adapter.parse_inbound("not a map")
    end

    test "handles message with empty content" do
      event = %{
        type: :MESSAGE_CREATE,
        id: 1,
        channel_id: 2,
        author: %{id: 99, username: "user"},
        bot: false
      }

      assert {:message, "", _metadata} = Adapter.parse_inbound(event)
    end
  end

  describe "format_agent_message/2" do
    test "delegates to formatter" do
      result = Adapter.format_agent_message("coder", "Fixed the bug")
      assert result == "**coder**\nFixed the bug"
    end
  end
end
