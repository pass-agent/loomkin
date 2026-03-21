defmodule Loomkin.Security.Redactor do
  @moduledoc """
  Multi-layer secret redaction for agent communications.

  Detects and replaces API keys, tokens, connection strings, and other
  sensitive patterns in text before it reaches PubSub, logs, or LLM prompts.

  Redaction is disabled in the `:test` environment by default. Tests can
  opt in by calling `enable/0` or setting application config.
  """

  @replacement "[REDACTED]"

  # Built-in patterns: {regex, label} — order matters for overlapping matches.
  # These cover the most common API key and token formats.
  @builtin_patterns [
    # OpenAI / Anthropic / Stripe sk- keys (at least 20 chars after prefix)
    {~r/sk-[A-Za-z0-9_\-]{20,}/, "sk-* key"},
    # AWS access key IDs
    {~r/AKIA[0-9A-Z]{16}/, "AWS access key"},
    # AWS secret keys (40-char base64ish following common env patterns)
    {~r/(?<=AWS_SECRET_ACCESS_KEY[=: ]["']?)[A-Za-z0-9\/+=]{40}/, "AWS secret key"},
    # GitHub tokens (classic and fine-grained)
    {~r/gh[pousr]_[A-Za-z0-9_]{36,}/, "GitHub token"},
    # Bearer tokens in header-like strings
    {~r/(?i)bearer\s+[A-Za-z0-9\-._~+\/]+=*/, "Bearer token"},
    # Connection strings with embedded passwords (postgres, mysql, redis, mongodb)
    {~r/(?i)(postgres(?:ql)?|mysql|redis|mongodb(?:\+srv)?|amqp):\/\/[^:]+:([^@\s]{4,})@/,
     "connection string password"},
    # Generic "password" / "secret" / "token" / "api_key" assignments
    {~r/(?i)(?:password|secret|token|api_key|apikey|api-key|access_key|secret_key)\s*[=:]\s*["']([^"']{8,})["']/,
     "key-value secret"},
    # Slack tokens
    {~r/xox[bpors]-[A-Za-z0-9\-]{10,}/, "Slack token"},
    # Private key blocks
    {~r/-----BEGIN\s+(?:RSA\s+)?PRIVATE\s+KEY-----[\s\S]*?-----END\s+(?:RSA\s+)?PRIVATE\s+KEY-----/,
     "private key"}
  ]

  @doc """
  Redact secrets from the given text.

  Returns the text with detected secrets replaced by `[REDACTED]`.
  Returns non-string inputs unchanged.
  """
  @spec redact(binary()) :: binary()
  @spec redact(term()) :: term()
  def redact(text) when is_binary(text) do
    if enabled?() do
      do_redact(text, patterns())
    else
      text
    end
  end

  def redact(other), do: other

  @doc """
  Enable redaction in the current environment (useful for test opt-in).
  """
  def enable do
    Application.put_env(:loomkin, :redaction_enabled, true)
  end

  @doc """
  Disable redaction in the current environment.
  """
  def disable do
    Application.put_env(:loomkin, :redaction_enabled, false)
  end

  @doc """
  Returns whether redaction is currently enabled.
  """
  def enabled? do
    case Application.get_env(:loomkin, :redaction_enabled) do
      nil -> Application.get_env(:loomkin, :env, :dev) != :test
      val -> val
    end
  end

  # --- Internal ---

  defp patterns do
    custom = Application.get_env(:loomkin, :redaction_patterns, [])
    @builtin_patterns ++ custom
  end

  defp do_redact(text, []), do: text

  defp do_redact(text, [{regex, _label} | rest]) do
    text
    |> apply_pattern(regex)
    |> do_redact(rest)
  end

  # For patterns with capturing groups, redact only the captured group.
  # For patterns without groups, redact the entire match.
  defp apply_pattern(text, regex) do
    case Regex.names(regex) do
      [] ->
        if Regex.source(regex) |> String.contains?("(") do
          # Has unnamed capturing groups — redact the last group
          Regex.replace(regex, text, fn full_match ->
            case Regex.run(regex, full_match, capture: :all) do
              [_full | groups] when groups != [] ->
                secret = List.last(groups)
                String.replace(full_match, secret, @replacement, global: false)

              _ ->
                @replacement
            end
          end)
        else
          Regex.replace(regex, text, @replacement)
        end

      _named ->
        Regex.replace(regex, text, @replacement)
    end
  end
end
