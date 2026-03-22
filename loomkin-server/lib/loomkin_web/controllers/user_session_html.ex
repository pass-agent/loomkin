defmodule LoomkinWeb.UserSessionHTML do
  use LoomkinWeb, :html

  embed_templates "user_session_html/*"

  defp local_mail_adapter? do
    Application.get_env(:loomkin, Loomkin.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
