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
  alias Barkpark.Plugins.Capabilities

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
end
