defmodule Loomkin.Security.Redactor do
  @moduledoc """
  Multi-layer secret redaction for agent communications.

  Detects and replaces API keys, tokens, connection strings, and other
  sensitive patterns in text before it reaches PubSub, logs, or LLM prompts.

  Redaction is disabled in the `:test` environment by default. Tests can
  opt in by calling `enable/0` or setting application config.
  """

  @replacement "[REDACTED]"

  # Built-in patterns — order matters for overlapping matches.
  # Each entry is {regex, label} for full-match replacement, or
  # {regex, label, replacement} with backreferences for partial replacement.
  @builtin_patterns [
    # OpenAI / Anthropic / Stripe sk- keys (at least 20 chars after prefix)
    {~r/sk-[A-Za-z0-9_\-]{20,}/, "sk-* key"},
    # AWS access key IDs
    {~r/AKIA[0-9A-Z]{16}/, "AWS access key"},
    # AWS secret keys (40-char base64ish following common env patterns)
    {~r/(?i)(AWS_SECRET_ACCESS_KEY[=: ]["']?)([A-Za-z0-9\/+=]{40})/, "AWS secret key",
     "\\1[REDACTED]"},
    # GitHub tokens (classic and fine-grained)
    {~r/gh[pousr]_[A-Za-z0-9_]{36,}/, "GitHub token"},
    # Bearer tokens in header-like strings
    {~r/(?i)bearer\s+[A-Za-z0-9\-._~+\/]+=*/, "Bearer token"},
    # Connection strings with embedded passwords (postgres, mysql, redis, mongodb)
    {~r/(?i)((?:postgres(?:ql)?|mysql|redis|mongodb(?:\+srv)?|amqp):\/\/[^:]+:)([^@\s]{4,})(@)/,
     "connection string password", "\\1[REDACTED]\\3"},
    # Generic "password" / "secret" / "token" / "api_key" assignments
    {~r/(?i)((?:password|secret|token|api_key|apikey|api-key|access_key|secret_key)\s*[=:]\s*["'])([^"']{8,})(["'])/,
     "key-value secret", "\\1[REDACTED]\\3"},
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
    Regex.replace(regex, text, @replacement)
    |> do_redact(rest)
  end

  defp do_redact(text, [{regex, _label, replacement} | rest]) do
    Regex.replace(regex, text, replacement)
    |> do_redact(rest)
  end
end
