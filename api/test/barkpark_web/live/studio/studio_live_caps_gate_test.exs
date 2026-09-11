defmodule BarkparkWeb.Studio.StudioLiveCapsGateTest do
  @moduledoc """
  ag-studio-capability-hide — the `@caps` map + the LOAD-BEARING server-side
  deny-gate (`BarkparkWeb.Studio.Caps`).

  Hidden ≠ denied: a forged `phx` event for a HIDDEN affordance is server-DENIED
  by the capability gate on EVERY Studio socket — proven NON-VACUOUSLY by the
  absence of the side-effect (no share / grant / document created), not merely a
  flash. The gate re-derives caps server-side, so a grant that expires
  mid-session denies a forged event even though LiveScope's write ladder (built
  from the STALE mount-time grant set) would still pass it.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Accounts, Auth, Content, Sharing}
  alias Barkpark.Repo
  alias Barkpark.TenancyFixtures

  import Barkpark.TenancyFixtures
  import Barkpark.AccessFixtures

  alias BarkparkWeb.Studio.Caps

  @dataset "production"
  @admin "caps-studio-admin"
  @member "caps-studio-member"
  @readonly "caps-studio-readonly"

  setup %{conn: conn} do
    {ws, _proj} = TenancyFixtures.ensure_default_scope!()

    {:ok, _} = Auth.create_token(@admin, "caps admin", @dataset, ["read", "write", "admin"])
    {:ok, _} = Auth.create_token(@member, "caps member", @dataset, ["read", "write"])
    # A READ-ONLY api token: create_token auto-memberships it on the Default ws,
    # so it IS a member — but its permission array is ["read"], so derive/1's
    # write arm (permits?(token, :write)) is false. This is the exact shape of
    # the hole: a member-but-read-only principal on the non-restricted Default.
    {:ok, _} = Auth.create_token(@readonly, "caps readonly", @dataset, ["read"])

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "icon" => "file-text",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    # A NON-default workspace: the Default workspace is an open public-demo in
    # test (`public_demo_studio: true`), so a grantee there mounts as the
    # anonymous-demo grade (no gate). A private workspace exercises the real
    # grant grade + LiveScope gates that the caps gate layers onto.
    priv_ws = create_workspace!("caps-priv-#{System.unique_integer([:positive])}")
    priv_proj = create_project!(priv_ws, "caps-priv-proj")

    # arpss-w8: refresh-proof Default-OFF baseline. A bare `put_env(:shares, [])`
    # is undone by the next Sharing.refresh/0 (which this suite CAN reach through
    # the forged `shares-add` events), and it never snapshots :shares_env.
    Barkpark.SharingFixtures.clear_shares!()

    {:ok, conn: conn, ws: ws, priv_ws: priv_ws, priv_proj: priv_proj}
  end

  defp priv_url(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

  defp token_view(conn, token) do
    conn
    |> Plug.Test.init_test_session(%{"api_token" => token})
    |> live(scoped_studio("/d/#{@dataset}/studio"))
  end

  # A signed-in, non-member USER admitted only by a covering grant.
  defp grantee_session(conn) do
    email = "caps-grantee-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  # `grant_authority!/1` + `bind_grant!/3` moved to `Barkpark.AccessFixtures`
  # (imported above) — shared byte-identically across the four enforcement suites.

  defp caps(view), do: :sys.get_state(view.pid).socket.assigns.caps
  defp flash_error(view), do: :sys.get_state(view.pid).socket.assigns.flash["error"]
  defp doc_count, do: Repo.aggregate(Content.Document, :count)

  # ── 1. LOAD-BEARING forged-event admin deny (hidden ≠ denied) ────────────────

  describe "forged admin-event deny — the security core" do
    test "a non-admin MEMBER forging shares-add is server-DENIED — no share created", %{
      conn: conn
    } do
      {:ok, view, html} = token_view(conn, @member)
      # affordance hidden
      refute html =~ ~s(phx-click="shares-open")
      refute Sharing.active?()

      render_hook(view, "shares-add", %{
        "scope" => "evil/default/production",
        "surfaces" => ["papers", "docs", "media"]
      })

      # NON-VACUOUS: the gate halted before the handler — no registry mutation.
      refute Sharing.shared?("evil", "default", "production", :papers)
      refute Sharing.active?()
      assert flash_error(view) == "You don't have access to do that."
    end

    test "a non-admin MEMBER forging item-share-create mints NO link", %{conn: conn, ws: ws} do
      {:ok, view, _html} = token_view(conn, @member)

      render_hook(view, "item-share-open", %{
        "kind" => "doc",
        "ref-type" => "paper",
        "ref-id" => "x"
      })

      render_hook(view, "item-share-create", %{"access" => "read"})

      assert Sharing.Links.list_for(ws.id, "doc", "paper", "x") == []
    end

    test "a READ-ONLY grantee forging shares-add is DENIED — no share created", %{
      conn: conn,
      priv_ws: ws,
      priv_proj: proj
    } do
      {user, conn} = grantee_session(conn)
      bind_grant!(ws, user, %{capabilities: ["read"]})

      {:ok, view, html} = live(conn, priv_url(ws, proj))
      refute html =~ ~s(phx-click="shares-open")

      render_hook(view, "shares-add", %{
        "scope" => "evil/default/production",
        "surfaces" => ["papers"]
      })

      refute Sharing.active?()
    end
  end

  # ── 2. write-tier forged deny + write-capable success ────────────────────────

  describe "write-tier enforcement" do
    test "a READ-ONLY grantee forging a write (new-document) is DENIED — nothing persists", %{
      conn: conn,
      priv_ws: ws,
      priv_proj: proj
    } do
      {user, conn} = grantee_session(conn)
      bind_grant!(ws, user, %{capabilities: ["read"]})

      {:ok, view, _html} = live(conn, priv_url(ws, proj))

      before = doc_count()
      render_click(view, "new-document", %{"type" => "post"})
      assert doc_count() == before
    end

    test "a WRITE-capable grantee's new-document SUCCEEDS", %{
      conn: conn,
      priv_ws: ws,
      priv_proj: proj
    } do
      {user, conn} = grantee_session(conn)
      bind_grant!(ws, user, %{capabilities: ["read", "write"]})

      {:ok, view, _html} = live(conn, priv_url(ws, proj))

      before = doc_count()
      render_click(view, "new-document", %{"type" => "post"})
      assert doc_count() > before
    end
  end

  # ── 2b. write tier enforced on ALL sockets (authz-drift fix) ─────────────────

  describe "write-tier enforced on non-restricted sockets too" do
    test "a READ-ONLY api-token MEMBER forging new-document is DENIED — nothing persists", %{
      conn: conn
    } do
      {:ok, view, _html} = token_view(conn, @readonly)

      # The hole's exact shape: a member (auto-membership) whose token is
      # read-only, mounted on the non-restricted Default. Before the fix the
      # :write tier short-circuited on `not restricted?` and this write PASSED.
      assert caps(view) == %{read: true, write: false, admin: false}

      before = doc_count()
      render_click(view, "new-document", %{"type" => "post"})

      assert doc_count() == before
      assert flash_error(view) == "You don't have access to do that."
    end

    test "a READ-ONLY member forging save/publish/confirm-delete is DENIED (all :write)", %{
      conn: conn
    } do
      {:ok, view, _html} = token_view(conn, @readonly)

      for event <- ["save", "publish", "confirm-delete"] do
        render_hook(view, event, %{})
        assert flash_error(view) == "You don't have access to do that."
      end
    end

    test "a full-WRITE api-token member is NOT over-denied — new-document persists", %{
      conn: conn
    } do
      {:ok, view, _html} = token_view(conn, @member)

      before = doc_count()
      render_click(view, "new-document", %{"type" => "post"})
      assert doc_count() > before
    end

    test "a USER member (role member ⇒ read+write) is NOT over-denied", %{conn: conn, ws: ws} do
      {user, conn} = grantee_session(conn)
      {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, user.id, "member", "user")

      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio"))
      assert caps(view).write == true

      before = doc_count()
      render_click(view, "new-document", %{"type" => "post"})
      assert doc_count() > before
    end
  end

  # ── 3. affordance hiding driven by @caps.admin ───────────────────────────────

  describe "affordance hiding" do
    test "an admin SEES the Share affordance; a non-admin member does NOT", %{conn: conn} do
      {:ok, _admin_v, admin_html} = token_view(conn, @admin)
      assert admin_html =~ ~s(phx-click="shares-open")

      {:ok, _mem_v, mem_html} = token_view(conn, @member)
      refute mem_html =~ ~s(phx-click="shares-open")
    end
  end

  # ── 4. @caps correctness (observed from the mounted socket) ──────────────────

  describe "@caps map" do
    test "a membership admin ⇒ read+write+admin", %{conn: conn} do
      {:ok, view, _html} = token_view(conn, @admin)
      assert caps(view) == %{read: true, write: true, admin: true}
    end

    test "a read-only grantee ⇒ read only", %{conn: conn, priv_ws: ws, priv_proj: proj} do
      {user, conn} = grantee_session(conn)
      bind_grant!(ws, user, %{capabilities: ["read"]})

      {:ok, view, _html} = live(conn, priv_url(ws, proj))
      c = caps(view)
      assert c.read == true
      assert c.write == false
      assert c.admin == false
    end

    test "a write grant ⇒ write true (admin still false — grants never confer admin)", %{
      conn: conn,
      priv_ws: ws,
      priv_proj: proj
    } do
      {user, conn} = grantee_session(conn)
      bind_grant!(ws, user, %{capabilities: ["read", "write"]})

      {:ok, view, _html} = live(conn, priv_url(ws, proj))
      c = caps(view)
      assert c.write == true
      assert c.admin == false
    end
  end

  # ── 5. mid-session expiry denies (server RE-DERIVES, not stale) ──────────────

  describe "mid-session grant expiry" do
    test "a write grant that expires MID-SESSION denies a forged write — the caps gate re-derives",
         %{conn: conn, priv_ws: ws, priv_proj: proj} do
      {user, conn} = grantee_session(conn)

      grant =
        bind_grant!(ws, user, %{
          capabilities: ["read", "write"],
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      {:ok, view, _html} = live(conn, priv_url(ws, proj))
      # baseline: caps say write while the grant is live.
      assert caps(view).write == true

      # Expire the grant in the DB — the socket's mount-time grant set is now stale.
      grant
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
      |> Repo.update!()

      before = doc_count()
      render_click(view, "new-document", %{"type" => "post"})

      # LiveScope's write ladder uses the STALE mount-time grant (still future) and
      # would pass; the caps gate re-derives from the DB (expired ⇒ excluded) and
      # DENIES. Nothing persists, and the deny is the caps gate's.
      assert doc_count() == before
      assert flash_error(view) == "You don't have access to do that."
    end
  end

  # ── 6. members not regressed ─────────────────────────────────────────────────

  describe "members are byte-identical" do
    test "a real member's new-document persists (the gate does not over-deny)", %{conn: conn} do
      {:ok, view, _html} = token_view(conn, @member)
      before = doc_count()
      render_click(view, "new-document", %{"type" => "post"})
      assert doc_count() > before
    end
  end

  # ── 2c. admin-tier structural mutation (arpss-schema-action-write-tier-ruling) ─

  describe "structural mutation is admin-tier, not write-tier" do
    # The three events named by the ruling PLUS the two confirm-modal steps that
    # continue the same schema action (`confirm_modal_dryrun/1` dispatches
    # `:dryrun`, `confirm_modal_real/1` dispatches `:real`) — the steps are where
    # the mutation actually happens, so leaving them :write would gate the
    # operation one tier too low at the step that performs it.
    @structural_events ~w(schema_action bulk-publish bulk-unpublish
                          confirm-modal-dryrun confirm-modal-real)

    test "each structural event classifies to :admin" do
      for event <- @structural_events do
        assert Caps.classify(event) == :admin, "#{event} is not admin-tier"
      end
    end

    test "a WRITE-capable NON-admin member is HALTED on every structural event", %{conn: conn} do
      {:ok, view, _html} = token_view(conn, @member)

      # NON-VACUITY: this principal HAS write. Any deny below is therefore the
      # admin tier talking, not a missing write cap.
      assert caps(view) == %{read: true, write: true, admin: false}

      for event <- @structural_events do
        render_hook(view, event, %{"name" => "not-a-real-action"})

        assert flash_error(view) == "You don't have access to do that.",
               "write-capable non-admin was NOT halted on #{event}"
      end
    end

    test "an ADMIN is not over-denied — schema_action reaches the handler", %{conn: conn} do
      {:ok, view, _html} = token_view(conn, @admin)
      assert caps(view).admin == true

      render_hook(view, "schema_action", %{"name" => "not-a-real-action"})

      # The handler's own unknown-action branch flashed :info — only reachable
      # PAST the gate, so this is a positive pass proof, not an absent deny.
      state = :sys.get_state(view.pid).socket.assigns.flash
      assert state["info"] == "Action not-a-real-action not yet wired"
      refute state["error"] == "You don't have access to do that."
    end
  end

  # ── comprehensiveness: every privileged event is classified (default-deny) ───

  # ── the DERIVED corpus (pds-bl-w41) ─────────────────────────────────────────
  #
  # THE RULE, NOT A LIST. The `:studio_caps_gate` is an
  # `attach_hook(_, :handle_event, _)` armed by `BarkparkWeb.Studio.Caps.attach/1`.
  # A hook attached in ONE LiveView's mount sees exactly that LiveView's own
  # `handle_event/3` dispatch — so the corpus is "every file under the studio
  # LiveView root that calls `Caps.attach(`", COMPUTED by `caps_gate_hosts/0` at
  # test time, not a hand-maintained `File.read!`. Heads are read out of the AST
  # (`Code.string_to_quoted!` + `Macro.prewalk`), so a `when`-guarded or
  # non-literal head is SEEN rather than silently missed by a
  # `def handle_event("` regex.
  #
  # PLUS the hook pass-through set: `BarkparkWeb.StudioChrome` attaches
  # `:studio_chrome_nav` from an `on_mount` (i.e. BEFORE `Caps.attach/1` runs in
  # `StudioLive.mount`, so it runs FIRST) and `:cont`s its `@per_view_events` on
  # StudioLive, which keeps its own richer handlers. Those names therefore DO
  # reach `Caps.classify/1` and belong to the corpus.
  #
  # DELIBERATELY OUT OF CORPUS (not forgotten):
  #   * `sheet_grid.ex` (80 clauses), `paper_field_block.ex` (4) and every other
  #     `use BarkparkWeb, :live_component` module — a `phx-target`ed component
  #     event is dispatched to `handle_event/3` on the COMPONENT and never
  #     traverses the parent LiveView's hook chain, so `:studio_caps_gate` is
  #     STRUCTURALLY blind to them. They carry their own predicates (the
  #     `write_capable` assign, `Caps.write_capable?/2`) — covered by
  #     `pds_w41_caps_component_gate_test.exs`.
  #   * the sibling studio LiveViews that do NOT call `Caps.attach/1`
  #     (`chat_live.ex` 45, `settings_live.ex` 11, `connectors_live.ex` 8,
  #     `api_tester_live.ex` 8, `tmux_live.ex` 4, `org_admin_live.ex` 4,
  #     `chat_hosts_live.ex` 2, `styleguide_live.ex` 1, `media_live.ex` 1).
  #     `/chat`, `/chat-hosts`, `/settings`, `/connectors`, `/org-admin`,
  #     `/styleguide` and `/tmux` sit in an admin `live_session`
  #     (`{LiveAuth, :admin}` / `:scoped_admin`), so the MOUNT is their gate;
  #     `/media` and `/api-tester` sit in `:scoped_studio` and gate per-event in
  #     the module (`ApiTesterLive` re-derives `Caps.derive(socket).admin` before
  #     `run` / `run-all`; `MediaLive` has no privileged head at all — its only
  #     `handle_event/3` clause is the unknown-event catch-all).
  #   * the trailing NON-LITERAL catch-all in `studio_live.ex` carries no event
  #     name, so `classify/1` can never see it. It is safe only as the file's
  #     LAST clause — the arm reds on any non-literal head that is not last.

  @studio_live_root "lib/barkpark_web/live/studio"
  @studio_live_file "lib/barkpark_web/live/studio/studio_live.ex"
  @chrome_file "lib/barkpark_web/studio_chrome.ex"

  describe "gate comprehensiveness (default-deny by construction)" do
    test "every handle_event head under the :studio_caps_gate classifies to a KNOWN tier" do
      hosts = caps_gate_hosts()

      # CONTROL 1 — the derivation is not empty. An empty corpus makes every
      # assertion below vacuously true, which is the exact failure this arm was
      # filed for.
      assert hosts != [],
             "DERIVATION FOUND NO GATE HOST: no file under " <>
               "#{@studio_live_root} calls `Caps.attach(`. Either the gate moved " <>
               "or this arm is now scanning nothing."

      # CONTROL 2 — the one host we know arms it is in the derived set.
      assert @studio_live_file in hosts,
             "derived gate hosts #{inspect(hosts)} do not include #{@studio_live_file}"

      scans = Enum.map(hosts, &scan_handle_event_heads/1)
      chrome = chrome_per_view_events()

      # CONTROL 3 — the hook-routed set parsed.
      assert chrome != [],
             "failed to parse @per_view_events out of #{@chrome_file}"

      scanned = corpus_report(scans, chrome)

      literal = scans |> Enum.flat_map(& &1.literal) |> Enum.uniq()

      # NON-VACUITY FLOOR, derived across the whole corpus (was `> 50` against
      # one file). 113 literal heads live in studio_live.ex alone at the time of
      # writing; a corpus that parses to fewer than 100 means the AST walk broke.
      assert length(literal) > 100,
             "corpus parsed only #{length(literal)} literal event heads — the AST " <>
               "walk is broken or the corpus shrank.\n#{scanned}"

      # A non-literal head (e.g. the trailing logging catch-all) carries no event
      # name, so `classify/1` can never see it. That is only safe when it is the
      # LAST clause in its file: a non-literal head placed EARLIER silently
      # swallows privileged event names ahead of every literal head below it.
      early = scans |> Enum.flat_map(& &1.early_non_literal)

      assert early == [],
             "NON-LITERAL handle_event head that is NOT the file's final clause — " <>
               "it can match privileged event names that `Caps.classify/1` will " <>
               "never see: #{inspect(early)}\n#{scanned}"

      unclassified = Enum.filter(literal ++ chrome, &(Caps.classify(&1) == :deny))

      assert unclassified == [],
             "these Studio events fall to the default-DENY tier — classify them in " <>
               "BarkparkWeb.Studio.Caps (safe/read/write/admin): #{inspect(unclassified)}" <>
               "\n#{scanned}"
    end

    test "the default (an unknown event) is DENY, and admin/write tiers are non-empty" do
      assert Caps.classify("some-brand-new-privileged-event") == :deny
      assert Caps.classify("shares-add") == :admin
      assert Caps.classify("save") == :write
      assert Caps.classify("select") == :none
    end
  end

  # ── corpus derivation helpers (the rule is stated above the describe) ───────

  # THE RULE. Every file under the studio LiveView root whose source arms the
  # gate. Returns cwd-relative paths (cwd is `api/` under `mix test`).
  defp caps_gate_hosts do
    Path.join([File.cwd!(), @studio_live_root, "**/*.ex"])
    |> Path.wildcard()
    |> Enum.filter(&String.contains?(File.read!(&1), "Caps.attach("))
    |> Enum.map(&Path.relative_to(&1, File.cwd!()))
    |> Enum.sort()
  end

  defp scan_handle_event_heads(rel) do
    clauses =
      Path.join(File.cwd!(), rel)
      |> File.read!()
      |> Code.string_to_quoted!()
      |> handle_event_clauses()
      |> Enum.sort_by(&elem(&1, 0))

    last_line =
      case List.last(clauses) do
        {line, _head} -> line
        nil -> nil
      end

    %{
      file: rel,
      total: length(clauses),
      literal: for({_line, head} <- clauses, is_binary(head), do: head),
      non_literal: for({line, head} <- clauses, not is_binary(head), do: "#{rel}:#{line}"),
      early_non_literal:
        for(
          {line, head} <- clauses,
          not is_binary(head),
          line != last_line,
          do: "#{rel}:#{line}"
        )
    }
  end

  defp handle_event_clauses(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {:def, meta, [call | _body]} = node, acc -> {node, collect_clause(meta, call, acc)}
        node, acc -> {node, acc}
      end)

    acc
  end

  defp collect_clause(meta, {:when, _, [call | _guard]}, acc), do: collect_clause(meta, call, acc)

  defp collect_clause(meta, {:handle_event, _, [head, _params, _socket]}, acc),
    do: [{Keyword.get(meta, :line), head} | acc]

  defp collect_clause(_meta, _call, acc), do: acc

  # The chrome hook `:cont`s these on StudioLive (it only INTERCEPTS them on
  # surfaces that define no handler), so they reach `Caps.classify/1` too.
  defp chrome_per_view_events do
    {_ast, names} =
      Path.join(File.cwd!(), @chrome_file)
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:@, _, [{:per_view_events, _, [{:sigil_w, _, [{:<<>>, _, [raw]}, _]}]}]} = node, _acc
        when is_binary(raw) ->
          {node, String.split(raw)}

        node, acc ->
          {node, acc}
      end)

    names
  end

  # EVERY scanned file is NAMED here, and this string is appended to EVERY red
  # this arm can raise (pds-bl-w41 c1).
  defp corpus_report(scans, chrome) do
    files =
      Enum.map_join(scans, "\n", fn s ->
        "  * #{s.file} — #{s.total} handle_event/3 clauses (#{length(s.literal)} literal, " <>
          "#{length(s.non_literal)} non-literal" <>
          if(s.non_literal == [], do: "", else: " at " <> Enum.join(s.non_literal, ", ")) <> ")"
      end)

    "SCANNED CORPUS (derived: every file under #{@studio_live_root} calling " <>
      "`Caps.attach(`, plus the chrome hook pass-through set):\n" <>
      files <> "\n  * #{@chrome_file} — @per_view_events: #{inspect(chrome)}"
  end
end
