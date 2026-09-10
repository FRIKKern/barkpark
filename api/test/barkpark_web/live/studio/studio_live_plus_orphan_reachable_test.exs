defmodule BarkparkWeb.Studio.StudioLivePlusOrphanReachableTest do
  @moduledoc """
  THE ORPHAN A DROPPED "+" NAVIGATION LEAVES BEHIND
  (spd-w18-plus-creates-without-navigating, criterion 2).

  WHAT WAS MEASURED. `tooling/studio-journey/journey.mjs` walked four served
  builds. On `4f046cce1` the "+" never navigated within 20.0s across three
  presses — and the desk list still grew "Untitled ⋅ Updated 2m ago" rows,
  because every one of those presses DID create a document. THREE orphan drafts
  survived on guerrilla production and were swept by hand. The create is not
  broken; the ANSWER is lost client-side (D242/D265: `new_document/2` ends in a
  `push_patch` whose reply rides the event's own ref, so a frame the browser
  drops leaves the server believing it navigated).

  THE CRITERION OFFERS TWO ARMS: either the create leaves no orphan, or the
  orphan is REACHABLE AND NAMED. This file takes the second, because the first
  is not reachable from the server: a server-issued `push_patch` runs
  `handle_params` in the same process, in the same reply cycle, with no client
  round trip to condition the insert on — there is no server-observable
  "the navigation arrived", so there is nothing to withhold the create until.
  Deleting on a missing client ACK would need a JS hook (outside this task's
  fence) and would delete a real document on a slow network.

  WHY "NAMED" IS THE WHOLE DEFECT AND NOT A COSMETIC. All three production
  orphans rendered the SAME two words, "Untitled", with the same "Updated 2m
  ago" underneath. The desk row's only visible text is its title
  (`components.ex` → `pane_doc_item`), so three identical rows gave the human
  no way to say which one their press had just made, which were older
  accidents, or which was safe to delete. A row that cannot be told apart from
  its siblings is not reachable, whatever its href says. The fix names the row
  from its schema type and its `doc_id` tail — and that tail is not decoration:
  it is the id in the rendered `doc-<id>`, the `phx-value-id` the row sends on
  select, and the last URL segment that opens the document. The name IS the
  path back.

  HOW THE NAVIGATION IS BLOCKED HERE. `Phoenix.LiveViewTest` has no way to drop
  one reply frame: `render_click/1` returns only after `handle_event` and
  `handle_params` have both run. So the drop is staged at the layer where it is
  observable — the press is made through the REAL "+" control, and then the
  LiveView process is killed before anything could be read off it, which is
  exactly what the human got (a screen that never moved) and exactly what the
  browser had (no navigation). Everything asserted afterwards is read from a
  FRESH desk session, i.e. the reload the human performs next. That is the only
  half of this that the production incident actually left behind.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  # The bare name the three production orphans all shared. Named once so the
  # arm asserting its ABSENCE cannot drift from the arm asserting the new one.
  @bare "Untitled"

  defp seed_schema!(name, title) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => name,
          "title" => title,
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )
  end

  setup do
    seed_schema!("paper", "Papers")
    :ok
  end

  defp desk_url, do: scoped_studio("/d/#{@dataset}/studio/paper")

  defp papers, do: Content.list_documents("paper", @dataset, perspective: :raw)

  # Press the real control, then take the screen away before the reply could be
  # read off it. Returns the document the press created.
  defp press_plus_and_drop_the_navigation(conn) do
    before = MapSet.new(papers(), & &1.doc_id)

    {:ok, view, _html} = live(conn, desk_url())

    view
    |> element(~s(button.pane-add-btn[phx-click="new-document"][phx-value-type="paper"]))
    |> render_click()

    drop_socket(view)

    created = Enum.reject(papers(), &MapSet.member?(before, &1.doc_id))

    # Counted, not matched: `assert [doc] = created, "…"` would evaluate the
    # match first and die of MatchError before `assert/2` ever ran, so the
    # message below would be dead code on the one path it was written for
    # (scripts/unreachable-assert-message-check.sh).
    assert length(created) == 1,
           "the press created #{length(created)} documents, not 1 — the premise of this whole file is that it DOES create exactly one"

    hd(created)
  end

  # A REAL drop, not an abandonment: the LiveView process is killed. It is
  # linked to the test through LiveViewTest's client proxy, so the test traps
  # exits for the duration and drains the wreckage — untrapping again
  # afterwards so a LATER unexpected crash still fails the test rather than
  # being silently absorbed.
  defp drop_socket(view) do
    was_trapping = Process.flag(:trap_exit, true)
    ref = Process.monitor(view.pid)
    Process.exit(view.pid, :kill)

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    after
      2_000 -> flunk("the LiveView did not go down; the socket was never dropped")
    end

    drain_exits()
    Process.flag(:trap_exit, was_trapping)
    :ok
  end

  defp drain_exits do
    receive do
      {:EXIT, _pid, _reason} -> drain_exits()
    after
      200 -> :ok
    end
  end

  # What the human sees on the row, read from the rendered desk rather than
  # from the builder — the criterion is about the DESK LIST.
  defp row_name(view, pub_id) do
    assert has_element?(view, "#doc-#{pub_id}"),
           "the orphan has no row on the desk at all — it is not reachable by any name"

    view
    |> element("#doc-#{pub_id} .pane-doc-title")
    |> render()
    |> strip_tags()
  end

  # The row title span wraps a status-dot span, so the visible name is the text
  # left once the tags are gone. Floki is NOT a dependency here (LiveView 1.1
  # moved LiveViewTest onto lazy_html), and pulling one in for three
  # assertions would be a dependency added by a test.
  defp strip_tags(html) do
    html
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  describe "arm 1 — the press landed, the navigation did not" do
    test "the orphan it left is on the desk under a name that is not a bare \"Untitled\"",
         %{conn: conn} do
      doc = press_plus_and_drop_the_navigation(conn)
      pub_id = Content.published_id(doc.doc_id)

      # The reload the human performs when the screen does not move.
      {:ok, view, _html} = live(conn, desk_url())

      name = row_name(view, pub_id)

      refute name == @bare,
             "the orphan renders as a bare \"Untitled\" — this is the exact row that survived three times on production with nothing to tell it apart"

      assert name =~ "paper",
             "the orphan's name does not say what it is: #{inspect(name)}"

      tail = doc.doc_id |> Content.published_id() |> String.split("-") |> List.last()

      assert name =~ tail,
             "the name carries no handle back to the document (#{inspect(name)} does not contain #{inspect(tail)}) — it names A paper, not THIS one"
    end

    test "the named row is the path back: it carries the id that opens the document",
         %{conn: conn} do
      doc = press_plus_and_drop_the_navigation(conn)
      pub_id = Content.published_id(doc.doc_id)

      {:ok, view, _html} = live(conn, desk_url())

      assert has_element?(
               view,
               ~s(#doc-#{pub_id} .bp-doc-row-body[phx-value-id="#{pub_id}"])
             ),
             "the orphan's row does not send its own id on select — the name would point at nothing"

      # And pressing it actually opens that document.
      view
      |> element("#doc-#{pub_id} .bp-doc-row-body")
      |> render_click()

      assert render(view) =~ pub_id,
             "selecting the named orphan did not open it"
    end
  end

  describe "arm 2 — the production shape: more than one orphan" do
    test "two dropped presses leave two rows with DIFFERENT names", %{conn: conn} do
      first = press_plus_and_drop_the_navigation(conn)
      second = press_plus_and_drop_the_navigation(conn)

      refute first.doc_id == second.doc_id,
             "the two presses reused one document; this arm needs two orphans"

      {:ok, view, _html} = live(conn, desk_url())

      first_name = row_name(view, Content.published_id(first.doc_id))
      second_name = row_name(view, Content.published_id(second.doc_id))

      refute first_name == second_name,
             "both orphans render as #{inspect(first_name)} — indistinguishable rows are what made the three production orphans unsweepable without the API"
    end
  end

  describe "arm 3 — a document the human named is left alone" do
    test "a real title renders verbatim, with no type-and-id suffix", %{conn: conn} do
      {:ok, doc} =
        Content.create_document(
          "paper",
          %{"title" => "Hand walk MT4FI4TN", "content" => %{}},
          @dataset
        )

      {:ok, view, _html} = live(conn, desk_url())

      assert row_name(view, Content.published_id(doc.doc_id)) == "Hand walk MT4FI4TN",
             "the fallback leaked onto a document that has a real title"
    end
  end
end
