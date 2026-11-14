defmodule BarkparkWeb.ChatUserTurn do
  @moduledoc """
  The user's turn on `POST /v1/chat/sessions/:id/messages`: the body's
  `attachments` list, the content the runtime receives, and the user row the
  transcript keeps.

  The body is `{content, attachments?}`. `attachments` is a list of 0 to 4
  entries naming distinct attachments already stored for THIS session through
  `POST /v1/chat/sessions/:id/attachments`. An entry is the sha256 content
  address as a string, or `{"id": sha256, "name": name}`
  (`/papers/chat-host-file-attachments-plan`). An image may have a name; a
  text file or PDF must have one. A name is refused, never cleaned, unless
  `AttachmentName.valid?/1` holds.

  Two steps, in this order in the controller:

    * `validate_ids/1` checks the SHAPE before the session is looked up, like
      every other body check: the ids, the keys and the names. Nothing is read.
    * `resolve/3` runs only after the tenant oracle (`fetch_scoped/2`) has
      returned the session. Each id is read through
      `Attachments.fetch(session.id, id)`, which looks only under that
      session's own store directory. An id stored for another session, in this
      workspace or another, is therefore the same miss as an id stored nowhere,
      and every miss answers one fixed message that never echoes the id. A
      file it does hold needs a name and a `registered_host` session: a managed
      claude or codex session would get a document block it may not read.

  With no attachments the content stays the caller's string, exactly what the
  runtime received before attachments existed. With attachments it becomes the
  block list the Studio composer sends (`Attachments.user_content/2`), plus a
  document block titled with the name for each file, and the user row carries
  the same `Attachments.pointer_json/1` pointers a Studio-sent row does (with
  `name` when one was given), so `GET /v1/chat/sessions/:id` and the event
  stream's history rows project them as references.
  """

  require Logger

  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.{AttachmentName, Attachments}

  # The Studio composer's cap (its allow_upload max_entries).
  @max_attachments 4

  @not_held "attachments names an id this session does not hold"
  @file_needs_name "attachments names a text or PDF file without a name"
  @file_needs_host "attachments names a text or PDF file, which only a registered_host session takes"
  @bad_name "attachments name must be 1 to #{AttachmentName.max_bytes()} bytes of UTF-8 with no control or format character, no / or \\, and not . or .."

  @media_types Attachments.media_types()
  @file_types Attachments.file_types()

  @typedoc "One `attachments` entry after the shape check."
  @type entry :: %{id: String.t(), name: String.t() | nil}

  @doc "The most attachments one message may name."
  @spec max_attachments() :: pos_integer()
  def max_attachments, do: @max_attachments

  @doc """
  The shape check on the body's `attachments` value. Absent (`nil`) is no
  attachments. Anything else must be a list of at most four entries, each a
  well-formed id or an `{"id", "name"}` object with a valid name, and no id
  may repeat.
  """
  @spec validate_ids(term()) :: {:ok, [entry()]} | {:error, String.t()}
  def validate_ids(nil), do: {:ok, []}

  def validate_ids(entries) when is_list(entries) do
    if length(entries) > @max_attachments do
      {:error, "attachments exceeds #{@max_attachments} entries"}
    else
      with {:ok, parsed} <- parse_entries(entries) do
        ids = Enum.map(parsed, & &1.id)

        if length(Enum.uniq(ids)) == length(ids),
          do: {:ok, parsed},
          else: {:error, "attachments must not repeat an id"}
      end
    end
  end

  def validate_ids(_), do: {:error, "attachments must be a list of attachment ids"}

  defp parse_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case parse_entry(entry) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp parse_entry(entry) when is_binary(entry), do: parse_entry(%{"id" => entry})

  defp parse_entry(%{"id" => id} = entry) do
    cond do
      Map.keys(entry) -- ["id", "name"] != [] ->
        {:error, "attachments entries may only carry id and name"}

      not Attachments.valid_id?(id) ->
        {:error, "attachments entries must be 64-character lowercase sha256 hex ids"}

      Map.has_key?(entry, "name") and not AttachmentName.valid?(entry["name"]) ->
        {:error, @bad_name}

      true ->
        {:ok, %{id: id, name: entry["name"]}}
    end
  end

  defp parse_entry(_),
    do: {:error, "attachments entries must be sha256 hex ids or {\"id\", \"name\"} objects"}

  @doc """
  The turn for `session`: `%{content, metadata}`, where `content` goes to
  `Runtime.send_turn/3` and `metadata` onto the persisted user row. Call it
  only with a session the tenant oracle returned, and with the entries
  `validate_ids/1` returned.
  """
  @spec resolve(StudioChat.Session.t(), String.t(), [entry()]) ::
          {:ok, %{content: String.t() | [map()], metadata: map()}} | {:error, String.t()}
  def resolve(_session, text, []), do: {:ok, %{content: text, metadata: %{"origin" => "api"}}}

  def resolve(%StudioChat.Session{} = session, text, entries) do
    with {:ok, attachments} <- fetch_all(session, entries) do
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

  # Every id must read back, under this session's own store, as an image or as
  # a file. `fetch/2` re-sniffs the bytes, so anything else is the same miss as
  # an absent id. Only an id the session holds can say it is a file, so the two
  # file refusals reveal nothing about another session.
  defp fetch_all(session, entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case Attachments.fetch(session.id, entry.id) do
        {:ok, %{media_type: type} = attachment} when type in @media_types ->
          {:cont, {:ok, [Map.put(attachment, :name, entry.name) | acc]}}

        {:ok, %{media_type: type}} when type in @file_types and is_nil(entry.name) ->
          {:halt, {:error, @file_needs_name}}

        {:ok, %{media_type: type}}
        when type in @file_types and session.execution_target != "registered_host" ->
          {:halt, {:error, @file_needs_host}}

        {:ok, %{media_type: type} = attachment} when type in @file_types ->
          {:cont, {:ok, [Map.put(attachment, :name, entry.name) | acc]}}

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
