defmodule Loomkin.Relay do
  @moduledoc """
  Relay system for connecting local Loomkin daemons to the deployed cloud instance.

  Enables mobile and remote clients to drive agents running on a user's local machine
  through a cloud relay. The local daemon connects outbound to the cloud (no port
  forwarding needed), and the cloud routes commands between mobile clients and daemons.

  ## Architecture

      Phone (mobile web / native)
          │
          │  REST + WebSocket
          ▼
      Deployed Loomkin (Fly) ← relay hub
          │
          │  Persistent WebSocket (outbound from local machine)
          ▼
      Local Loomkin Daemon (laptop)
          ├── filesystem access
          ├── agents running
          ├── workspace server
          └── git, tools, everything

  ## Protocol

  All messages are JSON-encoded with a `type` field for routing:

  ### Daemon → Cloud
  - `register` — announce machine + workspaces on connect
  - `heartbeat` — keep-alive (every 15s)
  - `command_response` — response to a relayed command
  - `event` — stream agent/session events to cloud
  - `workspace_update` — workspace came online/offline, agent count changed

  ### Cloud → Daemon
  - `command` — relayed command from mobile client
  - `heartbeat_ack` — confirm heartbeat received

  See `Loomkin.Relay.Protocol` for message struct definitions.
  """
end
