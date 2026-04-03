defmodule Loomkin.Channels.Telegram.AdapterTest do
  use ExUnit.Case, async: false

  import Mox

  alias Loomkin.Channels.Telegram.Adapter

  setup :verify_on_exit!

  setup do
    # Point the adapter at our Mox mock
    Application.put_env(:loomkin, :telegex_module, Loomkin.MockTelegex)
    Mox.set_mox_global()

    on_exit(fn ->
      Application.delete_env(:loomkin, :telegex_module)
    end)

    binding = %{channel_id: "12345"}
    %{binding: binding}
  end

  describe "send_text/3" do
    test "sends a single message for short text", %{binding: binding} do
      expect(Loomkin.MockTelegex, :send_message, fn chat_id, text, opts ->
        assert chat_id == "12345"
        assert text == "Hello world"
        assert Keyword.get(opts, :parse_mode) == "MarkdownV2"
        {:ok, %{}}
      end)

      assert :ok = Adapter.send_text(binding, "Hello world", [])
    end

    test "sends multiple messages for long text", %{binding: binding} do
      # Create text > 4096 chars to force splitting
      long_text = String.duplicate("x", 5000)

      expect(Loomkin.MockTelegex, :send_message, 2, fn _chat_id, chunk, _opts ->
        assert byte_size(chunk) <= 4096
        {:ok, %{}}
      end)

      assert :ok = Adapter.send_text(binding, long_text, [])
    end

    test "returns error when Telegex fails", %{binding: binding} do
      expect(Loomkin.MockTelegex, :send_message, fn _chat_id, _text, _opts ->
        {:error, "rate limited"}
      end)

      assert {:error, "rate limited"} = Adapter.send_text(binding, "hi", [])
    end
  end

  describe "send_question/4" do
    test "sends question with inline keyboard", %{binding: binding} do
      expect(Loomkin.MockTelegex, :send_message, fn chat_id, _text, opts ->
        assert chat_id == "12345"
        assert Keyword.get(opts, :parse_mode) == "MarkdownV2"

        keyboard = Keyword.get(opts, :reply_markup)
        assert keyboard != nil
        assert length(keyboard.inline_keyboard) == 2

        [[btn_a], [btn_b]] = keyboard.inline_keyboard
        assert btn_a.text == "Option A"
        assert btn_a.callback_data == "ask_user:q-42:0"
        assert btn_b.text == "Option B"
        assert btn_b.callback_data == "ask_user:q-42:1"

        {:ok, %{}}
      end)

      assert :ok = Adapter.send_question(binding, "q-42", "Choose:", ["Option A", "Option B"])
    end

    test "returns error when Telegex fails", %{binding: binding} do
      expect(Loomkin.MockTelegex, :send_message, fn _chat_id, _text, _opts ->
        {:error, :forbidden}
      end)

      assert {:error, :forbidden} = Adapter.send_question(binding, "q-1", "Pick", ["A"])
    end
  end

  describe "send_activity/2" do
    test "sends formatted activity event", %{binding: binding} do
      expect(Loomkin.MockTelegex, :send_message, fn chat_id, text, opts ->
        assert chat_id == "12345"
        assert text =~ "Conflict detected"
        assert Keyword.get(opts, :parse_mode) == "MarkdownV2"
        {:ok, %{}}
      end)

      event = %{type: :conflict_detected, agents: ["a", "b"]}
      assert :ok = Adapter.send_activity(binding, event)
    end
  end

  describe "parse_inbound/1" do
    test "parses a regular text message" do
      update = %{
        "message" => %{
          "message_id" => 42,
          "text" => "Hello bot",
          "chat" => %{"id" => 12345},
          "from" => %{
            "id" => 99,
            "username" => "testuser",
            "first_name" => "Test"
          }
        }
      }

      assert {:message, "Hello bot", metadata} = Adapter.parse_inbound(update)
      assert metadata.message_id == 42
      assert metadata.chat_id == 12345
      assert metadata.from_id == 99
      assert metadata.from_username == "testuser"
      assert metadata.from_first_name == "Test"
    end

    test "parses an edited message" do
      update = %{
        "edited_message" => %{
          "message_id" => 43,
          "text" => "Edited text",
          "chat" => %{"id" => 12345},
          "from" => %{
            "id" => 99,
            "username" => "editor"
          }
        }
      }

      assert {:message, "Edited text", metadata} = Adapter.parse_inbound(update)
      assert metadata.edited == true
      assert metadata.from_username == "editor"
    end

    test "parses callback query with structured ask_user data" do
      stub(Loomkin.MockTelegex, :answer_callback_query, fn _id -> {:ok, true} end)

      update = %{
        "callback_query" => %{
          "id" => "cb-123",
          "data" => "ask_user:q-42:1",
          "message" => %{
            "chat" => %{"id" => 12345}
          }
        }
      }

      assert {:callback, "q-42", %{raw: "ask_user:q-42:1", from_id: nil}} =
               Adapter.parse_inbound(update)
    end

    test "parses callback query with legacy unstructured data" do
      stub(Loomkin.MockTelegex, :answer_callback_query, fn _id -> {:ok, true} end)

      update = %{
        "callback_query" => %{
          "id" => "cb-456",
          "data" => "Option A",
          "message" => %{
            "chat" => %{"id" => 12345}
          }
        }
      }

      # Legacy fallback: data is used as callback_id, wrapped with user metadata
      assert {:callback, "Option A", %{raw: "Option A", from_id: nil}} =
               Adapter.parse_inbound(update)
    end

    test "ignores unknown update types" do
      assert :ignore = Adapter.parse_inbound(%{"channel_post" => %{}})
    end

    test "ignores non-map values" do
      assert :ignore = Adapter.parse_inbound("string")
      assert :ignore = Adapter.parse_inbound(nil)
      assert :ignore = Adapter.parse_inbound(42)
    end

    test "handles message with missing text gracefully" do
      update = %{
        "message" => %{
          "message_id" => 44,
          "chat" => %{"id" => 12345},
          "from" => %{}
        }
      }

      assert {:message, "", _metadata} = Adapter.parse_inbound(update)
    end

    test "handles message with missing from gracefully" do
      update = %{
        "message" => %{
          "message_id" => 45,
          "text" => "Hi",
          "chat" => %{"id" => 12345}
        }
      }

      assert {:message, "Hi", metadata} = Adapter.parse_inbound(update)
      assert metadata.from_id == nil
    end
  end

  describe "format_agent_message/2" do
    test "delegates to formatter" do
      result = Adapter.format_agent_message("researcher", "Found a bug")
      assert result =~ "researcher"
      assert result =~ "Found a bug"
    end
  end
end
