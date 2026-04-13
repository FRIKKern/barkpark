defmodule BarkparkWeb.Presence do
  use Phoenix.Presence,
    otp_app: :barkpark,
    pubsub_server: Barkpark.PubSub
end
