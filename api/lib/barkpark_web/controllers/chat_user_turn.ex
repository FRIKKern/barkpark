defmodule BarkparkWeb.ChatUserTurn do
  @moduledoc """
  The user's turn on `POST /v1/chat/sessions/:id/messages`: the body's
  `attachments` list, the content the runtime receives, and the user row the
  transcript keeps.

  The body is `{content, attachments?}`. `attachments` is a list of 0 to 4
  distinct ids, each the sha256 content address of an image already stored for
  THIS session through `POST /v1/chat/sessions/:id/attachments`.

  Two steps, in this order in the controller:

    * `validate_ids/1` checks the SHAPE before the session is looked up, like
      every other body check. Nothing is read.
    * `resolve/3` runs only after the tenant oracle (`fetch_scoped/2`) has
      returned the session. Each id is read through
      `Attachments.fetch(session.id, id)`, which looks only under that
      session's own store directory. An id stored for another session, in this
      workspace or another, is therefore the same miss as an id stored nowhere,
      and every miss answers one fixed message that never echoes the id.

  With no attachments the content stays the caller's string, exactly what the
  runtime received before attachments existed. With attachments it becomes the
  block list the Studio composer sends (`Attachments.user_content/2`), and the
  user row carries the same `Attachments.pointer_json/1` pointers a Studio-sent
  row does, so `GET /v1/chat/sessions/:id` and the event stream's history rows
  project them as references.
  """

  require Logger

  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Attachments

  # The Studio composer's cap (its allow_upload max_entries).
  @max_attachments 4

  @not_held "attachments names an id this session does not hold"

  @media_types Attachments.media_types()

  @doc "The most attachments one message may name."
  @spec max_attachments() :: pos_integer()
  def max_attachments, do: @max_attachments

  @doc """
  The shape check on the body's `attachments` value. Absent (`nil`) is no
  attachments. Anything else must be a list of at most four distinct
  well-formed ids.
  """
  @spec validate_ids(term()) :: {:ok, [String.t()]} | {:error, String.t()}
  def validate_ids(nil), do: {:ok, []}

  def validate_ids(ids) when is_list(ids) do
    cond do
      length(ids) > @max_attachments ->
        {:error, "attachments exceeds #{@max_attachments} entries"}

      not Enum.all?(ids, &Attachments.valid_id?/1) ->
        {:error, "attachments entries must be 64-character lowercase sha256 hex ids"}

      length(Enum.uniq(ids)) != length(ids) ->
        {:error, "attachments must not repeat an id"}

      true ->
        {:ok, ids}
    end
  end

  def validate_ids(_), do: {:error, "attachments must be a list of attachment ids"}

  @doc """
  The turn for `session_id`: `%{content, metadata}`, where `content` goes to
  `Runtime.send_turn/3` and `metadata` onto the persisted user row. Call it
  only with a session the tenant oracle returned.
  """
  @spec resolve(String.t(), String.t(), [String.t()]) ::
          {:ok, %{content: String.t() | [map()], metadata: map()}} | {:error, String.t()}
  def resolve(_session_id, text, []), do: {:ok, %{content: text, metadata: %{"origin" => "api"}}}

  def resolve(session_id, text, ids) do
    with {:ok, attachments} <- fetch_all(session_id, ids) do
      {:ok,
       %{
         content: Attachments.user_content(text, attachments),
         metadata: %{
           "origin" => "api",
           "attachments" => Enum.map(attachments, &Attachments.pointer_json/1)
         }
       }}
    end
  end

  # Every id must read back as one of the accepted images. `fetch/2` re-sniffs
  # the bytes, so a file in the store that is not one (which `put/2` never
  # writes) is the same miss as an absent one.
  defp fetch_all(session_id, ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case Attachments.fetch(session_id, id) do
        {:ok, %{media_type: type} = attachment} when type in @media_types ->
          {:cont, {:ok, [attachment | acc]}}

        _ ->
          {:halt, {:error, @not_held}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  @doc """
  Append the caller's turn as a `role:"user"` row, so the session's replayable
  history carries the human side (the Studio composer persists its own rows).
  `metadata` is `resolve/3`'s: `origin: "api"` plus any attachment pointers.

  Best-effort: the turn has already been dispatched, so a persist error is
  logged and never turns a live send into an error.
  """
  @spec persist(String.t(), String.t(), map()) :: :ok
  def persist(session_id, text, metadata) do
    case StudioChat.append_message(session_id, %{
           role: "user",
           source_markdown: text,
           metadata: metadata
         }) do
      {:ok, _message} ->
        :ok

      {:error, reason} ->
        Logger.warning("chat transport: failed to persist user turn: #{inspect(reason)}")
        :ok
    end
  end
end
