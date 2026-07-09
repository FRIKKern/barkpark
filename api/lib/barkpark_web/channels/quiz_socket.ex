defmodule BarkparkWeb.QuizSocket do
  @moduledoc """
  Anonymous realtime socket for hyperquiz players. Quiz players are ANONYMOUS
  (no account), but their identity is SERVER-AUTHORITATIVE: `connect/3` mints a
  random `player_id` and the channel hands back a `Phoenix.Token`-signed copy on
  join. A reconnecting client presents that signed token (`%{"token" => ...}`)
  and we honor the id inside it; a forged/absent/expired token gets a fresh id.
  This closes the P2-review spoofing gap (a client can no longer claim an
  arbitrary id) while giving stable identity across reconnects (P6). Carries
  `QuizChannel` on `"quiz:room:<pin>"`.
  """
  use Phoenix.Socket

  channel "quiz:room:*", BarkparkWeb.QuizChannel

  @salt "hyperquiz player id"
  @max_age 86_400

  @impl true
  def connect(params, socket, _connect_info) do
    player_id =
      case params["token"] && verify_token(params["token"]) do
        {:ok, id} -> id
        _ -> Ecto.UUID.generate()
      end

    {:ok, assign(socket, :player_id, player_id)}
  end

  @impl true
  def id(socket), do: "quiz_socket:" <> socket.assigns.player_id

  @doc "Sign a player_id into a token the client stores and presents on reconnect."
  @spec sign(String.t()) :: String.t()
  def sign(player_id), do: Phoenix.Token.sign(BarkparkWeb.Endpoint, @salt, player_id)

  @doc "Verify a player-id token; `{:ok, id}` or `{:error, reason}`."
  @spec verify_token(String.t()) :: {:ok, String.t()} | {:error, term()}
  def verify_token(token),
    do: Phoenix.Token.verify(BarkparkWeb.Endpoint, @salt, token, max_age: @max_age)
end
