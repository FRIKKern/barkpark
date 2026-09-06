defmodule Barkpark.Tasks.EdgesTwinCanonicalTest do
  @moduledoc """
  TWIN-EDGE CANONICALISATION (task-85bba5cb33dbd59b).

  `task_edges` FKs reference `documents.id`, a PER-ROW uuid, so an edge binds to
  ONE twin. The ready query's twin-collapse axis surfaces the PUBLISHED row, so
  a `blocks` edge filed onto the DRAFT twin's uuid did not gate the row anybody
  can actually claim — a blocker that silently does not block. `queue.ex`
  documents the gap and names this cure: canonicalise edge endpoints to the
  published uuid on the WRITE path, which is cold, rather than resolving twins
  inside the hot ready query.

  RED-WITHOUT / GREEN-WITH: with `canonical_endpoint/1` disarmed, the
  canonicalisation tests below store the draft's uuid and the gating test shows
  the published row ungated. The PRESERVATION tests are green on origin/main and
  must STAY green — an unpaired draft must keep its own edges, or the fix would
  make a real blocker vanish instead of moving it.

  ENDPOINT SHAPE (task-8f9d3ea8926f387f). The tests hand `Tasks.add_dep/3` the
  `%Document{}` structs, exactly as the one production writer
  (`TasksController.add_edge/2`) does after its scoped pre-flight, because the
  twin lookup derives its scope from the struct and never reads an endpoint
  back by primary key (a by-PK `Repo.get(Document, id)` carries no tenant
  clause — `scripts/tenant-scope-check.sh`). A bare uuid is stored as given;
  the "endpoint shape" block pins both halves of that contract and the
  workspace axis of the twin fence.
  """

  use Barkpark.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.Edge

  @dataset "production"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
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

    %{scope: scope}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # `Content.create_document/4` ALWAYS lands `drafts.<id>` — passing an
  # already-prefixed id does not make a second, distinct row, it makes the same
  # one. So a real twin PAIR needs an actual publish, and a publish must clear
  # the authoring wall's label spine: a 20+ character description AND 1-12
  # weighted tags that are themselves registered `type:tag` documents.
  # `Barkpark.LabelFixtures.with_registered_labels/2` is the helper that
  # registers them, and `dedup_draft_debris_test.exs` uses it for the same
  # reason.
  @desc "A twin-edge canonicalisation fixture row for task-85bba5cb33dbd59b."

  defp mk_draft!(scope, slug, lifecycle \\ "open") do
    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => slug,
          "title" => slug,
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => lifecycle,
            "description" => @desc
          }
        },
        @dataset,
        scope
      )

    doc
  end

  # A draft AND its published twin, as two distinct rows sharing one slug —
  # the shape the (doc_id, type, dataset_id) index permits and the ready
  # query's twin-collapse axis folds.
  defp mk_twins!(scope, slug, lifecycle \\ "open") do
    content =
      Barkpark.LabelFixtures.with_registered_labels(
        %{"kind" => "task", "lifecycle_status" => lifecycle, "description" => @desc},
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        "task",
        %{"doc_id" => slug, "title" => slug, "content" => content},
        @dataset,
        scope
      )

    {:ok, published} = Content.publish_document(slug, "task", @dataset, scope)

    assert published.doc_id == slug,
           "the fixture must actually be PUBLISHED for this test to mean anything"

    # Re-create the draft shadow a published-task mutate leaves behind.
    draft = mk_draft!(scope, slug, lifecycle)

    refute draft.id == published.id, "the fixture did not produce two distinct rows"
    {draft, published}
  end

  defp edge_endpoints(from_id) do
    Repo.all(from(e in Edge, where: e.from_id == ^from_id, select: {e.from_id, e.to_id}))
  end

  describe "an edge filed on a DRAFT twin" do
    test "is stored against the PUBLISHED twin's uuid", %{scope: scope} do
      slug = uniq("blocker")
      {draft, published} = mk_twins!(scope, slug)
      dependent = mk_draft!(scope, uniq("dependent"))

      # The caller names the DRAFT twin — which is what a client holding a
      # drafts.<id> uuid does today.
      assert {:ok, %Edge{}} = Tasks.add_dep(dependent, draft, :blocks)

      assert [{_from, to}] = edge_endpoints(dependent.id)

      assert to == published.id,
             "the edge bound to the draft twin, so it cannot gate the row ready serves"

      refute to == draft.id
    end

    test "canonicalises the DEPENDENT side too, not only the blocker",
         %{scope: scope} do
      slug = uniq("dependent")
      {draft, published} = mk_twins!(scope, slug)
      blocker = mk_draft!(scope, uniq("blocker"))

      assert {:ok, %Edge{}} = Tasks.add_dep(draft, blocker, :blocks)

      # `from_id` is the row the ready query correlates on
      # (`e.from_id == parent_as(:doc).id`), so a draft-bound FROM endpoint
      # leaves the published row ungated just as surely as a draft-bound TO.
      assert [{from, _to}] = edge_endpoints(published.id)
      assert from == published.id
      assert edge_endpoints(draft.id) == []
    end
  end

  describe "preservation — the shapes that must NOT be rewritten" do
    test "an UNPAIRED draft keeps its own uuid", %{scope: scope} do
      # queue.ex axis 3 suppresses a draft only when a published twin EXISTS,
      # so an unpaired draft is served as itself and its edges must keep
      # binding to it. Rewriting here would make the blocker vanish.
      draft = mk_draft!(scope, uniq("lonely"))
      dependent = mk_draft!(scope, uniq("dependent"))

      assert {:ok, %Edge{}} = Tasks.add_dep(dependent, draft, :blocks)
      assert [{_from, to}] = edge_endpoints(dependent.id)
      assert to == draft.id
    end

    test "an already-published endpoint is untouched", %{scope: scope} do
      {_d, blocker} = mk_twins!(scope, uniq("published-blocker"))
      dependent = mk_draft!(scope, uniq("dependent"))

      assert {:ok, %Edge{}} = Tasks.add_dep(dependent, blocker, :blocks)
      assert [{_from, to}] = edge_endpoints(dependent.id)
      assert to == blocker.id
    end

    test "a same-slug row in ANOTHER dataset is never adopted as the twin",
         %{scope: scope} do
      slug = uniq("cross-dataset")
      draft = mk_draft!(scope, slug)

      # The foreign row must be genuinely PUBLISHED in the other dataset, so its
      # doc_id is the BARE slug — the exact string the twin lookup searches for.
      # An unpublished `drafts.<slug>` there would make this test pass for the
      # wrong reason: the lookup would find nothing whether or not the dataset
      # scope existed, and dropping the scope would not red it.
      foreign_content =
        Barkpark.LabelFixtures.with_registered_labels(
          %{"kind" => "task", "lifecycle_status" => "open", "description" => @desc},
          "aker-brygge"
        )

      {:ok, _} =
        Content.create_document(
          "task",
          %{
            "doc_id" => slug,
            "title" => "a same-slug row in another dataset",
            "content" => foreign_content
          },
          "aker-brygge",
          scope
        )

      {:ok, foreign} = Content.publish_document(slug, "task", "aker-brygge", scope)

      assert foreign.doc_id == slug,
             "the foreign row must be PUBLISHED or the dataset fence is never exercised"

      dependent = mk_draft!(scope, uniq("dependent"))

      # The twin lookup is scoped on every axis the uniqueness index carries.
      # Adopting a foreign dataset's row would silently move a blocker across
      # a tenancy boundary.
      assert {:ok, %Edge{}} = Tasks.add_dep(dependent, draft, :blocks)
      assert [{_from, to}] = edge_endpoints(dependent.id)
      assert to == draft.id
      refute to == foreign.id
    end
  end

  describe "endpoint shape — structs canonicalise, uuids are stored as given" do
    test "a same-slug PUBLISHED row in ANOTHER workspace is never adopted as the twin" do
      # Both rows are WORKSPACE-ONLY (no project) on purpose. `fetch_twin/2`
      # scopes on workspace_id AND project_id, and a project can never belong
      # to two workspaces, so with projects set the project clause alone would
      # fence the foreign row and dropping the WORKSPACE clause could not red
      # this test. With project nil on both sides the workspace clause is the
      # only thing between the draft and the other tenant's published row —
      # remove `scope_twin(:workspace_id, …)` and `to == foreign.id`.
      slug = uniq("cross-workspace")
      ws_a = TenancyFixtures.create_workspace!()
      ws_b = TenancyFixtures.create_workspace!()
      scope_a = [workspace_id: ws_a.id]
      scope_b = [workspace_id: ws_b.id]

      draft = mk_draft!(scope_a, slug)
      assert %Document{workspace_id: draft_ws} = draft
      assert draft_ws == ws_a.id
      assert is_nil(draft.project_id)

      foreign_content =
        Barkpark.LabelFixtures.with_registered_labels(
          %{"kind" => "task", "lifecycle_status" => "open", "description" => @desc},
          @dataset
        )

      {:ok, _} =
        Content.create_document(
          "task",
          %{
            "doc_id" => slug,
            "title" => "a same-slug row in another workspace",
            "content" => foreign_content
          },
          @dataset,
          scope_b
        )

      {:ok, foreign} = Content.publish_document(slug, "task", @dataset, scope_b)

      assert foreign.doc_id == slug,
             "the foreign row must be PUBLISHED or the workspace fence is never exercised"

      assert foreign.workspace_id == ws_b.id
      assert is_nil(foreign.project_id)

      dependent = mk_draft!(scope_a, uniq("dependent"))

      assert {:ok, %Edge{}} = Tasks.add_dep(dependent, draft, :blocks)
      assert [{_from, to}] = edge_endpoints(dependent.id)
      assert to == draft.id
      refute to == foreign.id
    end

    test "a bare uuid endpoint is stored AS GIVEN — no read back, no twin swap",
         %{scope: scope} do
      # This is the other half of removing the by-PK read: with only an id in
      # hand there is no tenant-scoped way to learn the row's scope, so the
      # module does not try. A caller that wants canonicalisation passes the
      # struct it resolved. Pinning this keeps the contract explicit rather
      # than letting a future "helpful" `Repo.get(Document, id)` creep back in.
      {draft, published} = mk_twins!(scope, uniq("blocker"))
      dependent = mk_draft!(scope, uniq("dependent"))

      assert {:ok, %Edge{}} = Tasks.add_dep(dependent.id, draft.id, :blocks)
      assert [{_from, to}] = edge_endpoints(dependent.id)
      assert to == draft.id
      refute to == published.id
    end
  end

  # THE BACKFILL (criterion 2). The write-path fix only canonicalises NEW edges;
  # every edge written before it still binds a draft twin. The migration
  # 20260905160000_backfill_twin_canonical_task_edges re-points them. These
  # tests drive the SAME set-based SQL against edges planted directly, because
  # going through add_dep/3 would canonicalise them on the way in and there
  # would be nothing left to back-fill.
  describe "the backfill" do
    defp plant_edge!(from_id, to_id, kind \\ "blocks") do
      {:ok, edge} =
        Repo.insert(Ecto.Changeset.change(%Edge{}, %{from_id: from_id, to_id: to_id, kind: kind}))

      edge
    end

    # The MIGRATION is a thin caller around this function; a migration body
    # needs a runner process and cannot be driven from a test, so the logic is
    # tested where it lives.
    defp run_backfill!, do: Barkpark.Tasks.Edges.backfill_twin_canonical_edges()

    test "re-points a pre-existing draft-bound edge onto the published twin",
         %{scope: scope} do
      {draft, published} = mk_twins!(scope, uniq("blocker"))
      dependent = mk_draft!(scope, uniq("dependent"))

      plant_edge!(dependent.id, draft.id)
      assert [{_f, to}] = edge_endpoints(dependent.id)
      assert to == draft.id, "the fixture must start DRAFT-bound or it back-fills nothing"

      run_backfill!()

      assert [{_f, to_after}] = edge_endpoints(dependent.id)
      assert to_after == published.id
    end

    test "leaves an UNPAIRED draft's edge alone", %{scope: scope} do
      lonely = mk_draft!(scope, uniq("lonely"))
      dependent = mk_draft!(scope, uniq("dependent"))
      plant_edge!(dependent.id, lonely.id)

      run_backfill!()

      assert [{_f, to}] = edge_endpoints(dependent.id)
      assert to == lonely.id
    end

    test "DELETES the redundant duplicate instead of colliding on the unique index",
         %{scope: scope} do
      # The canonical edge already exists, so re-pointing its draft-bound
      # sibling onto the same (from_id, to_id, kind) triple would violate the
      # index and abort the whole migration. The duplicate must be removed
      # first — it is the same dependency stated twice, not lost information.
      {draft, published} = mk_twins!(scope, uniq("blocker"))
      dependent = mk_draft!(scope, uniq("dependent"))

      plant_edge!(dependent.id, published.id)
      plant_edge!(dependent.id, draft.id)
      assert length(edge_endpoints(dependent.id)) == 2

      run_backfill!()

      # Bind first, then assert on a boolean: `assert pattern = expr, "msg"`
      # raises MatchError before assert/2 can ever reach the message, so the
      # message is dead code (scripts/unreachable-assert-message-check.sh).
      remaining = edge_endpoints(dependent.id)

      assert length(remaining) == 1,
             "the collision was not de-duplicated — the migration would have aborted"

      assert [{_f, to}] = remaining
      assert to == published.id
    end

    test "is IDEMPOTENT — a second run changes nothing", %{scope: scope} do
      {draft, published} = mk_twins!(scope, uniq("blocker"))
      dependent = mk_draft!(scope, uniq("dependent"))
      plant_edge!(dependent.id, draft.id)

      run_backfill!()
      first = edge_endpoints(dependent.id)
      run_backfill!()

      assert edge_endpoints(dependent.id) == first
      assert [{_f, to}] = first
      assert to == published.id
    end
  end

  describe "the gate the whole fix exists for" do
    test "a blocks edge filed on the draft twin GATES the published row",
         %{scope: scope} do
      slug = uniq("blocker")
      {draft, published_blocker} = mk_twins!(scope, slug)
      dependent = mk_draft!(scope, uniq("dependent"))

      assert {:ok, %Edge{}} = Tasks.add_dep(dependent, draft, :blocks)

      # The blocker is not done, so the dependent must NOT be ready. Before the
      # fix the edge bound to the draft uuid, the ready query correlated on the
      # published row's id, found no edge, and served the dependent as
      # claimable with an unsatisfied blocker.
      ready_ids = Tasks.ready(scope) |> Enum.map(& &1.id)

      refute dependent.id in ready_ids,
             "the dependent was served as ready while a blocks edge on the draft twin was unsatisfied"

      # NON-VACUITY, and it is load-bearing. A `refute … in ready_ids` passes
      # for free if the dependent could never be ready at all — which is how a
      # gating test quietly stops testing gating. Resolve the blocker and the
      # dependent MUST appear, so the refute above is measuring the edge and
      # not the fixture.
      {:ok, _} =
        Tasks.close(published_blocker.id, "worker-twin",
          observed_epoch: 0,
          reason: "landed #1 @ deadbeef1 — fixture blocker resolved"
        )

      assert dependent.id in (Tasks.ready(scope) |> Enum.map(& &1.id)),
             "the dependent never becomes ready even with its blocker done — the refute above proves nothing"
    end
  end
end
