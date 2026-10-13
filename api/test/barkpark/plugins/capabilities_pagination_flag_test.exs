defmodule Barkpark.Plugins.CapabilitiesPaginationFlagTest do
  @moduledoc """
  The manifest's `paginated` bit is not documentation — it is the ONLY switch
  the Go CLI reads before it will page, warn, or refuse:

    * `internal/cli/run.go:236` — `--all` walks offset pages only when
      `cmd.Paginated`; on a `false` command `--all` is silently a no-op and the
      caller gets page one believing it got everything;
    * `internal/cli/run.go:527` — the "page reached the default limit, more may
      be available" notice is suppressed for non-paginated commands, so a
      truncated read looks complete;
    * `internal/cli/run.go:373` — the `unreadable_list_page` refusal (the PDS
      reader law) does not even arm, so a proxy 502 on a list read renders as an
      empty success.

  A read command that OFFERS `--limit` and `--offset` is by construction a
  paged read: those flags exist because the server truncates. Flagging it
  `paginated: false` is therefore not a lesser setting, it is a false one, and
  every consequence above is silent. `media.search` shipped exactly that shape —
  limit + offset + cursor flags, a server emitting `total`/`hasMore`/`nextCursor`,
  and `paginated: false`.

  This guard runs over the WHOLE manifest, not the media noun: an inverted flag
  in one command is never an inverted flag in only one.

  ## THE SECOND AXIS: `paginated: true` ⇒ PAGE TWO IS REACHABLE

  Everything above measures the DECLARATION. It cannot see the defect that a
  declaration is only half of: a server that answers `has_more: true` /
  `hasMore: true` and hands back nothing to ask page two WITH. `--all` arms,
  the truncation notice fires, the caller is correctly told more exists — and
  there is no token, no next offset, no cursor anywhere in the envelope. The
  flag is right and the walk still cannot happen.

  Three surfaces shipped exactly that, two of which never shared a line of
  code, so the invariant is checked here — where the paginated set is already
  enumerated — rather than in three sibling files that would each be a parallel
  second checker of the same rule:

    * `task.ready` (`GET /v1/tasks/ready`) — `TasksController.ready/2` called
      `task_list_response/4` with `limit:` and `offset:` only. `Tasks.ready/1`
      has NO keyset axis to seek on, so its continuation is necessarily
      OFFSET-shaped: `Params.page_meta/2` now mints `page.next_offset`.
    * `task.ls` (`GET /v1/tasks`) — the keyset `page.next_cursor` existed but
      `TasksController.page_block/2` added it ONLY when the caller had already
      spelled `?cursor=`. A plain `?limit=` walk got `has_more: true` and
      nothing else. Same `page.next_offset` covers it; the cursor branch nils
      `next_offset` because the index 400s a request naming both models.
    * `search.query` (`GET /v1/data/search/:dataset`, and `POST /v1/search`) —
      `HitEnvelope.build/5` threaded `:offset` in purely to COMPUTE `hasMore`
      and never emitted it. `offset` and `nextOffset` are now emitted from the
      same expression that decides `hasMore`.

  ### THE INVARIANT IS CONDITIONAL, AND THAT IS THE POINT

  `assert_continuation!/3` fires only on a response that ALREADY said there is
  more. A surface that reports `has_more: false` satisfies it — silence about
  paging is not a broken promise. This is why the guard is not the tautology
  "every list carries a cursor", and it is what the two mutation directions
  measure:

    * delete the continuation from a `has_more: true` response → the invariant
      test for THAT surface reds, naming the surface and the key;
    * delete the `has_more` signal instead (force it false) → every invariant
      test stays GREEN.

  ### NON-VACUITY, MEASURED WITHOUT READING THE FIELD UNDER TEST

  A conditional guard whose antecedent never holds passes while measuring
  nothing. Each surface therefore asserts its precondition from the FIXTURE and
  the ROWS — the corpus seeded is larger than the page requested, and the page
  came back exactly `limit` long — never from the `has_more`/`hasMore` field the
  invariant is about. A guard that established its own antecedent by reading
  the field under mutation would go green the moment that field was broken and
  call it a pass.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tasks, TenancyFixtures}
  alias Barkpark.Content.{MutationEvent, PaperAccess}
  alias Barkpark.Plugins.Capabilities
  alias Barkpark.Repo
  alias Barkpark.Webhooks

  @token "barkpark-test-pagination-continuation"
  @dataset "production"
  @search_dataset "test"

  # Seed more than one page so the antecedent is genuinely reachable, and page
  # small enough that the walk is two requests.
  @page 2
  @corpus 5

  defp commands do
    Capabilities.manifest("admin", project: false)["commands"]
  end

  defp flag_names(command), do: Enum.map(command["flags"] || [], & &1["name"])

  # ── axis 1: the DECLARATION (unchanged) ─────────────────────────────────

  test "the manifest is non-empty and carries the flag this guard measures" do
    cmds = commands()

    assert length(cmds) > 50,
           "manifest scanned #{length(cmds)} commands — too few to be the real one"

    assert Enum.all?(cmds, &is_map_key(&1, "paginated")),
           "every command must carry a `paginated` bit for this guard to mean anything"

    assert Enum.any?(cmds, & &1["paginated"]),
           "no command is `paginated: true` — the guard would pass vacuously"
  end

  test "every read offering both --limit and --offset is paginated: true" do
    offenders =
      commands()
      |> Enum.filter(fn cmd ->
        names = flag_names(cmd)
        not cmd["writes"] and "limit" in names and "offset" in names and not cmd["paginated"]
      end)
      |> Enum.map(& &1["id"])
      |> Enum.sort()

    assert offenders == [],
           """
           These read commands declare --limit AND --offset but are flagged `paginated: false`:

             #{Enum.join(offenders, "\n  ")}

           `bp <cmd> --all` silently returns page one for each of them, the
           default-page truncation notice never fires, and the
           unreadable_list_page refusal never arms. Set `paginated: true` on the
           command in api/lib/barkpark/plugins/capabilities.ex and record its
           response envelope key in internal/cli/paginate_all_test.go's
           `paginatedEnvelopeKeys` (that Go guard fails until you do).
           """
  end

  test "every paginated read declares a --limit flag with the server's default" do
    # `defaultPageLimit` (internal/cli/run.go:540) reads the limit flag's
    # DEFAULT off the manifest to decide whether page one was full. No default
    # means it returns 0 and the truncation notice is skipped — a paginated
    # command with no declared limit default cannot warn about truncation.
    offenders =
      commands()
      |> Enum.filter(& &1["paginated"])
      |> Enum.filter(fn cmd ->
        limit = Enum.find(cmd["flags"] || [], &(&1["name"] == "limit"))
        is_nil(limit) or is_nil(limit["default"])
      end)
      |> Enum.map(& &1["id"])
      |> Enum.sort()

    assert offenders == [],
           """
           These `paginated: true` commands declare no --limit default, so
           `defaultPageLimit` returns 0 and the "more may be available" notice
           can never fire for them:

             #{Enum.join(offenders, "\n  ")}
           """
  end

  test "the four media list reads are paginated with server-matching defaults" do
    by_id = Map.new(commands(), &{&1["id"], &1})

    for {id, limit_default} <- [
          {"media.ls", 50},
          {"media.search", 50},
          {"media.collections", 200},
          {"media.collection-assets", 50}
        ] do
      cmd = Map.fetch!(by_id, id)
      assert cmd["paginated"], "#{id} must be paginated: true"

      names = flag_names(cmd)
      assert "limit" in names, "#{id} must offer --limit"
      assert "offset" in names, "#{id} must offer --offset"

      limit = Enum.find(cmd["flags"], &(&1["name"] == "limit"))

      assert limit["default"] == limit_default,
             "#{id} --limit default #{inspect(limit["default"])} does not match the server's #{limit_default}"
    end
  end

  # ── axis 2: REACHABILITY ────────────────────────────────────────────────

  # The one assertion the whole second axis reduces to. `has_more` is the
  # ANTECEDENT, never the thing asserted: a false there is a satisfied
  # invariant, not a skipped test.
  defp assert_continuation!(label, key, {has_more, continuation}) do
    if has_more do
      refute is_nil(continuation),
             """
             CONTINUATION WITHHELD — #{label}

             The response says there is another page and hands back nothing to
             ask for it with: the paging signal is true and `#{key}` is
             #{inspect(continuation)}.

             A caller in this position has three bad options and no good one —
             re-read page one forever, guess an offset the server never
             confirmed, or stop early and call a truncated read complete. The
             CLI's `--all` walk takes the third.

             Either mint the continuation beside the signal that promises it
             (`TasksController.Params.page_meta/2` for the task routes,
             `Barkpark.Search.HitEnvelope.build/5` for the search surfaces —
             both derive it from the SAME expression that decides the signal,
             so neither can drift), or report the signal false.
             """
    end
  end

  # A fixture-side precondition, deliberately blind to the field under test:
  # it reads the corpus size and the row count, never `has_more`/`hasMore`.
  defp assert_antecedent_reachable!(label, returned) do
    assert @corpus > @page,
           "#{label}: the fixture seeds #{@corpus} rows for a #{@page}-row page — no page two exists to be reachable"

    assert returned == @page,
           "#{label}: page one returned #{returned} rows for `limit=#{@page}` — the fixture never produced a truncated page, so the invariant below would pass vacuously"
  end

  setup do
    {:ok, _} = Auth.create_token(@token, "test-pagination", "test", ["read", "write", "admin"])
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @search_dataset
      )

    %{scope: scope}
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer #{@token}")

  defp get_json(conn, path, params) do
    authed(conn) |> get(path, params) |> json_response(200)
  end

  # A RANDOM title: `Content.create_document` runs a near-duplicate guard over
  # task titles and a corpus of `x-1`, `x-2`, … trips it at ~0.7 similarity.
  # The fixture would then fail to seed, which reads as a paging bug.
  defp mk_task!(scope, phase_id) do
    content = %{
      "kind" => "task",
      "lifecycle_status" => "open",
      "parent_id" => phase_id,
      "acceptance_criteria" => [%{"criterion" => "the fixture states its bar", "met" => true}]
    }

    doc_id = "pgc-" <> Integer.to_string(System.unique_integer([:positive]))

    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => "t-" <> Base.encode16(:crypto.strong_rand_bytes(10), case: :lower),
          "content" => content
        },
        @dataset,
        scope
      )

    doc
  end

  defp seed_tasks!(scope) do
    phase_id = "pgc-phase-" <> Integer.to_string(System.unique_integer([:positive]))
    for _ <- 1..@corpus, do: mk_task!(scope, phase_id)
    phase_id
  end

  defp seed_search! do
    term = "pagecontinuation"

    for i <- 1..@corpus do
      doc_id = "pgs#{i}#{System.unique_integer([:positive])}"

      {:ok, _} =
        Content.create_document(
          "post",
          %{"doc_id" => doc_id, "title" => "#{term} number #{i}"},
          @search_dataset
        )

      {:ok, _} = Content.publish_document(doc_id, "post", @search_dataset)
    end

    term
  end

  # The reachability table is BOUND to the enumeration above, not parallel to
  # it: a surface here that the manifest does not call paginated would mean the
  # two axes are measuring different endpoints.
  # Plugins-off: asserts on what enabled plugins contribute (registry, schemas, desk nodes, manifest commands)
  @tag :requires_plugins
  test "every surface whose page-two reachability is proved below is a paginated command" do
    by_id = Map.new(commands(), &{&1["id"], &1})

    for id <- ["task.ready", "task.ls", "search.query"] do
      cmd = Map.fetch!(by_id, id)

      assert cmd["paginated"],
             "#{id} is proved reachable below but the manifest calls it paginated: false — the two axes are describing different commands"
    end
  end

  describe "(a) GET /v1/tasks/ready — the OFFSET continuation" do
    @label "task.ready (GET /v1/tasks/ready)"

    test "has_more: true carries page.next_offset", %{conn: conn, scope: scope} do
      phase_id = seed_tasks!(scope)

      body = get_json(conn, "/v1/tasks/ready", %{"limit" => "#{@page}", "phase_id" => phase_id})
      page = body["page"]

      assert_antecedent_reachable!(@label, length(body["docs"]))

      assert_continuation!(@label, "page.next_offset", {page["has_more"], page["next_offset"]})
    end

    test "the continuation actually reaches rows page one did not", %{conn: conn, scope: scope} do
      phase_id = seed_tasks!(scope)

      one = get_json(conn, "/v1/tasks/ready", %{"limit" => "#{@page}", "phase_id" => phase_id})
      assert_antecedent_reachable!(@label, length(one["docs"]))

      if one["page"]["has_more"] do
        two =
          get_json(conn, "/v1/tasks/ready", %{
            "limit" => "#{@page}",
            "offset" => "#{one["page"]["next_offset"]}",
            "phase_id" => phase_id
          })

        first = MapSet.new(one["docs"], & &1["doc_id"])
        second = MapSet.new(two["docs"], & &1["doc_id"])

        refute Enum.empty?(second),
               "#{@label}: page.next_offset was handed back and returned an EMPTY page — the continuation is a token to nowhere"

        assert MapSet.disjoint?(first, second),
               "#{@label}: page.next_offset re-served rows from page one — the walk does not advance"
      end
    end
  end

  describe "(b) GET /v1/tasks — offset by default, keyset when asked" do
    @label_ls "task.ls (GET /v1/tasks)"

    test "a plain ?limit= walk carries page.next_offset", %{conn: conn, scope: scope} do
      phase_id = seed_tasks!(scope)

      body = get_json(conn, "/v1/tasks", %{"limit" => "#{@page}", "phase_id" => phase_id})
      page = body["page"]

      assert_antecedent_reachable!(@label_ls, length(body["docs"]))

      assert_continuation!(@label_ls, "page.next_offset", {page["has_more"], page["next_offset"]})
    end

    test "?cursor= swaps the offset continuation for the keyset one, never both",
         %{conn: conn, scope: scope} do
      phase_id = seed_tasks!(scope)

      body =
        get_json(conn, "/v1/tasks", %{
          "limit" => "#{@page}",
          "phase_id" => phase_id,
          "cursor" => ""
        })

      page = body["page"]
      assert_antecedent_reachable!(@label_ls, length(body["docs"]))

      assert_continuation!(@label_ls, "page.next_cursor", {page["has_more"], page["next_cursor"]})

      # ONE page, ONE continuation. `index/2` 400s a request naming both models,
      # so an offset here would be a token the route refuses to accept back.
      assert is_nil(page["next_offset"]),
             "#{@label_ls}: a cursor page also minted page.next_offset — two tokens that disagree about where page two starts, one of which the route refuses"
    end

    test "the continuation actually reaches rows page one did not", %{conn: conn, scope: scope} do
      phase_id = seed_tasks!(scope)

      one = get_json(conn, "/v1/tasks", %{"limit" => "#{@page}", "phase_id" => phase_id})
      assert_antecedent_reachable!(@label_ls, length(one["docs"]))

      if one["page"]["has_more"] do
        two =
          get_json(conn, "/v1/tasks", %{
            "limit" => "#{@page}",
            "offset" => "#{one["page"]["next_offset"]}",
            "phase_id" => phase_id
          })

        first = MapSet.new(one["docs"], & &1["doc_id"])
        second = MapSet.new(two["docs"], & &1["doc_id"])

        refute Enum.empty?(second),
               "#{@label_ls}: page.next_offset was handed back and returned an EMPTY page"

        assert MapSet.disjoint?(first, second),
               "#{@label_ls}: page.next_offset re-served rows from page one — the walk does not advance"
      end
    end
  end

  describe "(c) GET /v1/data/search/:dataset — the shared hit envelope" do
    @label_q "search.query (GET /v1/data/search/:dataset)"

    test "hasMore: true carries nextOffset", %{conn: conn} do
      term = seed_search!()

      body =
        get_json(conn, "/v1/data/search/#{@search_dataset}", %{
          "q" => term,
          "limit" => "#{@page}",
          "offset" => "0"
        })

      assert_antecedent_reachable!(@label_q, length(body["documents"]))

      assert_continuation!(@label_q, "nextOffset", {body["hasMore"], body["nextOffset"]})
    end

    test "the continuation actually reaches hits page one did not", %{conn: conn} do
      term = seed_search!()

      one =
        get_json(conn, "/v1/data/search/#{@search_dataset}", %{
          "q" => term,
          "limit" => "#{@page}",
          "offset" => "0"
        })

      assert_antecedent_reachable!(@label_q, length(one["documents"]))

      if one["hasMore"] do
        two =
          get_json(conn, "/v1/data/search/#{@search_dataset}", %{
            "q" => term,
            "limit" => "#{@page}",
            "offset" => "#{one["nextOffset"]}"
          })

        first = MapSet.new(one["documents"], & &1["_id"])
        second = MapSet.new(two["documents"], & &1["_id"])

        refute Enum.empty?(second),
               "#{@label_q}: nextOffset was handed back and returned an EMPTY page"

        assert MapSet.disjoint?(first, second),
               "#{@label_q}: nextOffset re-served hits from page one — the walk does not advance"
      end
    end

    test "the loopback fast-path shares the builder, so it carries the same continuation",
         %{conn: conn} do
      term = seed_search!()

      body =
        get_json(conn, "/v1/data/local/search/#{@search_dataset}", %{
          "q" => term,
          "limit" => "#{@page}",
          "offset" => "0"
        })

      assert_antecedent_reachable!(@label_q <> " [loopback]", length(body["documents"]))

      assert_continuation!(
        @label_q <> " [loopback]",
        "nextOffset",
        {body["hasMore"], body["nextOffset"]}
      )
    end
  end

  # ── axis 3: THE ROUTER ARM (task-de4df581f611d49a) ──────────────────────
  #
  # Everything above enumerates the MANIFEST. A list route that is not a
  # manifest command is invisible to it by construction, which is how
  # `GET /v1/secrets/:name/audit` paged with no signal at all and
  # `GET /v1/data/history/...` had no `?offset=` for months. This arm derives a
  # second population from the ROUTER (Barkpark.Test.PagedRoutes: every GET
  # action that reads a "limit"/"offset" literal) and holds every member to an
  # explicit, reasoned classification. A new paged route therefore cannot be
  # born silent: it reds here until somebody says what it is.
  #
  # THE TWO ENDPOINTS, DECIDED (criterion 1 of the row): both take branch (a),
  # a truncation signal AND a continuation the caller passes back.
  #   * secrets audit — it already paged by offset but never said there was
  #     more. Now `has_more` (one row past the page, never a COUNT) and
  #     `next_offset`, on a TOTAL order (`inserted_at, id`) so the position is
  #     stable. Branch (b) "this page is the whole set" was never true: the log
  #     is unbounded and the route already took `?offset=`.
  #   * history — `?offset=` and `has_more` landed in #18882, but the
  #     continuation was left for the caller to compute. Now `next_offset`.
  #     Branch (b) is false here too: a document's trail is unbounded
  #     (Content.Revisions' retention is INDEFINITE).

  alias Barkpark.Test.PagedRoutes

  # Every member of the router-derived population, classified. The kinds:
  #   {:probed, why}           reachability is PROVED by a live probe in this
  #                            file (signal ⇒ continuation ⇒ page two)
  #   {:manifest, id, why}     a `paginated: true` manifest command; axis 1
  #                            governs its declaration
  #   {:signalled, why}        carries its own signal + continuation, not probed
  #                            here; the reason names the keys
  #   {:top_n, why}            deliberately a bounded top-N with no page two;
  #                            the reason says why that is the right shape
  @router_arm %{
    "BarkparkWeb.SecretController.audit" =>
      {:probed, "has_more + next_offset, minted from one expression; probed below"},
    "BarkparkWeb.HistoryController.index" =>
      {:probed, "has_more + next_offset over a total order; probed below (and doc.history)"},
    "BarkparkWeb.TasksController.ready" =>
      {:probed, "page.has_more + page.next_offset; probed in (a) above"},
    "BarkparkWeb.TasksController.index" =>
      {:probed, "page.next_offset, or page.next_cursor under ?cursor=; probed in (b) above"},
    "BarkparkWeb.SearchController.search" =>
      {:probed, "hasMore + nextOffset from Search.HitEnvelope; probed in (c) above"},
    "BarkparkWeb.SearchController.search_local" =>
      {:probed, "the loopback shares HitEnvelope; probed in (c) above"},
    "BarkparkWeb.QueryController.index" =>
      {:manifest, "doc.ls", "query envelope carries hasMore + nextOffset"},
    "BarkparkWeb.V1.MediaController.index" =>
      {:manifest, "media.ls", "media list envelope carries hasMore + nextOffset"},
    "BarkparkWeb.V1.MediaCollectionsController.index" =>
      {:manifest, "media.collections", "collections list carries hasMore + nextOffset"},
    "BarkparkWeb.MemberController.index" =>
      {:manifest, "workspace.member-ls", "members list carries hasMore + nextOffset"},
    "BarkparkWeb.MemberController.tokens" =>
      {:manifest, "token.ls", "tokens list carries hasMore + nextOffset"},
    "BarkparkWeb.V1.MediaCollectionsController.share_view" =>
      {:signalled, "public share view: hasMore + nextOffset beside total"},
    "BarkparkWeb.TasksController.events" =>
      {:signalled, "keyset replay: has_more + cursor, passed back as ?since="},
    "BarkparkWeb.PulseController.recent" =>
      {:signalled, "keyset: Pulse.recent/3 returns next (pass back as since) and total"},
    "BarkparkWeb.TasksController.prime" =>
      {:top_n, "session orientation, ≤100 cards by design — not a listing to walk"},
    "BarkparkWeb.FederatedSearchController.search" =>
      {:top_n,
       "a top-N preview per surface with per-surface total; walk the surface's own search"},
    "BarkparkWeb.SearchController.search_suggestions" =>
      {:top_n, "typeahead, ≤20 suggestions — a ranked head, not a set"},
    "BarkparkWeb.V1.MediaController.search_suggestions" =>
      {:top_n, "typeahead, ≤20 suggestions — a ranked head, not a set"},
    "BarkparkWeb.QueryController.related" =>
      {:top_n, "a ranked related-documents head, not a set"},
    "BarkparkWeb.PaperAccessController.index" =>
      {:probed, "has_more + next_offset over a total order (task-fb4cf8323a9795e5); probed below"},
    "BarkparkWeb.WebhookController.deliveries" =>
      {:probed, "has_more + next_offset over a total order (task-fb4cf8323a9795e5); probed below"}
  }

  # The positive control: routes the derivation MUST find. The two this row
  # named, plus one route that was already honest, so a derivation that found
  # only the two new ones (or nothing) cannot pass.
  @router_control [
    "BarkparkWeb.SecretController.audit",
    "BarkparkWeb.HistoryController.index",
    "BarkparkWeb.TasksController.ready"
  ]

  defp assert_router_control!(population) do
    keys = MapSet.new(population, & &1.key)
    missing = Enum.reject(@router_control, &MapSet.member?(keys, &1))

    assert missing == [],
           """
           ROUTER ARM IS BLIND to #{Enum.join(missing, ", ")}

           Barkpark.Test.PagedRoutes.derive/2 must find every GET action that
           reads a "limit"/"offset" literal, and it did not find these. A
           derivation that reads nothing passes everything, which is how this
           class of route stayed invisible for months.
           """
  end

  test "router arm: the positive control is found (the two named routes + an honest one)" do
    population = PagedRoutes.derive()
    assert length(population) >= 10, "router arm derived only #{length(population)} actions"
    assert_router_control!(population)
  end

  test "router arm: every derived action is classified, and no classification is stale" do
    derived = PagedRoutes.derive() |> Enum.map(& &1.key) |> MapSet.new()
    classified = @router_arm |> Map.keys() |> MapSet.new()

    unclassified = derived |> MapSet.difference(classified) |> Enum.sort()
    stale = classified |> MapSet.difference(derived) |> Enum.sort()

    assert unclassified == [],
           """
           UNCLASSIFIED PAGED ROUTE(S): #{Enum.join(unclassified, ", ")}

           These GET actions read ?limit=/?offset= and nobody has said whether
           a caller can tell a full page from the last one. Add each to
           @router_arm with its kind: {:probed, why} plus a probe here,
           {:manifest, id, why}, {:signalled, why} naming the signal and the
           continuation, or {:top_n, why} saying why no page two exists.
           """

    assert stale == [],
           "@router_arm classifies actions the router no longer derives: #{Enum.join(stale, ", ")} — drop them"
  end

  test "router arm: every :manifest classification names a paginated: true command" do
    by_id = Map.new(commands(), &{&1["id"], &1})

    for {key, {:manifest, id, _why}} <- @router_arm do
      cmd = Map.get(by_id, id)

      assert cmd,
             "#{key} is classified {:manifest, #{inspect(id)}} but the manifest has no such command"

      assert cmd["paginated"], "#{key} leans on #{id}, which is paginated: false"
    end
  end

  test "router arm MUTATION: strip the paging reads from either named controller and the control reds naming it" do
    for {mod, key} <- [
          {BarkparkWeb.SecretController, "BarkparkWeb.SecretController.audit"},
          {BarkparkWeb.HistoryController, "BarkparkWeb.HistoryController.index"}
        ] do
      source = PagedRoutes.source_of(mod)
      anchors = for lit <- ["\"limit\"", "\"offset\""], do: {lit, count(source, lit)}

      for {lit, n} <- anchors do
        assert n >= 1,
               "MUTATION ANCHOR #{lit} not found in #{inspect(mod)} — this measured nothing"
      end

      mutated =
        source
        |> String.replace("\"limit\"", "\"lim_mutant\"")
        |> String.replace("\"offset\"", "\"off_mutant\"")

      assert mutated != source, "the mutation of #{inspect(mod)} did not apply"
      assert count(mutated, "\"limit\"") + count(mutated, "\"offset\"") == 0

      population =
        PagedRoutes.derive(BarkparkWeb.Router.__routes__(), fn
          ^mod -> mutated
          other -> PagedRoutes.source_of(other)
        end)

      refute Enum.any?(population, &(&1.key == key)),
             "#{key} is still derived after its paging reads were stripped — the arm does not read what it claims"

      err = assert_raise ExUnit.AssertionError, fn -> assert_router_control!(population) end
      assert err.message =~ key, "the control red, but did not NAME #{key}: #{err.message}"
    end
  end

  defp count(haystack, needle), do: length(String.split(haystack, needle)) - 1

  # ── the two decided endpoints, probed live ──────────────────────────────

  @audit_label "secrets.audit (GET /v1/secrets/:name/audit)"
  @history_label "doc.history (GET /v1/data/history/:dataset/:type/:doc_id)"

  # A truncation OBSERVATION, made from the fixture and the rows — never from
  # the signal under test.
  defp observe(label, corpus, returned),
    do: %{label: label, corpus: corpus, page: @page, returned: returned}

  defp truncated?(%{corpus: c, page: p, returned: r}), do: c > p and r == p

  # NON-VACUITY as an executable refusal: a run in which fewer than `min`
  # probes saw a truncated page proved nothing about continuations.
  defp assert_observed_truncation!(observations, min) do
    seen = Enum.filter(observations, &truncated?/1)

    assert length(seen) >= min,
           """
           VACUOUS RUN: only #{length(seen)} of #{length(observations)} probe(s) observed a truncated
           page (need #{min}). Untruncated: #{observations |> Enum.reject(&truncated?/1) |> Enum.map_join(", ", &"#{&1.label} corpus=#{&1.corpus} returned=#{&1.returned}")}.
           A signal⇒continuation check whose antecedent never held measured nothing.
           """
  end

  # SIGNAL HONESTY, the half the conditional invariant deliberately cannot see:
  # when the FIXTURE proves another page exists (corpus > page, page full),
  # the route must SAY so. Without this a route with no signal at all — the
  # audit route before this row — satisfies signal⇒continuation vacuously.
  defp assert_signal_honest!(%{label: label} = obs, signal) do
    if truncated?(obs) do
      assert signal == true,
             "SILENT TRUNCATION — #{label}: the fixture holds #{obs.corpus} rows and page one returned #{obs.returned} of limit #{obs.page}, yet the paging signal is #{inspect(signal)}. A caller cannot tell this full page from the last one."
    end
  end

  defp seed_audit!(conn, n) do
    name = "pgc_audit_#{System.unique_integer([:positive])}"

    for i <- 1..n//1 do
      resp =
        conn
        |> authed()
        |> put_req_header("content-type", "application/json")
        |> put("/v1/secrets/#{name}", Jason.encode!(%{value: "v#{i}"}))

      assert resp.status == 200,
             "seeding the audit trail failed: #{resp.status} #{resp.resp_body}"
    end

    name
  end

  defp audit_page(conn, name, offset) do
    get_json(conn, "/v1/secrets/#{name}/audit", %{"limit" => "#{@page}", "offset" => "#{offset}"})
  end

  defp seed_history! do
    doc_id = "pgch#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "drafts." <> doc_id, "title" => "v0"},
        @search_dataset
      )

    {:ok, _} = Content.publish_document(doc_id, "post", @search_dataset)

    for i <- 1..@corpus do
      {:ok, _} =
        Content.apply_mutations(
          [%{"patch" => %{"id" => doc_id, "type" => "post", "set" => %{"title" => "v#{i}"}}}],
          @search_dataset
        )
    end

    corpus = doc_id |> Content.list_revisions("post", @search_dataset, limit: 1_000) |> length()
    {doc_id, corpus}
  end

  defp history_page(conn, doc_id, offset) do
    get_json(conn, "/v1/data/history/#{@search_dataset}/post/#{doc_id}", %{
      "limit" => "#{@page}",
      "offset" => "#{offset}"
    })
  end

  defp assert_page_two!(label, first, second, id_key) do
    one = MapSet.new(first, & &1[id_key])
    two = MapSet.new(second, & &1[id_key])
    refute Enum.empty?(two), "#{label}: next_offset was handed back and returned an EMPTY page"
    assert MapSet.disjoint?(one, two), "#{label}: next_offset re-served rows from page one"
  end

  # ── task-fb4cf8323a9795e5's two decided endpoints ───────────────────────────

  @paper_access_label "paper.access (GET /v1/papers/:slug/access)"
  @webhook_deliveries_label "webhook.deliveries (GET /v1/webhooks/:dataset/:id/deliveries)"

  defp seed_paper_access!(slug, workspace_id, n) do
    for i <- 1..n//1 do
      :ok =
        PaperAccess.record_now(%{
          slug: slug,
          dataset: @dataset,
          workspace_id: workspace_id,
          action: "view",
          actor_kind: "anonymous",
          actor_id: nil,
          actor_label: nil
        })

      # record_now has no explicit inserted_at; a tight loop can write several
      # rows in the same microsecond, which is exactly the tie the `id` half of
      # the total order exists to break — nothing to sleep for.
      _ = i
    end

    slug
  end

  defp paper_access_page(conn, slug, offset) do
    get_json(conn, "/v1/papers/#{slug}/access", %{"limit" => "#{@page}", "offset" => "#{offset}"})
  end

  defp make_pagination_event! do
    {:ok, ev} =
      %MutationEvent{}
      |> Ecto.Changeset.change(%{
        dataset: @search_dataset,
        workspace_id: TenancyFixtures.default_workspace_id!(),
        type: "widget",
        doc_id: "pgc-wh-#{System.unique_integer([:positive])}",
        mutation: "publish",
        rev: "rev-#{System.unique_integer([:positive])}",
        document: %{"_id" => "doc", "title" => "pgc"},
        inserted_at: DateTime.utc_now()
      })
      |> Repo.insert()

    ev
  end

  defp seed_webhook_deliveries!(scope, n) do
    {:ok, wh} =
      Webhooks.create_webhook(
        %{
          "name" => "pgc-#{System.unique_integer([:positive])}",
          "url" => "http://example.test/pgc-hook",
          "dataset" => @search_dataset,
          "events" => ["discardDraft"]
        },
        scope
      )

    for i <- 1..n//1 do
      ev = make_pagination_event!()
      {:ok, d} = Webhooks.claim_delivery(wh.id, ev.id)
      {:ok, _} = Webhooks.mark_delivered(d, 200, 1, i)
    end

    wh.id
  end

  defp webhook_deliveries_page(conn, wh_id, offset) do
    get_json(conn, "/v1/webhooks/#{@search_dataset}/#{wh_id}/deliveries", %{
      "limit" => "#{@page}",
      "offset" => "#{offset}"
    })
  end

  describe "(d) the router-arm endpoints this row decided" do
    test "audit and history: has_more ⇒ next_offset ⇒ a real page two, and the run is non-vacuous",
         %{conn: conn} do
      name = seed_audit!(conn, @corpus)
      a1 = audit_page(conn, name, 0)
      assert_signal_honest!(observe(@audit_label, @corpus, length(a1["audit"])), a1["has_more"])
      assert_continuation!(@audit_label, "next_offset", {a1["has_more"], a1["next_offset"]})
      a2 = audit_page(conn, name, a1["next_offset"] || @page)
      assert_page_two!(@audit_label, a1["audit"], a2["audit"], "inserted_at")

      {doc_id, h_corpus} = seed_history!()
      h1 = history_page(conn, doc_id, 0)

      assert_signal_honest!(
        observe(@history_label, h_corpus, length(h1["revisions"])),
        h1["has_more"]
      )

      assert_continuation!(@history_label, "next_offset", {h1["has_more"], h1["next_offset"]})
      h2 = history_page(conn, doc_id, h1["next_offset"] || @page)
      assert_page_two!(@history_label, h1["revisions"], h2["revisions"], "id")

      assert_observed_truncation!(
        [
          observe(@audit_label, @corpus, length(a1["audit"])),
          observe(@history_label, h_corpus, length(h1["revisions"]))
        ],
        2
      )
    end

    test "paper.access and webhook.deliveries: has_more ⇒ next_offset ⇒ a real page two, and the run is non-vacuous",
         %{conn: conn, scope: scope} do
      slug = "pgc-paper-#{System.unique_integer([:positive])}"
      seed_paper_access!(slug, Keyword.get(scope, :workspace_id), @corpus)
      p1 = paper_access_page(conn, slug, 0)

      assert_signal_honest!(
        observe(@paper_access_label, @corpus, length(p1["access"])),
        p1["has_more"]
      )

      assert_continuation!(
        @paper_access_label,
        "next_offset",
        {p1["has_more"], p1["next_offset"]}
      )

      p2 = paper_access_page(conn, slug, p1["next_offset"] || @page)
      assert_page_two!(@paper_access_label, p1["access"], p2["access"], "id")

      wh_id = seed_webhook_deliveries!(scope, @corpus)
      w1 = webhook_deliveries_page(conn, wh_id, 0)

      assert_signal_honest!(
        observe(@webhook_deliveries_label, @corpus, length(w1["deliveries"])),
        w1["has_more"]
      )

      assert_continuation!(
        @webhook_deliveries_label,
        "next_offset",
        {w1["has_more"], w1["next_offset"]}
      )

      w2 = webhook_deliveries_page(conn, wh_id, w1["next_offset"] || @page)
      assert_page_two!(@webhook_deliveries_label, w1["deliveries"], w2["deliveries"], "event_id")

      assert_observed_truncation!(
        [
          observe(@paper_access_label, @corpus, length(p1["access"])),
          observe(@webhook_deliveries_label, @corpus, length(w1["deliveries"]))
        ],
        2
      )
    end

    test "the last page says so: has_more false and next_offset nil", %{conn: conn} do
      name = seed_audit!(conn, @corpus)
      last = audit_page(conn, name, @corpus - 1)
      assert length(last["audit"]) == 1
      assert last["has_more"] == false
      assert is_nil(last["next_offset"])
    end

    test "NON-VACUITY reds when the fixture shrinks below the page", %{conn: conn} do
      name = seed_audit!(conn, 1)
      shrunk = audit_page(conn, name, 0)
      assert length(shrunk["audit"]) == 1, "the shrunk fixture should return one row"

      assert_raise ExUnit.AssertionError, ~r/VACUOUS RUN/, fn ->
        assert_observed_truncation!([observe(@audit_label, 1, length(shrunk["audit"]))], 1)
      end
    end

    test "MUTATION, both directions: drop the continuation and it reds; drop the signal and it stays green",
         %{conn: conn} do
      name = seed_audit!(conn, @corpus)
      {doc_id, _} = seed_history!()

      for {label, b} <- [
            {@audit_label, audit_page(conn, name, 0)},
            {@history_label, history_page(conn, doc_id, 0)}
          ] do
        assert b["has_more"] == true and is_integer(b["next_offset"]),
               "#{label}: the probe never reached the state the mutation breaks"

        # 1. Continuation withheld: the guard must red, naming the surface.
        no_cont = Map.delete(b, "next_offset")
        assert no_cont != b, "mutation 1 did not apply"

        err =
          assert_raise ExUnit.AssertionError, fn ->
            assert_continuation!(
              label,
              "next_offset",
              {no_cont["has_more"], no_cont["next_offset"]}
            )
          end

        assert err.message =~ "CONTINUATION WITHHELD — #{label}"

        # 2. Signal forced false: the invariant is CONDITIONAL, so this is green.
        no_signal = Map.put(b, "has_more", false) |> Map.delete("next_offset")
        assert no_signal != b, "mutation 2 did not apply"

        assert_continuation!(
          label,
          "next_offset",
          {no_signal["has_more"], no_signal["next_offset"]}
        )
      end
    end
  end
end
