defmodule Loomkin.Providers.OpenAICompatibleProviderTest do
  @moduledoc """
  Tests for the OpenAI-compatible provider registry.

  Verifies:
  - Registry is started and accessible
  - Endpoint discovery from config
  - Provider endpoint config lookup (atom and string keys)
  - Model discovery from configured endpoints
  """

  use Loomkin.DataCase, async: false

  alias Loomkin.Providers.OpenAICompatibleProvider
  alias Loomkin.Config

  describe "registry lifecycle" do
    test "endpoint_provider_registry is running" do
      # This would have caught the "unknown registry" error
      assert Registry.lookup(:endpoint_provider_registry, "nonexistent") == []
    end

    test "OpenAICompatibleProvider GenServer is running" do
      assert Process.whereis(OpenAICompatibleProvider) != nil
    end
  end

  describe "get_all_endpoints/0" do
    test "returns configured endpoints with valid URLs" do
      endpoints = OpenAICompatibleProvider.get_all_endpoints()
      assert is_list(endpoints)

      # Default config has ollama with a URL
      assert "ollama" in endpoints
    end

    test "excludes endpoints with nil URLs" do
      endpoints = OpenAICompatibleProvider.get_all_endpoints()

      # Default config has vllm with url: nil
      refute "vllm" in endpoints
    end
  end

  describe "get_endpoint_provider/1" do
    test "returns nil for unconfigured provider" do
      assert OpenAICompatibleProvider.get_endpoint_provider("nonexistent") == nil
    end

    test "returns a module atom for a registered provider" do
      # Ollama is registered at boot via init/1
      provider = OpenAICompatibleProvider.get_endpoint_provider("ollama")
      assert is_atom(provider)
      assert Code.ensure_loaded?(provider)
    end
  end

  describe "Config.get_provider_endpoint/1" do
    test "looks up by atom key" do
      result = Config.get_provider_endpoint(:ollama)
      assert %{url: url} = result
      assert is_binary(url)
      assert String.contains?(url, "11434")
    end

    test "looks up by string key" do
      result = Config.get_provider_endpoint("ollama")
      assert %{url: url} = result
      assert is_binary(url)
      assert String.contains?(url, "11434")
    end

    test "returns empty map for unknown provider" do
      assert Config.get_provider_endpoint("unknown_provider_xyz") == %{}
    end

    test "handles TOML-parsed string keys" do
      # Simulate what happens when TOML parser produces string keys
      # that aren't in @known_keys — they stay as strings in the map
      current = Config.get(:provider, :endpoints)

      Config.put(:provider, %{
        endpoints:
          Map.merge(current, %{
            "custom_backend" => %{"url" => "http://localhost:9999/v1", "auth_key" => "test"}
          })
      })

      result = Config.get_provider_endpoint("custom_backend")
      assert %{"url" => "http://localhost:9999/v1"} = result

      # Cleanup — restore original
      Config.put(:provider, %{endpoints: current})
    end
  end

  describe "model discovery integration" do
    test "all_providers_enriched includes endpoint providers" do
      all = Loomkin.Models.all_providers_enriched()

      # Should be a list of {provider, name, status, models} tuples
      assert is_list(all)

      Enum.each(all, fn entry ->
        assert {_provider, _name, _status, _models} = entry
      end)
    end

    test "available_models returns a list of {name, entries} tuples" do
      models = Loomkin.Models.available_models()
      assert is_list(models)

      Enum.each(models, fn entry ->
        assert {name, entries} = entry
        assert is_binary(name)
        assert is_list(entries)
      end)
    end
  end
end
