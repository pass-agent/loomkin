ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Loomkin.Repo, :manual)

# Skip LLM-dependent tests by default — they depend on external API state.
# Run with: mix test --include llm_dependent
ExUnit.configure(exclude: [:llm_dependent, :pending])

# Mox mock definitions for channel adapter tests
Mox.defmock(Loomkin.MockAdapter, for: Loomkin.Channels.Adapter)
Mox.defmock(Loomkin.MockTelegex, for: Loomkin.Channels.TelegexBehaviour)
Mox.defmock(Loomkin.MockNostrumApi, for: Loomkin.Channels.NostrumApiBehaviour)
