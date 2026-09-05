defmodule BarkparkWeb.PaperPresenceTest do
  @moduledoc """
  Edit-on-the-link slice 4 (task-e99a8e946f80f52c, epic task-a19eeb215f653529),
  criterion 2: *"Two identified viewers on one paper see each other in the
  presence strip within a second."*

  Driven the way the feature really runs: two independent `live/2` connections
  on the same URL, then `render/1` after the presence diff has propagated. The
  wait is a bounded poll rather than a `Process.sleep` — a sleep proves the
  strip appeared eventually, a poll with a deadline proves it appeared inside
  the second the criterion names.

  The second half of the criterion is the half that is easy to get wrong, so it
  is asserted just as hard: an anonymous viewer renders NO strip and is
  reflected only as a COUNT for the identified ones. The privacy line is
  structural — `PaperPresence` tracks every anonymous viewer under one shared
  key, so there is nowhere to put an identity even if a later render wanted
  one.

  `async: false` — the Default scope is process-global and presence is a
  shared, node-wide registry.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Auth, Content}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.PaperPresence

  @dataset "production"
  # The criterion's own budget. Every wait below is bounded by it.
  @within_ms 1_000

  setup %{conn: conn} do
    {default_ws, default_proj} = ensure_default_scope!()
    slug = "eol-presence-#{System.unique_integer([:positive])}"
    seed_paper!(slug)

    %{conn: conn, slug: slug, default_ws: default_ws, default_proj: default_proj}
  end

  defp seed_paper!(slug) do
    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "title" => "Presence probe",
          "blocks" => [
            %{"id" => "b-head", "type" => "heading", "text" => "Presence probe", "level" => 1},
            %{
              "id" => "b-body",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Original body text"}]
            },
            %{
              "id" => "b-extra",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Spare block"}]
            }
          ]
        })
      )

    paper
  end

  defp assigns_of(view), do: :sys.get_state(view.pid).socket.assigns

  defp as_token(conn, raw), do: Plug.Test.init_test_session(conn, %{"api_token" => raw})

  defp token_conn!(conn, name, perms \\ ["read"]) do
    raw = "eol-pres-#{name}-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, name, @dataset, perms)
    {token, as_token(conn, raw)}
  end

  defp user_conn!(conn, memberships) do
    email = "pres-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})

    for {ws, role} <- memberships do
      {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, role, "user")
    end

    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  # Poll `render/1` until `fun` holds, or fail once the criterion's budget is
  # spent. Returns the render that satisfied it.
  defp within(view, fun, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @within_ms
    html = render(view)

    cond do
      fun.(html) ->
        html

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition never held within #{@within_ms}ms; last render:\n#{html}")

      true ->
        Process.sleep(20)
        within(view, fun, deadline)
    end
  end

  describe "criterion 2 — two identified viewers see each other" do
    test "each strip names the other, within a second", %{
      conn: conn,
      slug: slug,
      default_ws: default_ws
    } do
      {user, user_c} = user_conn!(conn, [{default_ws, "member"}])
      {token, token_c} = token_conn!(conn, "desk-token")

      {:ok, first, _html} = live(user_c, "/papers/#{slug}")
      {:ok, second, _html} = live(token_c, "/papers/#{slug}")

      # Each sees BOTH entries: presence lists the room, not the others.
      first_html = within(first, &(&1 =~ "desk-token"))
      assert first_html =~ ~s(id="paper-presence")
      assert first_html =~ user.email

      second_html = within(second, &(&1 =~ user.email))
      assert second_html =~ ~s(id="paper-presence")
      assert second_html =~ "desk-token"

      # One row per PERSON, keyed by kind and id.
      assert second_html =~ ~s(data-presence-key="user:#{user.id}")
      assert first_html =~ ~s(data-presence-key="api_token:#{token.id}")
    end

    test "a viewer who leaves disappears from the other's strip", %{
      conn: conn,
      slug: slug,
      default_ws: default_ws
    } do
      {user, user_c} = user_conn!(conn, [{default_ws, "member"}])
      {_token, token_c} = token_conn!(conn, "leaver")

      {:ok, staying, _html} = live(user_c, "/papers/#{slug}")
      {:ok, leaving, _html} = live(token_c, "/papers/#{slug}")

      within(staying, &(&1 =~ "leaver"))

      GenServer.stop(leaving.pid)

      within(staying, &(not (&1 =~ "leaver")))
      # The strip keeps the viewer who stayed.
      assert render(staying) =~ user.email
    end

    test "entering edit mode raises the editing flag on the other's strip", %{
      conn: conn,
      slug: slug,
      default_ws: default_ws
    } do
      {_user, writer_c} = user_conn!(conn, [{default_ws, "member"}])
      {_token, watcher_c} = token_conn!(conn, "watcher")

      {:ok, writer, _html} = live(writer_c, "/papers/#{slug}")
      {:ok, watcher, _html} = live(watcher_c, "/papers/#{slug}")

      within(watcher, &(&1 =~ ~s(data-editing="false")))

      render_click(writer, "paper-toggle-edit", %{})

      watcher_html = within(watcher, &(&1 =~ ~s(data-editing="true")))
      assert watcher_html =~ "bp-paper-presence-who--editing"

      # And it drops again when the editor goes back to reading.
      render_click(writer, "paper-toggle-edit", %{})
      within(watcher, &(not (&1 =~ ~s(data-editing="true"))))
    end
  end

  describe "criterion 2 — anonymous viewers are counted, never identified" do
    test "an anonymous viewer renders no strip at all", %{conn: conn, slug: slug} do
      {:ok, view, html} = live(conn, "/papers/#{slug}")

      assert assigns_of(view).viewer.kind == :anonymous
      refute html =~ ~s(id="paper-presence")
      refute html =~ "bp-paper-presence"

      # Not even when somebody identified is in the room with her.
      {_token, token_c} = token_conn!(conn, "invisible-to-anon")
      {:ok, _other, _html} = live(token_c, "/papers/#{slug}")

      Process.sleep(100)
      later = render(view)
      refute later =~ ~s(id="paper-presence")
      refute later =~ "invisible-to-anon"
    end

    test "an identified viewer sees the anonymous COUNT rise, and no names", %{
      conn: conn,
      slug: slug
    } do
      {_token, token_c} = token_conn!(conn, "counter")
      {:ok, identified, _html} = live(token_c, "/papers/#{slug}")

      # Alone: nothing anonymous to report.
      refute render(identified) =~ ~s(id="paper-presence-anon")

      {:ok, _anon1, _html} = live(conn, "/papers/#{slug}")
      html = within(identified, &(&1 =~ ~s(data-count="1")))
      assert html =~ "1 anonymous"

      {:ok, _anon2, _html} = live(conn, "/papers/#{slug}")
      html = within(identified, &(&1 =~ ~s(data-count="2")))
      assert html =~ "2 anonymous"

      # The count is all there is: the anonymous entry carries no id anywhere.
      presence = assigns_of(identified).paper_presence
      assert presence.anonymous_count == 2
      assert Enum.all?(presence.identified, &(&1.kind != "anonymous"))
    end
  end

  describe "the presence room itself" do
    test "the topic is keyed per workspace, dataset and slug" do
      assert PaperPresence.topic("ws-1", "production", "a") ==
               "paper_presence:ws:ws-1:production:a"

      # Different tenant, different dataset, different paper: three different
      # rooms. Two tenants' same-slug papers must never see each other.
      refute PaperPresence.topic("ws-1", "production", "a") ==
               PaperPresence.topic("ws-2", "production", "a")

      refute PaperPresence.topic("ws-1", "production", "a") ==
               PaperPresence.topic("ws-1", "staging", "a")

      refute PaperPresence.topic("ws-1", "production", "a") ==
               PaperPresence.topic("ws-1", "production", "b")

      # A legacy NULL-workspace paper gets its OWN room, not a shared global.
      assert PaperPresence.topic(nil, nil, "a") == "paper_presence:ws:none:default:a"
    end

    test "every anonymous viewer shares one key; each identified one has her own" do
      assert PaperPresence.key(%{kind: "anonymous", id: nil}) == "anonymous"
      assert PaperPresence.key(%{kind: "user", id: "u1"}) == "user:u1"
      assert PaperPresence.key(%{kind: "api_token", id: "t1"}) == "api_token:t1"
      assert PaperPresence.key(%{kind: "share", id: "s1"}) == "share:s1"
      # A share with no link id has no identity to key on, so it counts.
      assert PaperPresence.key(%{kind: "share", id: nil}) == "anonymous"
    end

    test "an anonymous meta carries no id and no label, whatever it was handed" do
      meta = PaperPresence.meta(%{kind: "anonymous", id: "sneaky", label: "sneaky@example.com"})

      assert meta.kind == "anonymous"
      assert meta.id == nil
      assert meta.label == nil
      assert meta.editing? == false
    end

    test "two tabs of one person are one presence, and any tab editing counts", %{
      conn: conn,
      slug: slug
    } do
      {token, token_c} = token_conn!(conn, "two-tabs", ["read", "write"])

      {:ok, tab_a, _html} = live(token_c, "/papers/#{slug}")
      {:ok, _tab_b, _html} = live(token_c, "/papers/#{slug}")

      topic = assigns_of(tab_a).presence_topic
      listing = PaperPresence.list(topic)

      assert length(listing.identified) == 1
      assert [%{key: key, editing?: false}] = listing.identified
      assert key == "api_token:#{token.id}"

      render_click(tab_a, "paper-toggle-edit", %{})

      assert [%{editing?: true}] = PaperPresence.list(topic).identified
    end

    test "the display label falls back to a short id, never to blank" do
      assert PaperPresence.display(%{label: "a@b.c", id: "u1"}) == "a@b.c"
      assert PaperPresence.display(%{label: nil, id: "0123456789abcdef"}) == "01234567"
      assert PaperPresence.display(%{label: nil, id: nil}) == "someone"
    end
  end
end
