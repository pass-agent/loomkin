defmodule Loomkin.Signals.System do
  @moduledoc "System-domain signals: repo updates, config, cluster, metrics, auth."

  defmodule RepoUpdated do
    use Jido.Signal,
      type: "system.repo.updated",
      schema: []
  end

  defmodule ConfigLoaded do
    use Jido.Signal,
      type: "system.config.loaded",
      schema: []
  end

  defmodule NodeJoined do
    use Jido.Signal,
      type: "system.cluster.node_joined",
      schema: [
        node: [type: :atom, required: true]
      ]
  end

  defmodule NodeLeft do
    use Jido.Signal,
      type: "system.cluster.node_left",
      schema: [
        node: [type: :atom, required: true]
      ]
  end

  defmodule MetricsUpdated do
    use Jido.Signal,
      type: "system.metrics.updated",
      schema: []
  end

  defmodule AuthConnected do
    use Jido.Signal,
      type: "system.auth.connected",
      schema: [
        provider: [type: :atom, required: true]
      ]
  end

  defmodule AuthDisconnected do
    use Jido.Signal,
      type: "system.auth.disconnected",
      schema: [
        provider: [type: :atom, required: true]
      ]
  end

  defmodule AuthRefreshed do
    use Jido.Signal,
      type: "system.auth.refreshed",
      schema: [
        provider: [type: :atom, required: true]
      ]
  end

  defmodule AuthRefreshFailed do
    use Jido.Signal,
      type: "system.auth.refresh_failed",
      schema: [
        provider: [type: :atom, required: true]
      ]
  end
end
