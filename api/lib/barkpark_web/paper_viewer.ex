defmodule BarkparkWeb.PaperViewer do
  @moduledoc """
  `on_mount` hook for the paper reader (`BarkparkWeb.BulldocsLive`): the
  reader learns WHO is viewing, so a later slice can decide WHAT they may do
  on the page (epic task-a19eeb215f653529, "Edit on the link"; this is slice
  1, task-0c242c8dc61f6b13).

  ## What it does

  Reads the signed LiveView session and resolves every credential a browser
  can arrive with, then assigns:

    * `:current_user` — the `%Barkpark.Accounts.User{}` behind a
      `session["user_session"]` cookie, or `nil`;
    * `:api_token` — the verified `%Barkpark.Auth.ApiToken{}` behind
      `session["api_token"]` (or, in dev only, the seeded
      `:dev_browser_token`), or `nil`;
    * `:api_token_raw` — the RAW string behind that verified token, or `""`.
      Mirrors `BarkparkWeb.LiveAuth.on_mount(:fetch_api_token, …)`: the
      client-side editor bridges (`data-token=…`) need the raw credential the
      browser already presented, and slice 2's editor passes it straight to
      `paper_block_editor/1`. Only ever set for a token that VERIFIED, so an
      unverifiable string is `""`, never echoed back;
    * `:viewer` — a small scalar summary of the principal the page should
      treat as "you": `%{kind: :user | :token | :share | :anonymous, ...}`
      (see `viewer/3`);
    * `:can_edit?` — ALWAYS `false` here. The paper's workspace is not known
      until `BulldocsLive.mount/3` resolves the paper, so the LiveView calls
      `can_edit?/2` itself once it has the workspace id.

  ## What it never does

  It never halts. Anonymous mounts pass through with `viewer: %{kind:
  :anonymous}` and every other assign `nil`/`false`, so the public reader's
  anonymous render is byte-identical to before this hook existed (the
  `LiveViewMountAuthzCensusTest` public-tier row stays true). Denials are the
  business of `BarkparkWeb.PluginScopeSession` (item-share confinement) and,
  later, of the edit-mode event allowlist — not of this hook.

  ## Precedence

  Mirrors `BarkparkWeb.LiveAuth.on_mount(:fetch_api_token, …)`: the account
  session and the api-token session are resolved INDEPENDENTLY and both
  assigned. For the `:viewer` summary the account wins (a human identity is
  the one attribution wants); for `can_edit?/2` EITHER credential authorizing
  `:write` on the paper's workspace suffices, because each is an independently
  valid credential the browser legitimately presented.

  The dev fallback is the same idiom as LiveAuth: the CONFIG KEY is the
  switch, never `Mix.env()` (gh-8461 — `Mix` is absent in a release).
  `:dev_browser_token` is set only in `config/dev.exs`, so test stays
  fail-closed and prod never carries it.

  ## Share grants

  A mount whose session records an anonymous share grant
  (`PluginScopeSession.build/1` wrote `scoped_share_public`) resolves to
  `%{kind: :share, grant: :item | :section}`. `can_edit?/2` is `false` for
  every share viewer today: item links are read-only, and section edit access
  rides an opaque `share-edit-*` API token, never an anonymous browser
  session. Slice 3 (task-8ac4f3918da1c433) extends this arm with per-paper
  edit links — it must extend `can_edit?/2`, not bypass it.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Barkpark.Accounts
  alias Barkpark.Accounts.User
  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Sharing.Links
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  # The same keys `BarkparkWeb.PluginScopeSession.build/1` writes. Read here,
  # never written.
  @session_share_public "scoped_share_public"
  @session_share_token "scoped_share_token"

  @anonymous %{kind: :anonymous}

  @typedoc "The scalar principal summary the reader carries as `@viewer`."
  @type viewer ::
          %{kind: :anonymous}
          | %{kind: :user, id: binary(), label: String.t() | nil}
          | %{kind: :token, id: binary(), label: String.t() | nil}
          | %{kind: :share, grant: :item | :section, id: binary() | nil}

  @doc "The anonymous viewer — what a mount without this hook should assume."
  @spec anonymous() :: viewer()
  def anonymous, do: @anonymous

  def on_mount(:viewer, _params, session, socket) do
    user = user_from_session(session)
    {token, raw} = token_from_session(session)

    {:cont,
     socket
     |> assign(:current_user, user)
     |> assign(:api_token, token)
     |> assign(:api_token_raw, raw)
     |> assign(:viewer, viewer(user, token, session))
     |> assign(:can_edit?, false)}
  end

  @doc """
  Whether the mounted viewer may EDIT a paper owned by `workspace_id`.

  Takes the socket assigns (so a LiveView mounted WITHOUT the hook degrades to
  `false` rather than crashing) and the paper's workspace id. Fail-closed on
  every unknown shape. The decision is `Barkpark.Tenancy.Auth.authorize/3` with
  action `:write` — the single chokepoint that requires BOTH a membership row
  and (for tokens) the `write` permission — and nothing else.
  """
  @spec can_edit?(map(), binary() | nil) :: boolean()
  def can_edit?(assigns, workspace_id) when is_map(assigns) and is_binary(workspace_id) do
    principals =
      [Map.get(assigns, :current_user), Map.get(assigns, :api_token)]
      |> Enum.filter(&match?(%{__struct__: s} when s in [User, ApiToken], &1))

    Enum.any?(principals, &(TenancyAuth.authorize(&1, workspace_id, :write) == :ok))
  end

  def can_edit?(_assigns, _workspace_id), do: false

  @doc false
  @spec viewer(User.t() | nil, ApiToken.t() | nil, map()) :: viewer()
  def viewer(%User{id: id} = user, _token, _session),
    do: %{kind: :user, id: id, label: Map.get(user, :email)}

  def viewer(nil, %ApiToken{id: id} = token, _session),
    do: %{kind: :token, id: id, label: token.name || token.label}

  def viewer(nil, nil, session) when is_map(session) do
    if session[@session_share_public] == true do
      share_viewer(session[@session_share_token])
    else
      @anonymous
    end
  end

  def viewer(_user, _token, _session), do: @anonymous

  defp share_viewer(raw) when is_binary(raw) and raw != "" do
    case Links.resolve(raw) do
      {:ok, %{id: id}} -> %{kind: :share, grant: :item, id: id}
      _ -> %{kind: :share, grant: :section, id: nil}
    end
  end

  defp share_viewer(_), do: %{kind: :share, grant: :section, id: nil}

  defp user_from_session(session) do
    case session["user_session"] do
      raw when is_binary(raw) and raw != "" ->
        case Accounts.verify_user_session(String.trim(raw)) do
          {%User{} = user, _} -> user
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # `{token, raw}` — the verified struct and the raw string it verified from.
  # `{nil, ""}` for every absent / unverifiable credential, so the raw value is
  # never echoed back for a token the server did not accept.
  defp token_from_session(session) do
    raw =
      case session["api_token"] do
        raw when is_binary(raw) and raw != "" -> raw
        _ -> dev_browser_token_fallback()
      end

    with raw when is_binary(raw) <- raw,
         {:ok, %ApiToken{} = token} <- Auth.verify_token(raw) do
      {token, raw}
    else
      _ -> {nil, ""}
    end
  end

  defp dev_browser_token_fallback do
    case Application.get_env(:barkpark, :dev_browser_token) do
      raw when is_binary(raw) and raw != "" -> raw
      _ -> nil
    end
  end
end
