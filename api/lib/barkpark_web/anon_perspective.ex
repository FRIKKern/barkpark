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
  token, and not an `:edit` share.
  """
  @spec anon_pinned?(Plug.Conn.t()) :: boolean()
  def anon_pinned?(conn) do
    not authed?(conn) and not preview?(conn) and
      not (conn.assigns[:share_public] == true and conn.assigns[:share_access] == :edit)
  end

  @spec parse(term()) :: :published | :drafts | :raw
  def parse("drafts"), do: :drafts
  def parse("raw"), do: :raw
  def parse(_), do: :published

  defp authed?(conn), do: not is_nil(conn.assigns[:api_token])
  defp preview?(conn), do: is_binary(conn.assigns[:forced_perspective])
end
