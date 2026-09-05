defmodule BarkparkWeb.AnonPerspective do
  @moduledoc """
  Single source of truth for the anonymous-caller perspective invariant.

  EVERY plain anonymous caller (no api token, no preview JWT, not an `:edit`
  share) is pinned to the `:published` perspective: a `?perspective=drafts|raw`
  query param is IGNORED so a tokenless reader can never pull unpublished/draft
  content. This mirrors, verbatim, the guard `QueryController` has always
  enforced — it exists so the search controllers (federated + document search)
  enforce the SAME invariant instead of trusting the raw param
  (`error-emitters-duplicated`: the guard must live on every anonymous read
  path, not just `/query`).

  A token, a preview token (`forced_perspective`) or an `:edit` share falls
  through to the unchanged forced/param logic — an `:edit` share is deliberately
  exempt because it is an anonymous *editing* surface whose draft visibility is
  part of that contract.

  EXCEPTION to the token fall-through (stw7-backlog-drafts-clamp-gap, charter
  D60/D61): a token whose permissions CARRY `"public-read"` is pinned exactly
  like an anonymous caller. Public-read is the browser-shipped site credential —
  it exists to read the published corpus, never drafts. The membership check
  (`"public-read" in permissions`) is load-bearing: `TokenController` allowlists
  `~w(public-read read)` and returns the caller's list VERBATIM and UNORDERED,
  so `["public-read", "read"]` mints through the public site-provisioning path —
  a `permissions == ["public-read"]` equality pin is escapable by construction.
  The pin is a SILENT downgrade to `:published`, not a 403, so a public-read
  caller that never asks for drafts is byte-identical before and after.

  Returns an ATOM (`:published | :drafts | :raw`) — never a string — so the
  retriever's atom-keyed `perspective_filter/2` matches (a string silently fell
  through its catch-all and disabled the filter entirely).
  """

  @spec resolve(Plug.Conn.t(), map()) :: :published | :drafts | :raw
  def resolve(conn, params) do
    if anon_pinned?(conn) do
      :published
    else
      case conn.assigns[:forced_perspective] do
        nil -> parse(Map.get(params, "perspective", "published"))
        forced -> parse(forced)
      end
    end
  end

  @doc """
  True when the caller is pinned to published-only reads: no token, no preview
  token, and not an `:edit` share — OR a token whose permissions carry
  `"public-read"` (the browser-shipped site credential; see @moduledoc).
  """
  @spec anon_pinned?(Plug.Conn.t()) :: boolean()
  def anon_pinned?(conn) do
    public_read_token?(conn) or
      (not authed?(conn) and not preview?(conn) and not edit_share?(conn))
  end

  # The edit-share unpin, and the ONE grant shape it deliberately excludes.
  #
  # A SCOPE-wide edit grant (`RequireShareEditToken`, or a section share whose
  # `Sharing.access_for/3` is `:edit`) legitimately reads drafts: the whole
  # surface is the grant, and the editor behind it needs the unpublished view.
  #
  # An ITEM link is not that. Since slice 3 (task-8ac4f3918da1c433) it carries
  # its OWN access level into `:share_access`, so an `access: "edit"` item link
  # would otherwise land in this arm and unpin `?perspective=drafts` on every
  # share-reachable read route (`/papers/:slug/source`, the query/search reads).
  # Its edit grant is confined to the reader's LiveView op path for one slug;
  # it is not a drafts unlock, so `:item` stays pinned to published.
  defp edit_share?(conn) do
    conn.assigns[:share_public] == true and conn.assigns[:share_access] == :edit and
      conn.assigns[:share_grant] != :item
  end

  # MEMBERSHIP, never list equality (`== ["public-read"]` misses the unordered
  # mixed list the public mint path emits — see @moduledoc). The map pattern
  # requires the `:permissions` key: a token struct without it (e.g. the unit
  # suite's `%{tier: :member}` canary) is NOT pinned — absence of the key is
  # not evidence of the public-read class, and over-clamping every token would
  # break preview/member reads. A non-list `permissions` value also falls
  # through unpinned: only a list can carry the public-read grant.
  defp public_read_token?(conn) do
    case conn.assigns[:api_token] do
      %{permissions: perms} when is_list(perms) -> "public-read" in perms
      _ -> false
    end
  end

  # The LENIENT parser: it maps every unrecognised value to `:published` so a
  # caller reached by some path other than a declared `?perspective` route
  # degrades CLOSED. That catch-all is NOT the strictness layer — an unsupported
  # value on a route that declares the param is refused at the edge by
  # `BarkparkWeb.ReadPerspective` before this ever runs. `SearchController` used
  # to carry a byte-identical private copy of these three clauses; it now calls
  # this one. `TasksController.Params.parse_perspective/1` stays separate and
  # that is deliberate — see its own comment.
  # @canonical capability:read-perspective-parse aka:perspective,parse_perspective,drafts,raw,lenient perspective
  @spec parse(term()) :: :published | :drafts | :raw
  def parse("drafts"), do: :drafts
  def parse("raw"), do: :raw
  def parse(_), do: :published

  defp authed?(conn), do: not is_nil(conn.assigns[:api_token])
  defp preview?(conn), do: is_binary(conn.assigns[:forced_perspective])
end
