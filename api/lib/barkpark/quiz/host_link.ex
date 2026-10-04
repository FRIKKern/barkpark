defmodule Barkpark.Quiz.HostLink do
  @moduledoc """
  Signed host links for `/quiz/host` (owner ruling #23, 2026-10-03,
  task-f5d0ce5677e1c1d0).

  `/quiz/host/:pin?quiz=<id>` binds a stored quiz to a room, and the host of a
  room receives every answer and the quiz's answer key. The `quiz` type is
  private (the document stores the correct answer inline), so binding one is
  an authoring act. Before this ruling, anyone who knew a published quiz's id
  could open a room as its host.

  A room now binds `?quiz=` only when the request carries one of:

    * `host=<token>` — a link minted here, from Studio (the quiz plugin's
      "Host this quiz" document action). The token names the quiz it was
      minted for and expires after `max_age/0` seconds.
    * a signed-in Studio session whose token may WRITE the Default workspace,
      the only workspace `/quiz/host` reads quizzes from
      (`Barkpark.Quiz.Content.load_question/2`).

  Everyone else gets the room's default question, never the named quiz.

  The token is a `Phoenix.Token` signed with the endpoint secret. Its
  `signed_at` is floored to the hour, so the link Studio renders stays the
  same within an hour instead of changing on every LiveView render.
  """

  alias Barkpark.Auth
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @salt "quiz host link v1"
  @max_age 24 * 60 * 60

  @doc "Seconds a minted host link stays valid (24 hours)."
  @spec max_age() :: pos_integer()
  def max_age, do: @max_age

  @doc "Mint a host token for `quiz_id`."
  @spec sign(String.t(), keyword()) :: String.t()
  def sign(quiz_id, opts \\ []) when is_binary(quiz_id) do
    now = Keyword.get(opts, :now, System.system_time(:second))
    signed_at = div(now, 3600) * 3600

    Phoenix.Token.sign(BarkparkWeb.Endpoint, @salt, %{"q" => published_id(quiz_id)},
      signed_at: signed_at
    )
  end

  @doc """
  The Studio "Host this quiz" path. `/quiz/host/new` makes the host page pick
  a fresh PIN and keep the query, so the link itself names no room.
  """
  @spec path(String.t(), keyword()) :: String.t()
  def path(quiz_id, opts \\ []) when is_binary(quiz_id) do
    id = published_id(quiz_id)
    "/quiz/host/new?" <> URI.encode_query(%{"quiz" => id, "host" => sign(id, opts)})
  end

  @doc """
  Check a host token against the quiz it claims to bind.

  `{:error, :missing}` when no token was sent, `{:error, :expired}` past
  `max_age/0`, `{:error, :invalid}` for a forged or malformed token, and
  `{:error, :wrong_quiz}` when the token was minted for another quiz.
  """
  @spec verify(term(), String.t()) ::
          :ok | {:error, :missing | :expired | :invalid | :wrong_quiz}
  def verify(token, quiz_id) when is_binary(token) and token != "" and is_binary(quiz_id) do
    case Phoenix.Token.verify(BarkparkWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, %{"q" => q}} ->
        if q == published_id(quiz_id), do: :ok, else: {:error, :wrong_quiz}

      {:error, :expired} ->
        {:error, :expired}

      _ ->
        {:error, :invalid}
    end
  end

  def verify(_token, _quiz_id), do: {:error, :missing}

  @doc """
  May the browser session behind `session` host stored quizzes without a link?
  True only for a Studio session token that may write the Default workspace.
  """
  @spec signed_in_author?(map()) :: boolean()
  def signed_in_author?(%{"api_token" => raw}) when is_binary(raw) and raw != "" do
    with {:ok, token} <- Auth.verify_token(raw),
         %{id: ws_id} when is_binary(ws_id) <- Barkpark.Tenancy.get_default_workspace() do
      TenancyAuth.authorize(token, ws_id, :write) == :ok
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  def signed_in_author?(_session), do: false

  defp published_id("drafts." <> id), do: id
  defp published_id(id), do: id
end
