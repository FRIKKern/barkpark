defmodule BarkparkWeb.Studio.DeskVisionListenTest do
  @moduledoc """
  Vision's Listen on the desk (J37, TanStack's `vision-listen.ts`), over the
  desk's own LiveView socket (`Desk.VisionListen`, `VisionListenStream`): no
  token in the page, and the server holds each Listen to the socket's
  workspace, project and dataset. The browser half is `__desk_vision.test.mjs` §9.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content.Broadcast
  alias Barkpark.Tenancy
  alias Barkpark.TenancyFixtures
  alias BarkparkWeb.Studio.Desk.VisionListen
  alias BarkparkWeb.Studio.Desk.VisionListenStream

  @dataset "production"
  @event "desk-vision-listen"

  setup do
    {ws, proj} = TenancyFixtures.ensure_default_scope!()
    tag = System.unique_integer([:positive])
    staging = "dvl-staging-#{tag}"
    {:ok, _} = Tenancy.create_dataset(proj.id, %{slug: staging, name: "Staging #{tag}"})

    ws_b = TenancyFixtures.create_workspace!()
    proj_b = TenancyFixtures.create_project!(ws_b)

    {:ok,
     ws: ws,
     proj: proj,
     ws_b: ws_b,
     proj_b: proj_b,
     staging: staging,
     tag: tag,
     vision: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk/_tools/vision"}
  end

  defp signed_in(c, opts \\ []) do
    raw = "dvl-token-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "dvl", @dataset, ["read", "write", "admin"], c.ws.id, opts)
    Plug.Test.init_test_session(scoped_conn(), %{"api_token" => raw})
  end

  defp listen(view, payload),
    do:
      render_hook(
        view,
        "vision-listen-start",
        Map.merge(%{"id" => 7, "dataset" => @dataset}, payload)
      )

  defp probe(c), do: "dvl-#{c.tag}-#{System.unique_integer([:positive])}"

  defp stream_pid(view) do
    case :sys.get_state(view.pid).socket.assigns[:vision_listen] do
      %{pid: pid} -> pid
      _ -> nil
    end
  end

  defp subscribers(topic), do: Registry.lookup(Barkpark.PubSub, topic)

  test "the page names no token, and Listen sits beside Fetch, as TanStack's", c do
    {:ok, _view, html} = live(signed_in(c), c.vision)

    button =
      html |> LazyHTML.from_document() |> LazyHTML.query("#dk-vision button[data-vision-listen]")

    assert Enum.count(button) == 1
    assert LazyHTML.attribute(button, "aria-pressed") == ["false"]
    assert LazyHTML.text(button) =~ "Listen"
    root = html |> LazyHTML.from_document() |> LazyHTML.query("#dk-vision") |> LazyHTML.to_html()
    refute root =~ ~r/data-token|bearer|dvl-token-/i
  end

  test "Listen is TanStack's secondary button: a soft fill and a 1 px ring, a step on under the pointer",
       c do
    {:ok, _view, html} = live(signed_in(c), c.vision)

    assert html =~
             ".dk .dk-vision-listen { background: var(--dk-bg-soft); box-shadow: inset 0 0 0 1px var(--dk-btn2-ring); color: var(--dk-btn2-fg); }"

    assert html =~
             ~S|.dk .dk-vision-listen:hover:not([aria-disabled="true"]) { background: var(--dk-btn2-hover-bg); box-shadow: inset 0 0 0 1px var(--dk-btn2-hover-ring); color: var(--dk-btn2-hover-fg); }|

    # Fetch's blue under the pointer is Fetch's alone: a Listen waiting on bad
    # Params (aria-disabled) keeps its soft fill, as TanStack's.
    assert html =~ ".dk .dk-vision-fetch:not(.dk-vision-listen):hover { background: color-mix("
    refute html =~ ".dk .dk-vision-fetch:hover {"

    # Defined for the whole desk, not the editing pane only: Vision is no pane.
    assert html =~
             ".dk { --dk-bg-soft: rgb(246 246 248); --dk-btn2-fg: rgb(78 85 109); --dk-btn2-ring: rgb(230 230 234);"

    assert html =~
             ~S|html[data-theme="dark"] .dk { --dk-bg-soft: rgb(25 26 36); --dk-btn2-fg: rgb(153 158 179); --dk-btn2-ring: rgb(38 40 55);|
  end

  # task-114282a27782b443: TanStack's Listen waiting on bad Params keeps
  # full opacity and greys its word and icon to chip-off-fg (styles.css
  # .vision-actions .btn:not(.btn-primary):disabled).
  test "a disabled Listen greys its word and icon to TanStack's chip-off tokens, at full opacity",
       c do
    {:ok, _view, html} = live(signed_in(c), c.vision)

    assert html =~
             ~S|.dk .dk-vision-listen[aria-disabled="true"], .dk .dk-vision-listen[aria-disabled="true"] svg { color: var(--dk-chip-off-fg); }|

    # Neither is dimmed with opacity (task-c14b12cd6aa086ba).
    refute html =~ ~r/\.dk-vision-(fetch|listen)[^{]*\[aria-disabled="true"\][^{]*\{[^}]*opacity/

    # TanStack's --chip-off-fg, its light and dark values, for the whole
    # desk: Vision is no document pane.
    assert html =~ ~r/\.dk \{ --dk-bg-soft: [^}]*--dk-chip-off-fg: rgb\(143 148 168\); \}/

    assert html =~
             ~r/html\[data-theme="dark"\] \.dk \{ --dk-bg-soft: [^}]*--dk-chip-off-fg: rgb\(90 96 123\); \}/
  end

  # task-c14b12cd6aa086ba: TanStack's Fetch waiting on bad Params greys as a
  # disabled Publish (styles.css `.vision-actions .btn-primary:disabled`:
  # --publish-disabled-bg/-fg), and its disabled Listen under the pointer
  # has no fill (`.btn:not(.danger):disabled:hover { background: none }`
  # outranks the secondary fill).
  test "a disabled Fetch is TanStack's disabled Publish; a disabled Listen has no fill under the pointer",
       c do
    {:ok, _view, html} = live(signed_in(c), c.vision)

    assert html =~
             ~S|.dk .dk-vision-fetch:not(.dk-vision-listen)[aria-disabled="true"] { background: var(--dk-publish-off-bg); color: var(--dk-publish-off-fg); }|

    assert html =~ ~S|.dk .dk-vision-listen[aria-disabled="true"]:hover { background: none; }|

    # TanStack's --publish-disabled-bg/-fg, light and dark, for the whole
    # desk: Vision is neither the footer nor the bulk bar.
    assert html =~
             ~r/\.dk \{ --dk-bg-soft: [^}]*--dk-publish-off-bg: rgb\(187 189 201\); --dk-publish-off-fg: rgb\(236 237 243\);/

    assert html =~
             ~r/html\[data-theme="dark"\] \.dk \{ --dk-bg-soft: [^}]*--dk-publish-off-bg: rgb\(85 92 117\); --dk-publish-off-fg: rgb\(33 38 57\);/
  end

  test "a change in this workspace and project comes back as the listen stream's mutation", c do
    {:ok, view, _html} = live(signed_in(c), c.vision)
    listen(view, %{"type" => "post", "qs" => "filter%5Btitle%5D=Listen+probe&perspective=drafts"})
    assert_push_event(view, @event, %{id: 7, kind: "open"})

    id = probe(c)

    TenancyFixtures.create_document_in!(
      c.ws,
      c.proj,
      "post",
      %{"doc_id" => id, "title" => "Listen probe"},
      @dataset
    )

    assert_push_event(view, @event, %{id: 7, kind: "mutation", event: event}, 2_000)
    assert event.documentId == "drafts." <> id
    assert event.type == "post"
    assert event.result["title"] == "Listen probe"

    # The filter narrows: another title is not this query's.
    TenancyFixtures.create_document_in!(
      c.ws,
      c.proj,
      "post",
      %{"doc_id" => probe(c), "title" => "Other"},
      @dataset
    )

    refute_push_event(view, @event, %{kind: "mutation"}, 300)
  end

  test "workspace B's changes never reach A, even on A's own topic", c do
    {:ok, view, _html} = live(signed_in(c), c.vision)
    listen(view, %{"type" => "post", "qs" => "perspective=drafts"})
    assert_push_event(view, @event, %{kind: "open"})

    # B's real write, in a dataset of the same name.
    TenancyFixtures.create_document_in!(
      c.ws_b,
      c.proj_b,
      "post",
      %{"doc_id" => probe(c), "title" => "B secret"},
      @dataset
    )

    # And B's change put on A's topic and on the shared one: dropped by the workspace check.
    msg = %{
      event_id: 1,
      type: "post",
      mutation: "update",
      doc_id: "drafts.b-only",
      rev: "r1",
      previous_rev: nil,
      workspace_id: c.ws_b.id,
      project_id: c.proj_b.id,
      document: %{"_id" => "drafts.b-only", "title" => "B secret"}
    }

    Phoenix.PubSub.broadcast(
      Barkpark.PubSub,
      Broadcast.workspace_list_topic(@dataset, c.ws.id),
      {:document_changed, msg}
    )

    Phoenix.PubSub.broadcast(
      Barkpark.PubSub,
      Broadcast.global_list_topic(@dataset),
      {:document_changed, msg}
    )

    # Even one that names A's project: only the workspace check stops it.
    forged = %{msg | doc_id: "drafts.b-forged", project_id: c.proj.id}

    Phoenix.PubSub.broadcast(
      Barkpark.PubSub,
      Broadcast.workspace_list_topic(@dataset, c.ws.id),
      {:document_changed, forged}
    )

    # Another project of A is not this page's either.
    proj_a2 = TenancyFixtures.create_project!(c.ws)

    TenancyFixtures.create_document_in!(
      c.ws,
      proj_a2,
      "post",
      %{"doc_id" => probe(c), "title" => "A2"},
      @dataset
    )

    refute_push_event(view, @event, %{kind: "mutation"}, 500)

    # A's own change still comes, so the silence above is the fence, not a dead stream.
    TenancyFixtures.create_document_in!(
      c.ws,
      c.proj,
      "post",
      %{"doc_id" => probe(c), "title" => "A"},
      @dataset
    )

    assert_push_event(
      view,
      @event,
      %{kind: "mutation", event: %{result: %{"title" => "A"}}},
      2_000
    )
  end

  test "a dataset-bound token's session gets no other dataset", c do
    {:ok, view, _html} = live(signed_in(c, dataset_bound: true), c.vision)
    listen(view, %{"dataset" => c.staging, "type" => "post", "qs" => "perspective=drafts"})
    assert_push_event(view, @event, %{id: 7, kind: "error", message: message})
    assert message =~ "dataset"
    assert stream_pid(view) == nil
    assert subscribers(Broadcast.workspace_list_topic(c.staging, c.ws.id)) == []

    TenancyFixtures.create_document_in!(
      c.ws,
      c.proj,
      "post",
      %{"doc_id" => probe(c), "title" => "Staging"},
      c.staging
    )

    refute_push_event(view, @event, %{kind: "mutation"}, 300)

    # A dataset of another workspace, or one no page lists, is refused for any token.
    {:ok, view, _html} = live(signed_in(c), c.vision)
    listen(view, %{"dataset" => "dvl-nowhere-#{c.tag}", "type" => "post", "qs" => ""})
    assert_push_event(view, @event, %{kind: "error"})

    # Nor is a page of another dataset open to it: the desk refuses it before any
    # socket (VisionListen refuses such a dataset too, as a second fence).
    staging_page = "/w/#{c.ws.slug}/p/#{c.proj.slug}/d/#{c.staging}/studio/_desk/_tools/vision"
    refused = get(signed_in(c, dataset_bound: true), staging_page)
    assert refused.halted and refused.status not in [200, 301, 302, 303]

    # Its own dataset it may follow.
    {:ok, view, _html} = live(signed_in(c, dataset_bound: true), c.vision)
    listen(view, %{"type" => "post", "qs" => ""})
    assert_push_event(view, @event, %{kind: "open"})
  end

  test "an unbound admin may follow another dataset the page lists", c do
    {:ok, view, _html} = live(signed_in(c), c.vision)
    listen(view, %{"dataset" => c.staging, "type" => "post", "qs" => ""})
    assert_push_event(view, @event, %{kind: "open"})
    id = probe(c)

    TenancyFixtures.create_document_in!(
      c.ws,
      c.proj,
      "post",
      %{"doc_id" => id, "title" => "S"},
      c.staging
    )

    assert_push_event(view, @event, %{kind: "mutation", event: %{documentId: documentId}}, 2_000)
    assert documentId == "drafts." <> id
  end

  test "unmount stops the subscription", c do
    {:ok, view, _html} = live(signed_in(c), c.vision)
    listen(view, %{"type" => "post", "qs" => ""})
    assert_push_event(view, @event, %{kind: "open"})
    pid = stream_pid(view)
    topic = Broadcast.workspace_list_topic(@dataset, c.ws.id)

    assert Enum.any?(subscribers(topic), &(elem(&1, 0) == pid)), "the stream is subscribed"

    ref = Process.monitor(pid)

    # A normal exit, which a link would not carry: the stream watches the LiveView instead.
    GenServer.stop(view.pid, :normal)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
    # The registry forgets a dead subscriber a moment after it dies.
    assert gone?(topic, pid)
  end

  defp gone?(topic, pid, tries \\ 50) do
    cond do
      not Enum.any?(subscribers(topic), &(elem(&1, 0) == pid)) -> true
      tries == 0 -> false
      true -> Process.sleep(20) && gone?(topic, pid, tries - 1)
    end
  end

  test "Stop, a new Listen, a dataset change and leaving Vision each end the stream", c do
    {:ok, view, _html} = live(signed_in(c), c.vision)

    listen(view, %{"type" => "post", "qs" => ""})
    first = stream_pid(view)
    ref = Process.monitor(first)
    render_hook(view, "vision-listen-stop", %{})
    assert_receive {:DOWN, ^ref, :process, ^first, _}, 1_000
    assert stream_pid(view) == nil

    listen(view, %{"type" => "post", "qs" => ""})
    first = stream_pid(view)
    ref = Process.monitor(first)
    listen(view, %{"id" => 8, "type" => "post", "qs" => ""})
    assert_receive {:DOWN, ^ref, :process, ^first, _}, 1_000
    assert is_pid(stream_pid(view))

    # The page's dataset changes: the stream ends and the page is told.
    second = stream_pid(view)
    ref = Process.monitor(second)

    render_patch(
      view,
      "/w/#{c.ws.slug}/p/#{c.proj.slug}/d/#{c.staging}/studio/_desk/_tools/vision"
    )

    assert_receive {:DOWN, ^ref, :process, ^second, _}, 1_000
    assert_push_event(view, @event, %{id: 8, kind: "stopped"})

    # Leaving Vision for the desk's panes.
    listen(view, %{"dataset" => c.staging, "type" => "post", "qs" => ""})
    third = stream_pid(view)
    ref = Process.monitor(third)
    render_patch(view, "/w/#{c.ws.slug}/p/#{c.proj.slug}/d/#{c.staging}/studio/_desk")
    assert_receive {:DOWN, ^ref, :process, ^third, _}, 1_000
  end

  test "GROQ follows the types it names, with its filter and Params; a query naming none is refused",
       c do
    {:ok, view, _html} = live(signed_in(c), c.vision)

    listen(view, %{
      "query" => "*[title == $t]",
      "params" => %{"t" => "x"},
      "perspective" => "drafts"
    })

    assert_push_event(view, @event, %{kind: "error", message: message})
    assert message =~ "add a _type filter"
    assert stream_pid(view) == nil

    listen(view, %{
      "query" => ~s(*[_type == "post" && title == $t]{title}),
      "params" => %{"t" => "Heard"},
      "perspective" => "drafts"
    })

    assert_push_event(view, @event, %{kind: "open"})

    TenancyFixtures.create_document_in!(
      c.ws,
      c.proj,
      "post",
      %{"doc_id" => probe(c), "title" => "Not heard"},
      @dataset
    )

    TenancyFixtures.create_document_in!(
      c.ws,
      c.proj,
      "page",
      %{"doc_id" => probe(c), "title" => "Heard"},
      @dataset
    )

    refute_push_event(view, @event, %{kind: "mutation"}, 300)

    TenancyFixtures.create_document_in!(
      c.ws,
      c.proj,
      "post",
      %{"doc_id" => probe(c), "title" => "Heard"},
      @dataset
    )

    assert_push_event(
      view,
      @event,
      %{kind: "mutation", event: %{result: %{"title" => "Heard"}}},
      2_000
    )
  end

  test "an operator filter is refused, as the listen stream refuses it", c do
    {:ok, view, _html} = live(signed_in(c), c.vision)
    listen(view, %{"type" => "post", "qs" => "filter%5Btitle%5D%5Bcontains%5D=x"})
    assert_push_event(view, @event, %{kind: "error", message: message})
    assert message =~ "equality filters only"
  end

  test "at most per_second changes a second are shown; the rest are counted", c do
    {:ok, view, _html} = live(signed_in(c), c.vision)
    listen(view, %{"type" => "post", "qs" => ""})
    assert_push_event(view, @event, %{kind: "open"})
    max = VisionListenStream.per_second()
    topic = Broadcast.workspace_list_topic(@dataset, c.ws.id)

    for n <- 1..(max + 5) do
      msg = %{
        event_id: n,
        type: "post",
        mutation: "update",
        doc_id: "drafts.burst-#{n}",
        rev: "r",
        previous_rev: "q",
        workspace_id: c.ws.id,
        project_id: c.proj.id,
        document: %{"_id" => "drafts.burst-#{n}"}
      }

      Phoenix.PubSub.broadcast(Barkpark.PubSub, topic, {:document_changed, msg})
    end

    for _ <- 1..max, do: assert_push_event(view, @event, %{kind: "mutation"}, 1_000)
    refute_push_event(view, @event, %{kind: "mutation"}, 200)
    assert_push_event(view, @event, %{kind: "skipped", count: 5}, 1_500)
  end

  test "groq_types reads the types a query names, as TanStack's groqTypes" do
    assert VisionListen.groq_types(~s(*[_type == "post" && x == 1])) == ["post"]

    assert VisionListen.groq_types(~s(*[_type in ["a", 'b'] || _type=='c'])) |> Enum.sort() == [
             "a",
             "b",
             "c"
           ]

    assert VisionListen.groq_types("*[title == $t]") == []
  end

  test "the Listen words are in nb_NO" do
    Gettext.with_locale(BarkparkWeb.Gettext, "nb_NO", fn ->
      assert Gettext.gettext(BarkparkWeb.Gettext, "Listen") == "Lytt"
      assert Gettext.gettext(BarkparkWeb.Gettext, "Stop") == "Stopp"

      assert Gettext.gettext(BarkparkWeb.Gettext, "Listening for changes…") ==
               "Lytter etter endringer …"

      assert Gettext.gettext(BarkparkWeb.Gettext, "The listener closed") == "Lytteren ble lukket"
    end)
  end
end
