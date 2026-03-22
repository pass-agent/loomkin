defmodule Loomkin.Auth.ProviderRegistryTest do
  use ExUnit.Case, async: true

  alias Loomkin.Auth.ProviderRegistry

  describe "all/0" do
    test "returns a non-empty list of provider entries" do
      providers = ProviderRegistry.all()
      assert is_list(providers)
      assert length(providers) >= 3
    end

    test "includes all expected providers" do
      ids = Enum.map(ProviderRegistry.all(), & &1.id)
      assert :anthropic in ids
      assert :google in ids
      assert :openai in ids
    end

    test "each entry has required keys" do
      required_keys = [
        :id,
        :display_name,
        :auth_module,
        :reqllm_module,
        :oauth_prefix,
        :base_prefix,
        :env_var,
        :flow_type
      ]

      for entry <- ProviderRegistry.all() do
        for key <- required_keys do
          assert Map.has_key?(entry, key),
                 "Entry #{inspect(entry.id)} missing key #{inspect(key)}"
        end
      end
    end

    test "all provider IDs are atoms" do
      for entry <- ProviderRegistry.all() do
        assert is_atom(entry.id)
      end
    end

    test "all flow types are :redirect or :paste_back" do
      for entry <- ProviderRegistry.all() do
        assert entry.flow_type in [:redirect, :paste_back],
               "#{entry.id} has invalid flow_type: #{inspect(entry.flow_type)}"
      end
    end
  end

  describe "get/1" do
    test "returns entry for each registered provider" do
      for entry <- ProviderRegistry.all() do
        result = ProviderRegistry.get(entry.id)
        assert result != nil
        assert result.id == entry.id
        assert result.display_name == entry.display_name
      end
    end

    test "returns nil for unknown provider" do
      assert nil == ProviderRegistry.get(:nonexistent)
    end
  end

  describe "get!/1" do
    test "returns entry for each registered provider" do
      for entry <- ProviderRegistry.all() do
        assert entry == ProviderRegistry.get!(entry.id)
      end
    end

    test "raises for unknown provider" do
      assert_raise ArgumentError, ~r/Unknown OAuth provider/, fn ->
        ProviderRegistry.get!(:nonexistent)
      end
    end
  end

  describe "provider_ids/0" do
    test "matches the IDs from all/0" do
      assert ProviderRegistry.provider_ids() == Enum.map(ProviderRegistry.all(), & &1.id)
    end
  end

  describe "provider_id_strings/0" do
    test "each string corresponds to an atom ID" do
      strings = ProviderRegistry.provider_id_strings()
      ids = ProviderRegistry.provider_ids()
      assert length(strings) == length(ids)

      for {str, id} <- Enum.zip(strings, ids) do
        assert str == Atom.to_string(id)
      end
    end
  end

  describe "auth_modules/0" do
    test "returns a map keyed by provider ID to auth module" do
      modules = ProviderRegistry.auth_modules()
      assert is_map(modules)

      for entry <- ProviderRegistry.all() do
        assert modules[entry.id] == entry.auth_module,
               "auth_modules/0 mismatch for #{entry.id}"
      end
    end
  end

  describe "auth_module_for!/1" do
    test "returns the correct module for each registered provider" do
      for entry <- ProviderRegistry.all() do
        assert entry.auth_module == ProviderRegistry.auth_module_for!(entry.id)
      end
    end

    test "raises for unknown provider" do
      assert_raise ArgumentError, fn ->
        ProviderRegistry.auth_module_for!(:nonexistent)
      end
    end
  end

  describe "reqllm_modules/0" do
    test "includes the ReqLLM module for each registered provider" do
      modules = ProviderRegistry.reqllm_modules()

      for entry <- ProviderRegistry.all() do
        assert entry.reqllm_module in modules,
               "reqllm_modules/0 missing #{inspect(entry.reqllm_module)} for #{entry.id}"
      end
    end
  end

  describe "oauth_provider_map/0" do
    test "maps base_prefix to oauth_prefix for each registered provider" do
      map = ProviderRegistry.oauth_provider_map()
      assert is_map(map)

      for entry <- ProviderRegistry.all() do
        assert map[entry.base_prefix] == entry.oauth_prefix,
               "oauth_provider_map/0 mismatch for #{entry.id}"
      end
    end

    test "keys and values are all strings" do
      for {k, v} <- ProviderRegistry.oauth_provider_map() do
        assert is_binary(k)
        assert is_binary(v)
      end
    end
  end

  describe "oauth_capable_providers/0" do
    test "returns a MapSet containing all registered provider IDs" do
      set = ProviderRegistry.oauth_capable_providers()
      assert %MapSet{} = set

      for entry <- ProviderRegistry.all() do
        assert MapSet.member?(set, entry.id)
      end

      assert MapSet.size(set) == length(ProviderRegistry.all())
    end
  end

  describe "flow_type/1" do
    test "returns the correct flow_type for each registered provider" do
      for entry <- ProviderRegistry.all() do
        assert ProviderRegistry.flow_type(entry.id) == entry.flow_type
      end
    end

    test "raises for unknown provider" do
      assert_raise ArgumentError, fn ->
        ProviderRegistry.flow_type(:nonexistent)
      end
    end
  end

  describe "oauth_prefix?/1" do
    test "returns true for oauth-prefixed model string" do
      for entry <- ProviderRegistry.all() do
        assert ProviderRegistry.oauth_prefix?("#{entry.oauth_prefix}:some-model")
      end
    end

    test "returns false for base-prefixed model string" do
      for entry <- ProviderRegistry.all() do
        refute ProviderRegistry.oauth_prefix?("#{entry.base_prefix}:some-model")
      end
    end

    test "returns false for unknown prefix" do
      refute ProviderRegistry.oauth_prefix?("some_unknown:model")
      refute ProviderRegistry.oauth_prefix?("random-string")
    end

    test "returns false for partial match without colon" do
      refute ProviderRegistry.oauth_prefix?("anthropic_oauth")
    end
  end

  describe "oauth_base_prefix?/1" do
    test "returns true for base-prefixed model from OAuth-capable provider" do
      for entry <- ProviderRegistry.all() do
        assert ProviderRegistry.oauth_base_prefix?("#{entry.base_prefix}:some-model")
      end
    end

    test "returns false for oauth-prefixed model string" do
      for entry <- ProviderRegistry.all() do
        refute ProviderRegistry.oauth_base_prefix?("#{entry.oauth_prefix}:some-model")
      end
    end

    test "returns false for unknown prefix" do
      refute ProviderRegistry.oauth_base_prefix?("some_unknown:model")
      refute ProviderRegistry.oauth_base_prefix?("random")
    end
  end

  describe "env_var/1" do
    test "returns env var name for each registered provider" do
      for entry <- ProviderRegistry.all() do
        assert entry.env_var == ProviderRegistry.env_var(entry.id)
      end
    end

    test "returns nil for unknown provider" do
      assert nil == ProviderRegistry.env_var(:nonexistent)
    end
  end

  describe "base_prefix/1" do
    test "returns base prefix string for each registered provider" do
      for entry <- ProviderRegistry.all() do
        assert entry.base_prefix == ProviderRegistry.base_prefix(entry.id)
      end
    end

    test "raises for unknown provider" do
      assert_raise ArgumentError, fn ->
        ProviderRegistry.base_prefix(:nonexistent)
      end
    end
  end

  describe "registry consistency" do
    test "oauth_prefix always ends with _oauth" do
      for entry <- ProviderRegistry.all() do
        assert String.ends_with?(entry.oauth_prefix, "_oauth"),
               "#{entry.id} oauth_prefix #{entry.oauth_prefix} doesn't end with _oauth"
      end
    end

    test "oauth_prefix starts with base_prefix" do
      for entry <- ProviderRegistry.all() do
        assert String.starts_with?(entry.oauth_prefix, entry.base_prefix),
               "#{entry.id} oauth_prefix #{entry.oauth_prefix} doesn't start with base_prefix #{entry.base_prefix}"
      end
    end

    test "no duplicate IDs" do
      ids = ProviderRegistry.provider_ids()
      assert ids == Enum.uniq(ids)
    end

    test "no duplicate oauth_prefixes" do
      prefixes = Enum.map(ProviderRegistry.all(), & &1.oauth_prefix)
      assert prefixes == Enum.uniq(prefixes)
    end
  end
end
