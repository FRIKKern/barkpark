defmodule Barkpark.Tasks.DedupTest do
  @moduledoc """
  DB-backed tests for the find-or-create gate (task-obsession layer 1), driven
  through the real `Content.create_document/4` write path so the Writer hook,
  the candidate query, and the escape hatches are all exercised end-to-end.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Tasks, TenancyFixtures}

  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)
    %{scope: scope}
  end

  defp register_schemas!(scope) do
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  defp create_task(doc_id, title, scope, content_extra) do
    content =
      Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, content_extra)

    Content.create_document(
      "task",
      %{"doc_id" => doc_id, "title" => title, "content" => content},
      @dataset,
      scope
    )
  end

  @rate_limit "add rate limiting to the mutate controller"
  @rate_limit_desc "throttle writes on the REST mutate endpoint per token bucket"

  test "a near-duplicate cross-epic task is REFUSED with the similar list", %{scope: scope} do
    {:ok, _} =
      create_task("existing-rl", @rate_limit, scope, %{
        "description" => @rate_limit_desc,
        "parent_id" => "epic-a"
      })

    assert {:error, {:duplicate_task, payload}} =
             create_task("new-rl", @rate_limit, scope, %{
               "description" => @rate_limit_desc,
               "parent_id" => "epic-b"
             })

    assert [%{id: "existing-rl"} | _] = payload.similar
  end

  test "a same-parent sibling is ALLOWED even when lexically near-identical", %{scope: scope} do
    {:ok, _} =
      create_task("sib-1", @rate_limit, scope, %{
        "description" => @rate_limit_desc,
        "parent_id" => "shared-epic"
      })

    # Same parent → structural sibling → never a duplicate.
    assert {:ok, _} =
             create_task("sib-2", @rate_limit, scope, %{
               "description" => @rate_limit_desc,
               "parent_id" => "shared-epic"
             })
  end

  test "distinct_from naming the match ALLOWS the create and persists the trail", %{scope: scope} do
    {:ok, _} =
      create_task("orig-rl", @rate_limit, scope, %{
        "description" => @rate_limit_desc,
        "parent_id" => "epic-a"
      })

    assert {:ok, doc} =
             create_task("clone-rl", @rate_limit, scope, %{
               "description" => @rate_limit_desc,
               "parent_id" => "epic-b",
               "distinct_from" => ["orig-rl"]
             })

    # The escape hatch is persisted on the doc as the queryable rejection trail.
    assert doc.content["distinct_from"] == ["orig-rl"]
  end

  test "a genuinely distinct task is ALLOWED", %{scope: scope} do
    {:ok, _} =
      create_task("rl", @rate_limit, scope, %{
        "description" => @rate_limit_desc,
        "parent_id" => "epic-a"
      })

    assert {:ok, _} =
             create_task("reader", "render markdown headings in the article reader", scope, %{
               "description" => "heading rhythm and vertical spacing in the paper reader",
               "parent_id" => "epic-b"
             })
  end

  test "a CANCELLED task never blocks a legitimate re-attempt (criterion 4)", %{scope: scope} do
    {:ok, _} =
      create_task("abandoned-rl", @rate_limit, scope, %{
        "description" => @rate_limit_desc,
        "parent_id" => "epic-a",
        "lifecycle_status" => "cancelled"
      })

    # We decided not to do it → re-proposing the same work must be allowed.
    assert {:ok, _} =
             create_task("retry-rl", @rate_limit, scope, %{
               "description" => @rate_limit_desc,
               "parent_id" => "epic-b"
             })
  end

  test "a DONE task DOES still surface (already-landed signal)", %{scope: scope} do
    {:ok, _} =
      create_task("shipped-rl", @rate_limit, scope, %{
        "description" => @rate_limit_desc,
        "parent_id" => "epic-a",
        "lifecycle_status" => "done"
      })

    assert {:error, {:duplicate_task, payload}} =
             create_task("redo-rl", @rate_limit, scope, %{
               "description" => @rate_limit_desc,
               "parent_id" => "epic-b"
             })

    assert Enum.any?(payload.similar, &(&1.lifecycle_status == "done"))
  end

  # ── the gate SAYS WHAT IT COULD NOT DO ─────────────────────────────────────
  #
  # The 2026-07-30 outage: the candidate scan lost its race with the 15 s DB
  # checkout budget, the old code swallowed that into an empty candidate set,
  # and the create either sailed through unchecked or died as
  # `internal_error / "unknown error"`. Both are the same lie — a create
  # reporting success on a duplicate check that never ran.

  # A REAL, unmocked scan failure, driven through the production code path: the
  # candidate query is built with an unusable workspace scope, so `Repo.all`
  # raises before it can produce a candidate set. What matters is that the gate
  # cannot compute its answer — the same state the 15 s checkout timeout left it
  # in — and that it says so instead of returning an empty backlog.
  defp check_with_failing_scan(doc_id, title, content) do
    Barkpark.Tasks.Dedup.check_new_task(
      "task",
      %{"doc_id" => doc_id, "title" => title, "content" => content},
      @dataset,
      nil,
      workspace_id: "not-a-uuid-so-the-scan-cannot-run"
    )
  end

  describe "degraded candidate scan" do
    test "REFUSES with a message naming what could not be done — never a silent pass" do
      assert {:error, {:dedup_unavailable, message}} =
               check_with_failing_scan("deg-new", @rate_limit, %{
                 "kind" => "task",
                 "description" => @rate_limit_desc
               })

      # The body names the gate, the failure, the consequence and the way out.
      assert message =~ "task dedup gate could not complete"
      assert message =~ "the backlog scan"
      assert message =~ "REFUSED rather than filed unchecked"
      assert message =~ "no duplicate check ran"
      assert message =~ "content.dedup_bypass: true"
      refute message =~ "unknown error"
    end

    test "the refusal renders as a NAMED error body, not internal_error/unknown error" do
      assert {:error, {:dedup_unavailable, _}} =
               result = check_with_failing_scan("deg-env", @rate_limit, %{"kind" => "task"})

      env = Barkpark.Content.Errors.to_envelope(result)

      refute env.code == "internal_error"
      refute env.message == "unknown error"
      # 503, not the plugin-veto 409: a dedup outage is TRANSIENT, and the code
      # is what tells an unattended caller (Github.Intake) to come back rather
      # than treat the refusal as a permanent policy decision and drop the row.
      # On the wire this stays 409 `halted` for now: a new public code must be
      # registered in known_codes/0, which docs/api-v1.md §9 must then document,
      # and §9 has 3 bytes of headroom against a CI-enforced cap. The INTERNAL
      # tag is what had to split; the wire upgrade to a 503 dedup_unavailable is
      # named as next-wave work, not claimed here.
      assert env.status == 409

      # THE TRIPWIRE. `:halted` is the plugin-VETO tag, and consumers treat it
      # as deterministic: `Plugins.Github.Intake` answers a clean 2xx on
      # `{:error, {:halted, _}}` on the explicit reasoning that "GitHub
      # redelivery would only hit the same veto forever". A dedup outage is
      # TRANSIENT, so wearing that tag would make an unattended intake drop the
      # issue permanently and log it as a policy refusal that never happened.
      # If a future change borrows `:halted` here again, this reds.
      refute match?({:error, {:halted, _}}, result)
      assert env.message =~ "task dedup gate could not complete"
    end

    test "the bypass is an OWNER decision, not a server shortcut — it skips a real duplicate", %{
      scope: scope
    } do
      {:ok, _} =
        create_task("byp2-existing", @rate_limit, scope, %{
          "description" => @rate_limit_desc,
          "parent_id" => "epic-a"
        })

      # Same text, healthy scan: without the flag this is a hard refuse.
      assert {:error, {:duplicate_task, _}} =
               create_task("byp2-no-flag", @rate_limit, scope, %{
                 "description" => @rate_limit_desc,
                 "parent_id" => "epic-b"
               })

      assert {:ok, doc} =
               create_task("byp2-flag", @rate_limit, scope, %{
                 "description" => @rate_limit_desc,
                 "parent_id" => "epic-b",
                 "dedup_bypass" => true
               })

      # The flag persists on the document as the queryable trail — the same
      # shape as `distinct_from`, so "who waved this through" stays answerable.
      assert doc.content["dedup_bypass"] == true
    end
  end

  # ── bounded candidate fetch ────────────────────────────────────────────────

  # `Content.create_document/4` always writes a DRAFT (`drafts.<id>`), so a real
  # twin pair is a published row alongside its draft — the shape every
  # edited-then-published task on the live corpus has. Mirror the draft row into
  # a published one to build it.
  defp publish_twin_of!(%Barkpark.Content.Document{} = draft, published_id) do
    draft
    |> Map.from_struct()
    |> Map.drop([
      :__meta__,
      :id,
      :inserted_at,
      :updated_at,
      :search_vector,
      :task_edges,
      :tags_meta,
      :slug_text,
      :author_text,
      :category_text
    ])
    |> Map.merge(%{doc_id: published_id, status: "published"})
    |> then(&struct(Barkpark.Content.Document, &1))
    |> Barkpark.Repo.insert!()
  end

  describe "candidate projection + twin collapse" do
    test "a draft/published TWIN pair is scored and reported ONCE, not twice", %{scope: scope} do
      {:ok, draft} =
        create_task("twin-rl", @rate_limit, scope, %{
          "description" => @rate_limit_desc,
          "parent_id" => "epic-a"
        })

      assert draft.doc_id == "drafts.twin-rl"
      published = publish_twin_of!(draft, "twin-rl")
      assert published.doc_id == "twin-rl"

      assert {:error, {:duplicate_task, payload}} =
               create_task("twin-new", @rate_limit, scope, %{
                 "description" => @rate_limit_desc,
                 "parent_id" => "epic-b"
               })

      # DISTINCT ON the drafts-stripped id: one row survives per task, and it is
      # the PUBLISHED one. Before the fix both rows were fetched and scored, and
      # `similar` carried the same task twice.
      assert Enum.count(payload.similar, &(&1.id == "twin-rl")) == 1
      assert [%{id: "twin-rl"}] = payload.similar
    end

    test "detection is unchanged for a task that exists ONLY as a draft", %{scope: scope} do
      # No published counterpart: the draft is the one surviving row and must
      # still block. Collapsing twins narrowed nothing.
      {:ok, draft} =
        create_task("only-draft-rl", @rate_limit, scope, %{
          "description" => @rate_limit_desc,
          "parent_id" => "epic-a"
        })

      assert draft.doc_id == "drafts.only-draft-rl"

      assert {:error, {:duplicate_task, payload}} =
               create_task("only-draft-new", @rate_limit, scope, %{
                 "description" => @rate_limit_desc,
                 "parent_id" => "epic-b"
               })

      # `present/1` reports the canonical id, so the drafts-only row shows up
      # under the id the author would reference.
      assert [%{id: "only-draft-rl"}] = payload.similar
    end

    test "the projected row still carries every scored field (labels included)", %{scope: scope} do
      {:ok, _} =
        create_task("proj-a", "alpha beta gamma delta", scope, %{
          "parent_id" => "epic-a",
          "labels" => ["proj:x", "phase:1"]
        })

      # Disjoint titles; only the labels can push this over the advise floor, so
      # a lost `labels` projection would make this create succeed.
      assert {:error, {:duplicate_task, payload}} =
               create_task("proj-b", "alpha beta gamma epsilon", scope, %{
                 "parent_id" => "epic-b",
                 "labels" => ["proj:x", "phase:1"]
               })

      assert [%{id: "proj-a"} | _] = payload.similar
    end
  end

  # ── tier-2 judge escalation ────────────────────────────────────────────────

  defmodule FakeJudge do
    def post(_url, _body, _headers) do
      case Application.get_env(:barkpark, :judge_fake) do
        {:ok, text} -> {:ok, 200, %{"content" => [%{"type" => "text", "text" => text}]}}
        {:error, r} -> {:error, r}
        other -> other
      end
    end
  end

  # A cross-epic pair with partial token overlap → lands in the ADVISE band
  # (sim ~0.42, below the 0.55 refuse floor), which is exactly where the judge
  # is consulted.
  @adv_title_a "alpha beta gamma delta"
  @adv_title_b "alpha beta gamma zeta"

  defp with_judge(fake) do
    Application.put_env(:barkpark, :judge_http_adapter, FakeJudge)
    Application.put_env(:barkpark, :anthropic_api_key, "sk-test")
    Application.put_env(:barkpark, :judge_fake, fake)

    on_exit(fn ->
      Application.delete_env(:barkpark, :judge_http_adapter)
      Application.delete_env(:barkpark, :anthropic_api_key)
      Application.delete_env(:barkpark, :judge_fake)
    end)
  end

  describe "tier-2 judge escalation" do
    test "a judged 'duplicate' escalates an advise-band match to a REFUSE", %{scope: scope} do
      with_judge({:ok, ~s({"relation":"duplicate","confidence":0.9,"reason":"same"})})
      {:ok, _} = create_task("adv-a", @adv_title_a, scope, %{"parent_id" => "epic-a"})

      assert {:error, {:duplicate_task, payload}} =
               create_task("adv-b", @adv_title_b, scope, %{"parent_id" => "epic-b"})

      assert Enum.any?(payload.similar, &(&1.id == "adv-a"))
    end

    test "a judged 'distinct' leaves the advise match non-blocking (create allowed)", %{
      scope: scope
    } do
      with_judge({:ok, ~s({"relation":"distinct","confidence":0.9,"reason":"different"})})
      {:ok, _} = create_task("adv-a2", @adv_title_a, scope, %{"parent_id" => "epic-a"})

      assert {:ok, _} = create_task("adv-b2", @adv_title_b, scope, %{"parent_id" => "epic-b"})
    end

    test "a judge error fails open — the advise match does not block", %{scope: scope} do
      with_judge({:error, :timeout})
      {:ok, _} = create_task("adv-a3", @adv_title_a, scope, %{"parent_id" => "epic-a"})

      assert {:ok, _} = create_task("adv-b3", @adv_title_b, scope, %{"parent_id" => "epic-b"})
    end

    test "low judge confidence does not escalate", %{scope: scope} do
      with_judge({:ok, ~s({"relation":"duplicate","confidence":0.4,"reason":"maybe"})})
      {:ok, _} = create_task("adv-a4", @adv_title_a, scope, %{"parent_id" => "epic-a"})

      assert {:ok, _} = create_task("adv-b4", @adv_title_b, scope, %{"parent_id" => "epic-b"})
    end
  end

  # ── a malformed backlog row must not take down creation for everyone ───────
  #
  # MEASURED LIVE 2026-08-01 (PDS wave 33): EVERY `type:task` create against
  # guerrilla was refused 409 `halted` with "the backlog scan failed
  # (Protocol.UndefinedError)", until callers learned to pass `dedup_bypass` —
  # which disables duplicate detection fleet-wide. The gate itself behaved
  # correctly: it failed CLOSED and named its own bypass. The defect was that a
  # single poisoned row could put the gate into that state for every caller.
  #
  # THE POISON: `fetch_candidates/2` projects `content->'labels'` as RAW JSONB
  # (every other projected field uses `->>`, which is always text-or-NULL). That
  # raw term is fed to `to_string/1`, which has no `String.Chars` implementation
  # for a map — so ONE task row whose `content.labels` holds objects instead of
  # strings raises `Protocol.UndefinedError` inside the scan.
  #
  # The row is planted with a direct `Repo.insert!` ON PURPOSE: the write path
  # would coerce it, and the whole point is a row that arrived through a
  # non-`bp` path (a migration, a restore, a hand-written INSERT).
  defp plant_poisoned_row!(doc_id, labels, scope) do
    Barkpark.Repo.insert!(%Barkpark.Content.Document{
      doc_id: doc_id,
      type: "task",
      dataset: @dataset,
      status: "published",
      rev: Ecto.UUID.generate(),
      title: "poisoned backlog row",
      workspace_id: Keyword.fetch!(scope, :workspace_id),
      project_id: Keyword.fetch!(scope, :project_id),
      content: %{
        "kind" => "task",
        "lifecycle_status" => "open",
        "description" => "a row written through a non-bp path",
        "labels" => labels
      }
    })
  end

  describe "a malformed candidate row" do
    # The exact live shape: `labels` holding weighted-tag OBJECTS (the same
    # shape `content.tags` legitimately carries) instead of bare strings.
    @poison_shapes %{
      "a list of objects" => [%{"tag" => "pds", "strength" => 86}],
      "a bare object" => %{"tag" => "pds"},
      "a list mixing strings and objects" => ["pds", %{"tag" => "elixir"}]
    }

    for {label, shape} <- @poison_shapes do
      @shape shape
      @label label

      test "#{label} in content.labels does NOT take the gate down", %{scope: scope} do
        plant_poisoned_row!("poison-#{:erlang.phash2(@label)}", @shape, scope)

        # THE REGRESSION. Before the fix this was
        # {:error, {:dedup_unavailable, "... the backlog scan failed
        # (Protocol.UndefinedError) ..."}} — for EVERY caller, on every create,
        # regardless of what the caller sent.
        assert {:ok, _} =
                 create_task("clean-#{:erlang.phash2(@label)}", "an unrelated new task", scope, %{
                   "description" => "nothing like the poisoned row"
                 })
      end
    end

    test "the malformed row is REPORTED by doc_id, not silently swallowed", %{scope: scope} do
      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          plant_poisoned_row!("poison-reported", [%{"tag" => "pds"}], scope)

          assert {:ok, _} =
                   create_task("clean-reported", "an unrelated new task", scope, %{
                     "description" => "nothing like the poisoned row"
                   })
        end)

      # Resilience must not become a blind spot: the scan survives the row AND
      # says which row it was, so the poison can be found and fixed at source.
      assert log =~ "poison-reported"
      assert log =~ "labels"
    end

    test "the poisoned row still PARTICIPATES in detection — it is not dropped", %{scope: scope} do
      # A row with unusable labels keeps its title/description signal, which is
      # 0.7 of the score. Degrading `labels` must not amount to deleting the row
      # from the backlog: that would silently punch a hole in dedup coverage.
      Barkpark.Repo.insert!(%Barkpark.Content.Document{
        doc_id: "poison-dup",
        type: "task",
        dataset: @dataset,
        status: "published",
        rev: Ecto.UUID.generate(),
        title: @rate_limit,
        workspace_id: Keyword.fetch!(scope, :workspace_id),
        project_id: Keyword.fetch!(scope, :project_id),
        content: %{
          "kind" => "task",
          "lifecycle_status" => "open",
          "description" => @rate_limit_desc,
          "parent_id" => "epic-a",
          "labels" => [%{"tag" => "pds"}]
        }
      })

      assert {:error, {:duplicate_task, payload}} =
               create_task("poison-dup-new", @rate_limit, scope, %{
                 "description" => @rate_limit_desc,
                 "parent_id" => "epic-b"
               })

      assert Enum.any?(payload.similar, &(&1.id == "poison-dup"))
    end

    # The SECOND hole, same root cause, different blast radius. `string_list/1`
    # also runs over the NEW task's own content in `to_task/2` — which is
    # OUTSIDE `fetch_candidates/2`'s rescue. There the same `to_string/1` on a
    # map was an UNHANDLED raise, i.e. a 500, not a named refusal. MEASURED on
    # the pre-fix tree, verbatim:
    #
    #   ** (Protocol.UndefinedError) protocol String.Chars not implemented for Map
    #       (barkpark) lib/barkpark/tasks/dedup.ex:287: Barkpark.Tasks.Dedup.to_task/2
    #
    # It is driven through `check_new_task/5` DIRECTLY on purpose:
    # `Content.create_document/4` normalises content against the schema first,
    # so the write path never delivered this shape and the hole was invisible
    # from there. Anything calling the gate without that normalisation — another
    # plugin, an internal caller, a future write path — got the 500.
    test "a CALLER's own object-shaped labels do not raise out of the gate", %{scope: scope} do
      assert :ok =
               Barkpark.Tasks.Dedup.check_new_task(
                 "task",
                 %{
                   "doc_id" => "caller-poison",
                   "title" => "a task with object labels",
                   "content" => %{
                     "kind" => "task",
                     "description" => "labels arrived as weighted-tag objects",
                     "labels" => [%{"tag" => "pds", "strength" => 86}]
                   }
                 },
                 @dataset,
                 nil,
                 scope
               )
    end
  end

  # ── the upsert INSERT branch (pds-bl-upsert-insert-branch-ungated-birth) ──
  #
  # `do_upsert_document` has its own insert branch (prev_doc nil -> Repo.insert)
  # and its `with` chain used to call NEITHER dedup arm — run-proven on the
  # pre-fix tree: `Content.create_document` REFUSED a near-duplicate
  # ({:error, {:duplicate_task, _}}) while `Content.upsert_document` on the
  # SAME attrs and an unseen doc_id BIRTHED it (drafts.probe-dup-upsert
  # persisted). These pin the gate now riding that branch.
  describe "upsert insert-branch birth gate" do
    @up_title "add rate limiting to the mutate controller"
    @up_desc "throttle writes on the REST mutate endpoint per token bucket"

    test "an upsert onto an UNSEEN doc_id is a birth and the duplicate is REFUSED", %{
      scope: scope
    } do
      {:ok, _} =
        create_task("up-existing", @up_title, scope, %{
          "description" => @up_desc,
          "parent_id" => "epic-a"
        })

      assert {:error, {:duplicate_task, payload}} =
               Content.upsert_document(
                 "task",
                 %{
                   "doc_id" => "up-dup",
                   "title" => @up_title,
                   "content" => %{
                     "kind" => "task",
                     "lifecycle_status" => "open",
                     "description" => @up_desc,
                     "parent_id" => "epic-b"
                   }
                 },
                 @dataset,
                 scope
               )

      assert [%{id: "up-existing"} | _] = payload.similar

      # Nothing was born: neither the draft nor a published twin exists.
      assert {:error, :not_found} =
               Content.get_document("drafts.up-dup", "task", @dataset, scope)
    end

    test "an upsert onto a LIVE row is an update and stays ungated (autosave parity)", %{
      scope: scope
    } do
      {:ok, _} =
        create_task("up-live", @up_title, scope, %{
          "description" => @up_desc,
          "parent_id" => "epic-a"
        })

      # Same near-duplicate text, but prev_doc resolves — the guard head-matches
      # prev_doc == nil and must not fire on an update.
      assert {:ok, doc} =
               Content.upsert_document(
                 "task",
                 %{
                   "doc_id" => "up-live",
                   "title" => @up_title,
                   "content" => %{
                     "kind" => "task",
                     "lifecycle_status" => "open",
                     "description" => @up_desc <> " (edited)",
                     "parent_id" => "epic-a"
                   }
                 },
                 @dataset,
                 scope
               )

      assert doc.content["description"] =~ "(edited)"
    end
  end
end
