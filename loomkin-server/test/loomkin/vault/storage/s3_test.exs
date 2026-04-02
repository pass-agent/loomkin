defmodule Loomkin.Vault.Storage.S3Test do
  use ExUnit.Case, async: true

  @moduletag :s3

  alias Loomkin.Vault.Storage.S3

  describe "s3_key/2" do
    test "prepends default vault/ prefix" do
      assert S3.s3_key("notes/hello.md", []) == "vault/notes/hello.md"
    end

    test "uses custom prefix when provided" do
      assert S3.s3_key("notes/hello.md", prefix: "data/") == "data/notes/hello.md"
    end

    test "handles empty path" do
      assert S3.s3_key("", []) == "vault/"
    end
  end

  describe "build_config/1" do
    test "returns empty config for empty opts" do
      assert S3.build_config([]) == []
    end

    test "includes region when provided" do
      config = S3.build_config(region: "us-east-1")
      assert Keyword.get(config, :region) == "us-east-1"
    end

    test "includes credentials when provided" do
      config = S3.build_config(access_key_id: "AKID", secret_access_key: "secret")
      assert Keyword.get(config, :access_key_id) == "AKID"
      assert Keyword.get(config, :secret_access_key) == "secret"
    end

    test "parses endpoint into host, scheme, and port" do
      config = S3.build_config(endpoint: "https://fly.storage.tigris.dev")
      assert Keyword.get(config, :host) == "fly.storage.tigris.dev"
      assert Keyword.get(config, :scheme) == "https://"
      assert Keyword.get(config, :port) == 443
    end

    test "parses http endpoint with custom port" do
      config = S3.build_config(endpoint: "http://localhost:9000")
      assert Keyword.get(config, :host) == "localhost"
      assert Keyword.get(config, :scheme) == "http://"
      assert Keyword.get(config, :port) == 9000
    end

    test "combines all options" do
      config =
        S3.build_config(
          endpoint: "https://s3.example.com",
          region: "eu-west-1",
          access_key_id: "key",
          secret_access_key: "secret"
        )

      assert Keyword.get(config, :host) == "s3.example.com"
      assert Keyword.get(config, :region) == "eu-west-1"
      assert Keyword.get(config, :access_key_id) == "key"
      assert Keyword.get(config, :secret_access_key) == "secret"
    end
  end
end
