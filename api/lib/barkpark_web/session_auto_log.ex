defmodule BarkparkWeb.SessionAutoLog do
  @moduledoc """
  Server-side session auto-log (session-handoff design v1.5, §5b).

  v1 of the session handoff left the event trail to agent discipline: a human
  or an agent had to remember to run `bp session log` after every milestone.
  §5b removes that reliance for the two milestones **Barkpark itself
  witnesses** — a task close and a paper publish. When the request carries a
  session slug header, the endpoint appends `{ts, kind, ref}` to that
  session's `content["events"]` itself, through the one append-only writer
  `Barkpark.Content.Sessions.append_event/5`. Git pushes stay agent-logged:
  Barkpark never sees them.

  ## THE HEADER NAME IS NOT THE ONE THE DESIGN SPELLED

  §5b names the header `X-Barkpark-Session`. That name was **already taken on
  main**, by something whose confidentiality is load-bearing: the claim-session
  discriminator (`Barkpark.Tasks.SessionId.derive/2`, read at
  `BarkparkWeb.TasksController.session_id/2`). There the header carries a
  SECRET the server never stores — it HMACs it under the endpoint secret and
  the calling token, and the one-way result lands on `claim.session`, so a peer
  cannot replay a session id copied off the ledger.

  A session SLUG is the opposite of a secret: it is the document's public
  `doc_id`, printed by `bp session open`, readable by anyone who can read the
  session. Sending the slug on `x-barkpark-session` would feed a PUBLIC,
  guessable value into the claim discriminator as if it were the secret,
  turning "a peer's session cannot be replayed" into "any reader of the ledger
  can mint your claim session id". So this slice uses a DISTINCT header,
  `X-Barkpark-Session-Slug`, and leaves the existing header's meaning
  untouched. Both may ride the same request; they are different things.

  ## Never blocks the milestone

  The design's error contract is explicit: "never fail a task close or a push
  because the session log call failed — warn loudly and continue." So every
  return here is informational and every caller discards it. A missing header,
  an unknown slug, a lost CAS, or an outright exception all end the same way:
  a `Logger.warning` and the primary write's own response, unchanged.

  ## Tenancy: FAIL CLOSED, off the document that was just written

  `doc_scope_opts/1` reads the workspace straight off the `%Document{}` the
  milestone produced — the closed task, the published paper — and that is the
  ONLY scope the session lookup runs under. Not a re-resolution of the request:
  a re-derivation is a second copy of a rule, and this one must agree with the
  primary write exactly or it is either a refusal of honest work or a
  cross-tenant write.

  The read path is `append_event/5` -> `Content.get_blocks_doc/4` ->
  `Content.Query.get_document/4` -> `Scope.scope_to_workspace_or_global/3`.
  That helper is on the WIDENING side of the sign (see `Barkpark.Content.Scope`):
  a `nil` workspace_id there is an EXPLICIT cross-tenant read, every tenant's
  rows. So a nil is never passed. A document with no workspace of its own gets
  the `:shared_only` sentinel, which pins the lookup to `workspace_id IS NULL` —
  the shared layer — rather than opening it to all of them.

  `project_id` is deliberately NOT narrowed. The workspace is the hard tenant
  boundary; a project is a partition inside one, and a session record spans an
  agent's work across the projects of its workspace. Narrowing to the closed
  task's project would refuse an honest log, without fencing anything a
  workspace member could not already read.

  The rule in one sentence: **a milestone may only auto-log to a session in the
  same workspace as the document the milestone wrote**, and an unresolvable
  slug is a logged no-op, never a widened search.
  """

  require Logger

  import Plug.Conn, only: [get_req_header: 2]

  @header "x-barkpark-session-slug"

  @doc """
  The request header carrying the open session's slug.

  Deliberately NOT `x-barkpark-session` — see the moduledoc. Anything that
  looks for the auto-log header must read it from here, so the two header
  names can never drift apart in a copy.
  """
  @spec header() :: String.t()
  def header, do: @header

  @doc "The open session's slug for this request, or `nil` when none was sent."
  @spec session_slug(Plug.Conn.t()) :: String.t() | nil
  def session_slug(%Plug.Conn{} = conn) do
    case get_req_header(conn, @header) do
      [value | _] when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          slug -> slug
        end

      _ ->
        nil
    end
  end

  def session_slug(_), do: nil

  @doc """
  The session-lookup scope for a milestone on `doc` — see the moduledoc.

  Workspace-exact, project-agnostic, and fail-closed on a document with no
  workspace (`:shared_only`, never `nil`: nil is the cross-tenant read).
  """
  @spec doc_scope_opts(map()) :: keyword()
  def doc_scope_opts(%{workspace_id: workspace_id}) when is_binary(workspace_id),
    do: [workspace_id: workspace_id]

  def doc_scope_opts(_doc), do: [workspace_id: :shared_only]

  @doc """
  Append `{ts, kind, ref}` to the header-named session's trail, if a session
  was named at all.

  Returns `:no_session` (no header — the overwhelmingly common case, and a
  total no-op), `{:logged, count}` on a successful append, or
  `{:skipped, reason}` when a session was named but the append did not land.
  The return exists for tests; no caller may branch a response on it.
  """
  @spec maybe_log(Plug.Conn.t(), String.t(), String.t() | nil, String.t() | nil, keyword()) ::
          :no_session | {:logged, non_neg_integer()} | {:skipped, atom()}
  def maybe_log(conn, kind, ref, dataset \\ nil, scope_opts \\ []) do
    case session_slug(conn) do
      nil -> :no_session
      slug -> append(slug, kind, ref, dataset, scope_opts)
    end
  end

  defp append(slug, kind, ref, dataset, scope_opts) do
    dataset = dataset || Barkpark.Content.paper_default_dataset()

    case Barkpark.Content.Sessions.append_event(
           slug,
           kind,
           %{"ref" => ref},
           dataset,
           scope_opts || []
         ) do
      {:ok, %{count: count}} ->
        {:logged, count}

      {:error, reason} ->
        warn(slug, kind, ref, reason)
        {:skipped, reason}
    end
  rescue
    error ->
      # The milestone has ALREADY committed by the time we get here; an
      # exception raised while logging it must not turn a landed close into a
      # 500. Loud in the log, invisible on the wire.
      warn(slug, kind, ref, Exception.message(error))
      {:skipped, :exception}
  end

  defp warn(slug, kind, ref, reason) do
    Logger.warning(
      "session auto-log skipped: session=#{inspect(slug)} kind=#{kind} " <>
        "ref=#{inspect(ref)} reason=#{inspect(reason)} — the milestone itself is unaffected"
    )
  end
end
