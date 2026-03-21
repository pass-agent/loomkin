defmodule Loomkin.Security.RedactorTest do
  use ExUnit.Case, async: true

  alias Loomkin.Security.Redactor

  setup do
    # Enable redaction for these tests (disabled by default in test env)
    Redactor.enable()
    on_exit(fn -> Redactor.disable() end)
    :ok
  end

  describe "redact/1 with non-string input" do
    test "returns non-string values unchanged" do
      assert Redactor.redact(42) == 42
      assert Redactor.redact(nil) == nil
      assert Redactor.redact(:atom) == :atom
      assert Redactor.redact([1, 2]) == [1, 2]
    end
  end

  describe "redact/1 with OpenAI/Anthropic/Stripe sk- keys" do
    test "redacts sk- keys with sufficient length" do
      input = "Using key sk-1234567890abcdefghijklmnopqrst"
      assert Redactor.redact(input) == "Using key [REDACTED]"
    end

    test "does not redact short sk- prefixed strings" do
      input = "sk-short"
      assert Redactor.redact(input) == "sk-short"
    end

    test "redacts sk- key embedded in JSON" do
      input = ~s({"api_key": "sk-abcdefghij1234567890ABCDEFGHIJ"})
      result = Redactor.redact(input)
      refute result =~ "sk-abcdefghij"
      assert result =~ "[REDACTED]"
    end
  end

  describe "redact/1 with AWS access keys" do
    test "redacts AKIA access key IDs" do
      input = "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE"
      assert Redactor.redact(input) == "AWS_ACCESS_KEY_ID=[REDACTED]"
    end
  end

  describe "redact/1 with GitHub tokens" do
    test "redacts ghp_ personal access tokens" do
      token = "ghp_" <> String.duplicate("a", 40)
      input = "token: #{token}"
      result = Redactor.redact(input)
      refute result =~ "ghp_"
      assert result =~ "[REDACTED]"
    end

    test "redacts gho_ OAuth tokens" do
      token = "gho_" <> String.duplicate("B", 40)
      input = "Authorization: #{token}"
      result = Redactor.redact(input)
      refute result =~ "gho_"
      assert result =~ "[REDACTED]"
    end
  end

  describe "redact/1 with Bearer tokens" do
    test "redacts Bearer tokens" do
      input = "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abc123"
      result = Redactor.redact(input)
      refute result =~ "eyJhbGci"
      assert result =~ "[REDACTED]"
    end

    test "is case-insensitive for Bearer" do
      input = "bearer mytoken123abc"
      result = Redactor.redact(input)
      assert result =~ "[REDACTED]"
    end
  end

  describe "redact/1 with connection strings" do
    test "redacts postgres connection string passwords" do
      input = "DATABASE_URL=postgresql://user:s3cr3tP@ss@localhost:5432/mydb"
      result = Redactor.redact(input)
      refute result =~ "s3cr3tP@ss"
      assert result =~ "[REDACTED]"
      # Host portion should remain
      assert result =~ "localhost:5432"
    end

    test "redacts redis connection string passwords" do
      input = "REDIS_URL=redis://default:myp4ssw0rd@redis.host:6379"
      result = Redactor.redact(input)
      refute result =~ "myp4ssw0rd"
      assert result =~ "[REDACTED]"
    end

    test "redacts mongodb+srv connection strings" do
      input = "mongodb+srv://admin:hunter2password@cluster.mongodb.net"
      result = Redactor.redact(input)
      refute result =~ "hunter2password"
      assert result =~ "[REDACTED]"
    end
  end

  describe "redact/1 with key-value secrets" do
    test "redacts password = 'value' patterns" do
      input = ~s(password = "my_secret_password_123")
      result = Redactor.redact(input)
      refute result =~ "my_secret_password_123"
      assert result =~ "[REDACTED]"
    end

    test "redacts api_key: 'value' patterns" do
      input = ~s(api_key: 'abcdefgh12345678')
      result = Redactor.redact(input)
      refute result =~ "abcdefgh12345678"
      assert result =~ "[REDACTED]"
    end

    test "does not redact short values (< 8 chars)" do
      input = ~s(password = "short")
      assert Redactor.redact(input) == input
    end
  end

  describe "redact/1 with Slack tokens" do
    test "redacts xoxb- bot tokens" do
      input = "SLACK_TOKEN=xoxb-1234567890-abcdefghij"
      result = Redactor.redact(input)
      refute result =~ "xoxb-"
      assert result =~ "[REDACTED]"
    end

    test "redacts xoxp- user tokens" do
      input = "xoxp-1234567890-abcdefghij"
      result = Redactor.redact(input)
      assert result == "[REDACTED]"
    end
  end

  describe "redact/1 with private keys" do
    test "redacts RSA private key blocks" do
      input = """
      Here is a key:
      -----BEGIN RSA PRIVATE KEY-----
      MIIEowIBAAKCAQEA2a2rwplBQr8Hk...
      -----END RSA PRIVATE KEY-----
      Done.
      """

      result = Redactor.redact(input)
      refute result =~ "MIIEowIBAAKCAQEA2a2rwplBQr8Hk"
      assert result =~ "[REDACTED]"
      assert result =~ "Here is a key:"
      assert result =~ "Done."
    end

    test "redacts generic private key blocks" do
      input = "-----BEGIN PRIVATE KEY-----\ndata\n-----END PRIVATE KEY-----"
      result = Redactor.redact(input)
      assert result =~ "[REDACTED]"
      refute result =~ "data"
    end
  end

  describe "redact/1 with multiple secrets" do
    test "redacts multiple different secret types in the same text" do
      input =
        "key=sk-abcdefghij1234567890ABCDEFGHIJ " <>
          "token=ghp_" <>
          String.duplicate("x", 40) <>
          " " <>
          "db=postgresql://user:secret_pw@host/db"

      result = Redactor.redact(input)
      refute result =~ "sk-abcdefghij"
      refute result =~ "ghp_"
      refute result =~ "secret_pw"
      assert String.contains?(result, "[REDACTED]")
    end
  end

  describe "redact/1 with safe text" do
    test "does not redact normal text" do
      input = "This is a normal message about deploying the application to production."
      assert Redactor.redact(input) == input
    end

    test "does not redact code snippets" do
      input = "def handle_call(:get_state, _from, state), do: {:reply, state, state}"
      assert Redactor.redact(input) == input
    end

    test "does not redact short alphanumeric strings" do
      input = "The task ID is abc123 and the status is ok"
      assert Redactor.redact(input) == input
    end
  end

  describe "enabled?/0 and enable/disable" do
    test "disabled in test env by default" do
      Redactor.disable()
      assert Redactor.enabled?() == false
    end

    test "can be enabled for tests" do
      Redactor.enable()
      assert Redactor.enabled?() == true
    end

    test "when disabled, redact/1 passes text through unchanged" do
      Redactor.disable()
      input = "sk-1234567890abcdefghijklmnopqrst"
      assert Redactor.redact(input) == input
    end
  end

  describe "custom patterns via application config" do
    test "user-configured patterns are applied" do
      custom = [{~r/CUSTOM-[A-Z]{10,}/, "custom key"}]
      Application.put_env(:loomkin, :redaction_patterns, custom)
      on_exit(fn -> Application.delete_env(:loomkin, :redaction_patterns) end)

      input = "key=CUSTOM-ABCDEFGHIJ"
      result = Redactor.redact(input)
      assert result == "key=[REDACTED]"
    end
  end
end
