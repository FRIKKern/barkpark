defmodule Barkpark.Mailer do
  @moduledoc """
  Transactional mailer for core auth (email verification + password reset).

  Adapter is config-selected per environment (`config :barkpark, #{inspect(__MODULE__)}`):
  dev → `Swoosh.Adapters.Local` (the `/dev/mailbox`), test → `Swoosh.Adapters.Test`
  (in-process capture), prod → SMTP via `gen_smtp` (wired in runtime.exs). The
  Swoosh API client is disabled (config.exs) so no HTTP client dep is pulled.
  """
  use Swoosh.Mailer, otp_app: :barkpark
end
