defmodule Barkpark.Plugins.Indx.IndexKeyTenancyTest do
  @moduledoc """
  The Indx search index was LAST-WRITER-WINS across tenants.

  Every workspace is BORN owning a dataset named `production`
  (`Tenancy.do_create_owned_workspace/4`; uniqueness is `(project_id, slug)`,
  never global), so co-tenancy on one dataset STRING is the seeded default —
  not an edge case. Three links keyed the index on that string alone:

    1. `Lifecycle.scope_opts/1` stamps the SAVING document's `workspace_id`
       onto the rebuild job.
    2. `IndexerWorker`'s Oban `unique:` clause keyed on `(op, scope, _id)` —
       no tenancy — so workspace B's rebuild for `production` COLLAPSED into
       workspace A's in-flight job. B's rebuild simply never ran.
    3. The surviving job then listed A's corpus and blue/green-swapped it
       into ONE global pointer slot, `:persistent_term[{Indexer,
       :live_dataset}]["production"]`, which every tenant reads. The physical
       Indx dataset name (`bp_production_v1`) collided too.

  Net: tenant B's search read an index built entirely from tenant A's corpus,
  with B's own documents ABSENT from the candidate pool.

  Measured on `origin/main` @ 0bd0994c5c before the fix, with the same shapes
  the cases below assert on:

      job A id=230703 conflict?=false workspace_id="0a28a44b-…"
      job B id=230703 conflict?=true  workspace_id="0a28a44b-…"   # A's id!
      current_dataset("probe195") = "idx-B"   # A's swap erased
      ws_a -> bp_production_v1 | ws_b -> bp_production_v1

  The author had ALREADY reasoned this out for one dimension. The `unique:`
  note in `IndexerWorker` argues, about TYPES, that "two per-type keyed jobs
  would each swap a one-type dataset — last swap wins, the rest vanish". That
  argument holds verbatim across WORKSPACES, which is why the workspace
  belongs IN the key while `:types` stays out.

  ## Why this fixture COULD have produced the failure

  Both tenants use the SAME dataset string, both enqueue in the same debounce
  window, and both swap. Every assertion is a measurement of two live tenants
  competing for one identity — not a fence asserted against a single tenant.
  The "same workspace still collapses" case is the control: it proves the
  partition did not simply disable debouncing, which would make the rest pass
  for the wrong reason.

  ## :persistent_term hygiene

  The live pointer is VM-global and NO Ecto sandbox rolls it back, so every
  case here snapshots the whole term and restores it `on_exit`. Scope strings
  are `System.unique_integer`-suffixed on top of that, so a leak cannot reach
  another file even between the put and the restore.
  """
  use Barkpark.DataCase, async: false
  use Oban.Testing, repo: Barkpark.Repo

  alias Barkpark.Plugins.Indx.Indexer
  alias Barkpark.Plugins.Indx.IndexerWorker
  alias Barkpark.Plugins.Indx.Persistence
  alias Barkpark.Plugins.Indx.Retriever

  @pointer_term {Indexer, :live_dataset}

  # The dataset string every workspace is born owning — the collision surface.
  @shared_dataset "production"

  @indexer "Barkpark.Plugins.Indx.IndexKeyTenancyTest.SpyIndexer"
  @content "Barkpark.Plugins.Indx.IndexKeyTenancyTest.PerWorkspaceContent"

  # ── Seams ──────────────────────────────────────────────────────────────────

  # Reports the INDEX KEY it was handed alongside the corpus, so a case can see
  # which index a job's corpus was actually loaded into and swapped onto.
  defmodule SpyIndexer do
    @moduledoc false
    def rebuild(index_key, docs) do
      ids = Enum.map(docs, & &1["_id"])
      send(self(), {:rebuild, index_key, ids})

      {:ok,
       %{
         new_dataset: "ds-for-#{index_key}",
         old_dataset: nil,
         count: length(ids),
         key_map: Map.new(Enum.with_index(ids), fn {id, i} -> {i, id} end)
       }}
    end

    # Delegates to the REAL swap so the case can read the resulting pointer
    # state back. A fake that only recorded the call would still "pass" when
    # both tenants resolve to one index — the clobber happens in the pointer
    # table, so the pointer table is what has to be observed.
    def swap(index_key, result), do: Barkpark.Plugins.Indx.Indexer.swap(index_key, result)

    def delete_dataset(_old, _opts), do: :ok
  end

  # Returns a DIFFERENT document per workspace, so a corpus listed for the
  # wrong tenant is visible in the assertion rather than indistinguishable.
  defmodule PerWorkspaceContent do
    @moduledoc false
    def list_schemas(_scope, _opts), do: [%{name: "post", visibility: "public"}]

    def list_documents(_type, _scope, opts) do
      [%{"_id" => "doc-for-#{Keyword.get(opts, :workspace_id)}", "_type" => "post"}]
    end

    def get_document(_id, _type, _scope), do: {:error, :not_found}
  end

  # Records which physical dataset the read path asked the engine for. Returns
  # an empty pool on purpose: index SELECTION is what this seam measures;
  # hydration scoping is `RetrieverTotalScopeTest`'s subject.
  defmodule DatasetSpyClient do
    @moduledoc false
    def search_full(dataset, _text, _opts) do
      send(self(), {:searched, dataset})
      {:ok, %{records: [], facets: nil, truncation_index: nil}}
    end

    def get_json(_dataset, _keys, _opts), do: {:ok, []}
  end

  # Reports the physical dataset name `rebuild/3` minted, then stops the
  # rebuild — the name is the only thing under test.
  defmodule NameProbeClient do
    @moduledoc false
    def create_or_open(name, _opts) do
      send(self(), {:created, name})
      {:error, %Barkpark.Plugins.Indx.Errors.NetworkError{reason: :probe_stop}}
    end

    def delete_dataset(_name, _opts), do: :ok
  end

  setup do
    prior = :persistent_term.get(@pointer_term, %{})
    on_exit(fn -> :persistent_term.put(@pointer_term, prior) end)

    # `Indexer.swap/2` persists alongside the pointer, and `Persistence`'s
    # default dir is `priv/indx_state` INSIDE the repo — a real swap in a test
    # would leave untracked `.term` files in the working tree. Point it at a
    # temp dir for the duration, exactly as `RecoveryPersistenceTest` does.
    dir = Path.join(System.tmp_dir!(), "indx-index-key-test-#{System.unique_integer([:positive])}")
    prev_persistence = Application.get_env(:barkpark, Persistence, [])
    Application.put_env(:barkpark, Persistence, dir: dir)

    on_exit(fn ->
      Application.put_env(:barkpark, Persistence, prev_persistence)
      File.rm_rf!(dir)
    end)

    %{ws_a: Ecto.UUID.generate(), ws_b: Ecto.UUID.generate()}
  end

  describe "the Oban unique key partitions rebuilds per tenant" do
    test "two workspaces' rebuilds of the SAME dataset string both survive", ctx do
      assert {:ok, job_a} =
               IndexerWorker.enqueue(@shared_dataset, types: ["post"], workspace_id: ctx.ws_a)

      assert {:ok, job_b} =
               IndexerWorker.enqueue(@shared_dataset, types: ["post"], workspace_id: ctx.ws_b)

      # Before the fix both calls returned the SAME job row (Oban resolves a
      # unique conflict by handing back the existing job with conflict?: true),
      # carrying workspace A's id — B's rebuild never ran.
      refute job_b.conflict?,
             "workspace B's rebuild was deduped into another tenant's job"

      assert job_a.id != job_b.id
      assert job_a.args["workspace_id"] == ctx.ws_a
      assert job_b.args["workspace_id"] == ctx.ws_b
      assert job_a.args["index_key"] != job_b.args["index_key"]
    end

    test "a workspace-LESS rebuild is not swallowed by a tenant's job either", ctx do
      # The nil third state. Oban's `keys:` filter is CONTAINMENT (`args @>`)
      # and `drop_nil/1` omits a nil workspace_id, so a job whose unique subset
      # is a strict SUBSET of a tenant's job matched it — the workspace-less
      # rebuild collapsed into whichever tenant happened to be in flight. An
      # always-present `index_key` has no subset to be contained by.
      assert {:ok, tenant_job} =
               IndexerWorker.enqueue(@shared_dataset, types: ["post"], workspace_id: ctx.ws_a)

      assert {:ok, global_job} = IndexerWorker.enqueue(@shared_dataset, types: ["post"])

      refute global_job.conflict?
      assert tenant_job.id != global_job.id
      assert Map.has_key?(global_job.args, "index_key")
      refute Map.has_key?(global_job.args, "workspace_id")
    end

    test "CONTROL: the same tenant's burst STILL collapses to one job", ctx do
      # Without this the partition could be "nothing dedups any more", which
      # would satisfy every assertion above while destroying the debounce the
      # whole scope-rebuild design exists for.
      assert {:ok, first} =
               IndexerWorker.enqueue(@shared_dataset, types: ["post"], workspace_id: ctx.ws_a)

      assert {:ok, second} =
               IndexerWorker.enqueue(@shared_dataset, types: ["page"], workspace_id: ctx.ws_a)

      assert first.id == second.id
      assert second.conflict?
    end

    test "upsert/delete stay unique per (op, index, _id) across tenants", ctx do
      assert {:ok, up_a} =
               IndexerWorker.enqueue_upsert(@shared_dataset, "p1", workspace_id: ctx.ws_a)

      assert {:ok, up_b} =
               IndexerWorker.enqueue_upsert(@shared_dataset, "p1", workspace_id: ctx.ws_b)

      assert {:ok, del_a} =
               IndexerWorker.enqueue_delete(@shared_dataset, "p1", workspace_id: ctx.ws_a)

      # Same `_id` in two tenants is two different documents — both must run.
      assert up_a.id != up_b.id

      # ...while the op discriminator still separates a delete from an upsert.
      assert del_a.id != up_a.id
    end
  end

  describe "the live pointer slot is per-tenant" do
    test "one tenant's swap cannot erase another's index", ctx do
      scope = "ptr#{System.unique_integer([:positive])}"
      key_a = Indexer.index_key(scope, workspace_id: ctx.ws_a)
      key_b = Indexer.index_key(scope, workspace_id: ctx.ws_b)

      assert key_a != key_b

      Indexer.swap(key_a, %{new_dataset: "idx-A", key_map: %{1 => "doc-a"}})
      Indexer.swap(key_b, %{new_dataset: "idx-B", key_map: %{2 => "doc-b"}})

      # Pre-fix both swaps wrote `table["ptr…"]`, so A read "idx-B" and A's
      # key_map was gone — its delete targets unresolvable.
      assert Indexer.current_dataset(key_a) == "idx-A"
      assert Indexer.current_dataset(key_b) == "idx-B"
      assert Indexer.key_map(key_a) == %{1 => "doc-a"}
      assert Indexer.key_map(key_b) == %{2 => "doc-b"}
    end

    test "the physical Indx dataset name differs per tenant", ctx do
      # Two tenants rebuilding `production` both produced `bp_production_v1` —
      # the same dataset inside the shared Indx account, so the second rebuild
      # loaded its corpus over the first tenant's.
      name_a = dataset_name_for(Indexer.index_key(@shared_dataset, workspace_id: ctx.ws_a))
      name_b = dataset_name_for(Indexer.index_key(@shared_dataset, workspace_id: ctx.ws_b))

      assert name_a != name_b
      assert name_a =~ ~r/^bp_production_t[0-9a-f]{16}_v1$/
      assert name_b =~ ~r/^bp_production_t[0-9a-f]{16}_v1$/
    end

    test "handing a pointer function a bare dataset string RAISES" do
      # The tripwire. A caller that forgets to partition gets a
      # FunctionClauseError, not a silent cross-tenant index merge.
      assert_raise FunctionClauseError, fn -> Indexer.current_dataset(@shared_dataset) end
      assert_raise FunctionClauseError, fn -> Indexer.key_map(@shared_dataset) end

      assert_raise FunctionClauseError, fn ->
        Indexer.swap(@shared_dataset, %{new_dataset: "x", key_map: %{}})
      end
    end
  end

  describe "end to end: each tenant's rebuild loads ITS OWN corpus into ITS OWN index" do
    test "two rebuild jobs for one dataset string never cross", ctx do
      key_a = Indexer.index_key(@shared_dataset, workspace_id: ctx.ws_a)
      key_b = Indexer.index_key(@shared_dataset, workspace_id: ctx.ws_b)
      corpus_a = ["doc-for-#{ctx.ws_a}"]
      corpus_b = ["doc-for-#{ctx.ws_b}"]

      # A rebuilds FIRST, B second — so a shared slot would end up holding B's
      # corpus and A's assertions below are the ones that catch the clobber.
      assert :ok = perform_job(IndexerWorker, rebuild_args(ctx.ws_a))
      assert :ok = perform_job(IndexerWorker, rebuild_args(ctx.ws_b))

      # Each job listed its OWN workspace's corpus...
      assert_received {:rebuild, ^key_a, ^corpus_a}
      assert_received {:rebuild, ^key_b, ^corpus_b}

      # ...and swapped it onto its OWN live index, which B's later swap did not
      # touch. Reading the POINTER (not just the calls) is what makes this a
      # measurement: pre-fix both swaps wrote one slot, so A's live index named
      # B's dataset and A's key_map held B's document.
      assert Indexer.current_dataset(key_a) == "ds-for-#{key_a}"
      assert Indexer.current_dataset(key_b) == "ds-for-#{key_b}"
      assert Indexer.key_map(key_a) == %{0 => "doc-for-#{ctx.ws_a}"}
      assert Indexer.key_map(key_b) == %{0 => "doc-for-#{ctx.ws_b}"}
    end
  end

  describe "the read path resolves the caller's own index" do
    test "workspace B's search queries B's dataset, not A's", ctx do
      scope = "read#{System.unique_integer([:positive])}"

      # B is seated FIRST and A LAST, deliberately. If the two tenants ever
      # resolve to one slot, A's seat wins and B's search reads "idx-A" — the
      # exact disclosure under test. Seating B last would let a collapsed slot
      # answer "idx-B" and the assertion would pass for the wrong reason.
      seat_pointer!(Indexer.index_key(scope, workspace_id: ctx.ws_b), "idx-B")
      seat_pointer!(Indexer.index_key(scope, workspace_id: ctx.ws_a), "idx-A")

      Retriever.search(scope, %{terms: ["anything"]}, %{},
        workspace_id: ctx.ws_b,
        client: DatasetSpyClient
      )

      # Pre-fix `Indexer.current_dataset(scope)` returned whichever dataset was
      # swapped LAST, so B's search read A's index whenever A rebuilt last.
      assert_received {:searched, "idx-B"}
      refute_received {:searched, "idx-A"}
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp rebuild_args(workspace_id) do
    %{
      "op" => "rebuild",
      "scope" => @shared_dataset,
      "types" => ["post"],
      "workspace_id" => workspace_id,
      "index_key" => Indexer.index_key(@shared_dataset, workspace_id: workspace_id),
      "indexer" => @indexer,
      "content" => @content
    }
  end

  defp seat_pointer!(index_key, dataset) do
    table = :persistent_term.get(@pointer_term, %{})
    :persistent_term.put(@pointer_term, Map.put(table, index_key, %{dataset: dataset}))
  end

  # The name `Indexer.rebuild/3` would mint for a first (v1) build of this
  # index, observed through the client seam rather than reimplemented here.
  defp dataset_name_for(index_key) do
    {:error, _} = Indexer.rebuild(index_key, [], client: NameProbeClient)
    assert_receive {:created, name}
    name
  end
end
