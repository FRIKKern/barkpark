defmodule BarkparkWeb.PaperActor do
  @moduledoc """
  ONE translation from the reader's `:viewer` summary to the attribution
  vocabulary the storage layer records — edit-on-the-link slice 4
  (task-e99a8e946f80f52c).

  Slice 1's `BarkparkWeb.PaperViewer` resolves WHO is on the page as
  `%{kind: :user | :token | :share | :anonymous, ...}`. Three things now want
  to write that principal down: a revision row, a presence meta, and a
  `paper_access_log` row. They must agree on the strings, or the same visitor
  reads as three different people across the three surfaces.

  So the mapping lives here, once, and every writer calls it:

      :user      -> "user"       + the account id
      :token     -> "api_token"  + the API-token id
      :share     -> "share"      + the share-link id (nil for a section grant)
      :anonymous -> "anonymous"  + no id, ever

  ## Why "api_token" and not "token"

  It is the value `Barkpark.Content.CallerContext`'s `:principal_type` already
  uses for the same principal. A second spelling would mean a query for
  token-authored history had to know which surface wrote the row.

  ## Anonymous is a KIND, not an absence

  An anonymous visitor is recorded as `%{kind: "anonymous", id: nil}` rather
  than skipped. "Somebody unidentified viewed this" is a fact worth holding;
  "nothing happened" is a different and false one. The nil id is what keeps it
  honest — the log never learns anything it was not already told.

  This module deliberately does NOT live in `PaperViewer`: that module is
  slice 1/3 territory, and a shared file is a merge conflict waiting to happen.
  It reads the `:viewer` shape and never writes it.
  """

  alias Barkpark.Content.CallerContext

  @anonymous %{kind: "anonymous", id: nil, label: nil}

  @typedoc "The attribution triple, in `CallerContext.actor/0` shape."
  @type actor :: %{kind: String.t(), id: binary() | nil, label: String.t() | nil}

  @doc "The anonymous actor — what an unrecognised viewer resolves to."
  @spec anonymous() :: actor()
  def anonymous, do: @anonymous

  @doc """
  Translate a `PaperViewer.viewer/0` summary into an attribution actor.

  Total: any shape that is not one of the four known viewers resolves to
  anonymous, so a future viewer kind is under-attributed rather than
  mis-attributed.
  """
  @spec from_viewer(map() | nil) :: actor()
  def from_viewer(%{kind: :user, id: id} = viewer) when is_binary(id),
    do: %{kind: "user", id: id, label: label_of(viewer)}

  def from_viewer(%{kind: :token, id: id} = viewer) when is_binary(id),
    do: %{kind: "api_token", id: id, label: label_of(viewer)}

  # A section-grant share carries no link id (`id: nil`) — it is still a share,
  # and saying so is more useful than collapsing it to anonymous.
  def from_viewer(%{kind: :share} = viewer),
    do: %{kind: "share", id: Map.get(viewer, :id), label: label_of(viewer)}

  def from_viewer(_viewer), do: @anonymous

  @doc "The actor for a LiveView socket's assigns (reads `:viewer`)."
  @spec from_assigns(map()) :: actor()
  def from_assigns(assigns) when is_map(assigns),
    do: assigns |> Map.get(:viewer) |> from_viewer()

  @doc """
  The `CallerContext` a reader write should carry: the one the tenant scope
  already produced, UPGRADED to the account principal when the socket has an
  authenticated user, then stamped with the attribution actor.

  Two deliberate properties:

    * **never a downgrade.** A context that already resolved a non-anonymous
      principal (an API token, via `ScopeHelpers.scope_opts/1`) is kept as-is.
      Only the anonymous baseline is upgraded, and only to a real account.
    * **attribution never widens access.** The actor rides in `:actor`, which
      no access decision reads — so a share visitor is named "share" on the row
      while still grading as the anonymous principal she is.

  `load_grants: false` on the upgrade is not a shortcut: grants are consumed
  only under `opts[:grant_scoped]`, which the public reader never sets, so
  loading them would be a per-op query whose result nothing reads.
  """
  @spec caller_context(keyword(), map()) :: CallerContext.t()
  def caller_context(scope_opts, assigns) when is_list(scope_opts) and is_map(assigns) do
    scope_opts
    |> Keyword.get(:caller_context)
    |> upgrade(Map.get(assigns, :current_user))
    |> CallerContext.with_actor(from_assigns(assigns))
  end

  defp upgrade(%CallerContext{principal_type: :anonymous}, %{id: id}) when is_binary(id),
    do: CallerContext.from_user(id, load_grants: false)

  defp upgrade(%CallerContext{} = ctx, _user), do: ctx

  defp upgrade(_nil_or_other, %{id: id}) when is_binary(id),
    do: CallerContext.from_user(id, load_grants: false)

  defp upgrade(_nil_or_other, _user), do: CallerContext.anonymous()

  # `:label` is optional on every viewer shape and may itself be nil.
  defp label_of(viewer) do
    case Map.get(viewer, :label) do
      label when is_binary(label) and label != "" -> label
      _ -> nil
    end
  end
end
