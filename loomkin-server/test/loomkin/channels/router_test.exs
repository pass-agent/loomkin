defmodule Loomkin.Channels.RouterTest do
  use Loomkin.DataCase, async: false

  import Mox

  alias Loomkin.Channels.Router

  setup :verify_on_exit!

  setup do
    # Ensure Config is started for ACL tests
    try do
      Loomkin.Config.start_link()
    catch
      :error, {:already_started, _} -> :ok
    end

    # Clear ACL to allow all by default
    Loomkin.Config.put(:channels, %{
      telegram: %{allowed_chat_ids: [], allow_user_ids: []},
      discord: %{guild_ids: [], allow_user_ids: []}
    })

    Mox.set_mox_global()

    :ok
  end

  describe "check_channel_acl/2" do
    test "allows any channel when allowlist is empty" do
      Loomkin.Config.put(:channels, %{telegram: %{allowed_chat_ids: [], allow_user_ids: []}})
      assert :ok = Router.check_channel_acl(:telegram, "12345")
    end

    test "allows channel in allowlist" do
      Loomkin.Config.put(:channels, %{telegram: %{allowed_chat_ids: [12345], allow_user_ids: []}})
      assert :ok = Router.check_channel_acl(:telegram, "12345")
    end

    test "rejects channel not in allowlist" do
      Loomkin.Config.put(:channels, %{telegram: %{allowed_chat_ids: [12345], allow_user_ids: []}})
      assert {:error, :channel_not_allowed} = Router.check_channel_acl(:telegram, "99999")
    end

    test "handles integer and string IDs interchangeably" do
      Loomkin.Config.put(:channels, %{
        telegram: %{allowed_chat_ids: ["12345"], allow_user_ids: []}
      })

      assert :ok = Router.check_channel_acl(:telegram, 12345)
    end

    test "works with discord guild_ids" do
      Loomkin.Config.put(:channels, %{discord: %{guild_ids: ["guild-1"], allow_user_ids: []}})
      assert :ok = Router.check_channel_acl(:discord, "guild-1")
    end

    test "rejects unknown discord guild" do
      Loomkin.Config.put(:channels, %{discord: %{guild_ids: ["guild-1"], allow_user_ids: []}})
      assert {:error, :channel_not_allowed} = Router.check_channel_acl(:discord, "guild-2")
    end
  end

  describe "check_user_acl/2" do
    test "allows any user when allowlist is empty" do
      Loomkin.Config.put(:channels, %{telegram: %{allowed_chat_ids: [], allow_user_ids: []}})
      assert :ok = Router.check_user_acl(:telegram, %{from_id: 999})
    end

    test "allows user in allowlist" do
      Loomkin.Config.put(:channels, %{telegram: %{allowed_chat_ids: [], allow_user_ids: [42]}})
      assert :ok = Router.check_user_acl(:telegram, %{from_id: 42})
    end

    test "rejects user not in allowlist" do
      Loomkin.Config.put(:channels, %{telegram: %{allowed_chat_ids: [], allow_user_ids: [42]}})
      assert {:error, :user_not_allowed} = Router.check_user_acl(:telegram, %{from_id: 999})
    end

    test "allows through when metadata has no user_id" do
      Loomkin.Config.put(:channels, %{telegram: %{allowed_chat_ids: [], allow_user_ids: [42]}})
      assert :ok = Router.check_user_acl(:telegram, %{})
    end

    test "works with discord user_id" do
      Loomkin.Config.put(:channels, %{discord: %{guild_ids: [], allow_user_ids: [100]}})
      assert :ok = Router.check_user_acl(:discord, %{user_id: 100})
    end

    test "rejects discord user not in allowlist" do
      Loomkin.Config.put(:channels, %{discord: %{guild_ids: [], allow_user_ids: [100]}})
      assert {:error, :user_not_allowed} = Router.check_user_acl(:discord, %{user_id: 200})
    end
  end

  describe "parse_command/1" do
    test "parses command without arguments" do
      assert {:command, "bind", ""} = Router.parse_command("/bind")
    end

    test "parses command with arguments" do
      assert {:command, "bind", "team-123"} = Router.parse_command("/bind team-123")
    end

    test "parses command with multiple word arguments" do
      assert {:command, "ask", "lead What is the plan?"} =
               Router.parse_command("/ask lead What is the plan?")
    end

    test "handles extra whitespace in arguments" do
      assert {:command, "bind", "team-123"} = Router.parse_command("/bind   team-123")
    end

    test "returns :not_command for regular messages" do
      assert :not_command = Router.parse_command("hello world")
    end

    test "returns :not_command for empty string" do
      assert :not_command = Router.parse_command("")
    end

    test "recognizes all supported commands" do
      for cmd <- ~w(bind unbind status agents ask cancel send cost perm approve audit) do
        assert {:command, ^cmd, _} = Router.parse_command("/#{cmd}")
      end
    end

    test "parses unknown commands without error" do
      assert {:command, "unknown", ""} = Router.parse_command("/unknown")
    end

    test "parses /cancel with session_id" do
      assert {:command, "cancel", "sess-abc"} = Router.parse_command("/cancel sess-abc")
    end

    test "parses /send with session_id and text" do
      assert {:command, "send", "sess-abc hello there"} =
               Router.parse_command("/send sess-abc hello there")
    end

    test "parses /cost with team_id" do
      assert {:command, "cost", "team-xyz"} = Router.parse_command("/cost team-xyz")
    end

    test "parses /cost without arguments" do
      assert {:command, "cost", ""} = Router.parse_command("/cost")
    end

    test "parses /approve with request_id and action" do
      assert {:command, "approve", "req-1 once"} = Router.parse_command("/approve req-1 once")
    end
  end

  describe "handle_inbound/4 with Mox" do
    test "routes commands through parse_command" do
      stub(Loomkin.MockAdapter, :parse_inbound, fn _raw ->
        {:message, "/status", %{}}
      end)

      # /status without a binding returns a help message
      result = Router.handle_inbound(Loomkin.MockAdapter, :telegram, "chat-1", %{})
      assert {:ok, text} = result
      assert text =~ "No active binding"
    end

    test "ACL blocks disallowed channels" do
      Loomkin.Config.put(:channels, %{telegram: %{allowed_chat_ids: [999], allow_user_ids: []}})

      assert {:error, :channel_not_allowed} =
               Router.handle_inbound(Loomkin.MockAdapter, :telegram, "111", %{})
    end

    test "ignores events when adapter returns :ignore" do
      stub(Loomkin.MockAdapter, :parse_inbound, fn _raw -> :ignore end)

      assert {:ok, :ignored} =
               Router.handle_inbound(Loomkin.MockAdapter, :telegram, "chat-1", %{})
    end

    test "returns unknown command help for unrecognized commands" do
      stub(Loomkin.MockAdapter, :parse_inbound, fn _raw ->
        {:message, "/foobar", %{}}
      end)

      assert {:ok, text} = Router.handle_inbound(Loomkin.MockAdapter, :telegram, "chat-1", %{})
      assert text =~ "Unknown command"
      assert text =~ "/foobar"
    end

    test "returns :no_binding for messages without a bridge or binding" do
      stub(Loomkin.MockAdapter, :parse_inbound, fn _raw ->
        {:message, "hello", %{}}
      end)

      assert {:error, :no_binding} =
               Router.handle_inbound(Loomkin.MockAdapter, :telegram, "unbound-chat", %{})
    end
  end

  describe "handle_callback/4" do
    test "returns error when no bridge exists" do
      assert {:error, :no_binding} =
               Router.handle_callback(:telegram, "no-bridge", "cb-1", "data")
    end
  end
end
