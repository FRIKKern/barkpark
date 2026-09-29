defmodule Barkpark.Content.WriteScopeProvenanceTest do
  @moduledoc """
  SCOPE-RESOLUTION PROVENANCE AT WRITE TIME (task-b389fe352e013dce).

  ## The question this makes answerable

  `task-e6523cc7154304f0`'s criterion 1 closed UNMEASURABLE: nobody could say
  how many documents carry the seeded Default workspace BY FALLBACK rather than
  BY A CALLER'S CHOICE. The reason was not that nobody counted — it is that the
  two writes are byte-identical in storage:

    * a caller passing `workspace_id: <Default>` takes `resolve_write_scope/1`'s
      `not is_nil(opt_ws)` arm;
    * a caller passing nothing takes `resolve_key_absent_write_scope/1` ->
      `seeded_default_write_scope/0`;

  and BOTH land `{Default.id, Default_project.id}` with no other difference.
  `documents` carried 21 columns and none of them recorded HOW the scope was
  resolved.

  ## What is asserted here

  Both arms are driven through the REAL write path (`Content.create_document/4`,
  which stamps via `WriteScope.put_scope_attrs/2`), and the verdict is read back
  with RAW SQL against the `documents` table — not from the in-memory struct,
  not by re-running the resolver. That is the whole point of criterion 0: the
  discriminator has to survive in stored bytes, recoverable by a reader who has
  no access to the calling code.

  The fallback arm is a genuine `opts: []` write. It is NOT simulated by passing
  the Default id explicitly, because those two are precisely the pair nothing
  could tell apart before this change.

  ## The test that reds if they become indistinguishable again

  `the fallback write and the explicit-Default write are DISTINGUISHABLE in
  storage` compares the two stored values directly. Delete the `scope_source`
  stamp from `put_scope_attrs/2` (or make both arms stamp the same literal) and
  it reds on the equality, regardless of which vocabulary the column uses.

  SCOPE NOTE (shared test database): every assertion is keyed on doc_ids this
  test mints. `async: false` because the seeded Default workspace is
  process-global state all three arms read.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.TenancyFixtures

  @dataset "test"
  @type_name "scope_provenance_probe"

  setup do
    Content.upsert_schema(
      %{
        "name" => @type_name,
        "title" => "Scope Provenance Probe",
        "visibility" => "public",
        "fields" => []
      },
      @dataset,
      instance_wide: true
    )

    default = Tenancy.get_default_workspace()

    refute is_nil(default),
           "the seeded Default workspace must exist or every arm below proves nothing"

    {:ok, default: default}
  end

  # Read the row the way a LATER READER would: straight out of the table, with
  # no access to the opts the writer was called with.
  defp stored_scope(doc_id) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        "SELECT workspace_id::text, scope_source FROM documents WHERE doc_id = $1",
        [doc_id]
      )

    case rows do
      [[ws_id, scope_source]] -> %{workspace_id: ws_id, scope_source: scope_source}
      other -> flunk("expected exactly one row for doc_id #{doc_id}, got: #{inspect(other)}")
    end
  end

  defp write!(opts) do
    title = "prov-#{System.unique_integer([:positive])}"

    {:ok, doc} =
      Content.create_document(@type_name, %{"title" => title}, @dataset, opts)

    stored_scope(doc.doc_id)
  end

  describe "both arms at the write path" do
    test "a write that NAMES the Default workspace stores scope_source=explicit", %{
      default: default
    } do
      stored = write!(workspace_id: default.id)

      assert stored.workspace_id == default.id
      assert stored.scope_source == "explicit"
    end

    test "a write that names NOTHING falls into the Default and stores scope_source=default_fallback",
         %{default: default} do
      # opts: [] carries no :workspace_id, no :caller_context, no :user_id and
      # no :instance_wide — so it reaches resolve_key_absent_write_scope/1's
      # residual arm and therefore seeded_default_write_scope/0 for real.
      stored = write!([])

      assert stored.workspace_id == default.id
      assert stored.scope_source == "default_fallback"
    end

    test "THE REGRESSION GUARD: the fallback write and the explicit-Default write are DISTINGUISHABLE in storage",
         %{default: default} do
      explicit = write!(workspace_id: default.id)
      fallback = write!([])

      # The premise the row rests on: the tenancy columns ARE identical. If this
      # ever stops holding, the guard below is passing for the wrong reason.
      assert explicit.workspace_id == fallback.workspace_id,
             "premise broken: the two arms no longer land in the same workspace"

      refute is_nil(explicit.scope_source),
             "an explicit write stored no provenance — the discriminator is gone"

      refute is_nil(fallback.scope_source),
             "a fallback write stored no provenance — the discriminator is gone"

      refute explicit.scope_source == fallback.scope_source,
             "the NAMED write and the FALLEN-INTO write are byte-identical again"
    end

    test "an instance_wide DECLARATION is its own third value, not the fallback's", %{
      default: default
    } do
      declared = write!(instance_wide: true)
      fallback = write!([])

      assert declared.workspace_id == default.id
      assert declared.scope_source == "instance_wide"
      refute declared.scope_source == fallback.scope_source
    end

    test "an INFERRED write (one-workspace principal) is neither explicit nor fallback" do
      ws = TenancyFixtures.create_workspace!()
      _ = TenancyFixtures.create_project!(ws, "default")

      user =
        Barkpark.AccountsFixtures.register_user(
          "prov-#{System.unique_integer([:positive])}@example.com"
        )

      {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, "member", "user")

      stored = write!(user_id: user.id)

      assert stored.workspace_id == ws.id
      assert stored.scope_source == "inferred"
    end
  end

  describe "the provenance is SERVER-authoritative" do
    test "a client-supplied scope_source is dropped, exactly like a client workspace_id" do
      # `scope_source` joins @client_scope_keys. A caller that asserts its own
      # provenance is overwritten by what the resolver actually did, or the
      # column would be a caller's claim rather than a measurement.
      assert {:ok, stamped} =
               Content.put_scope_attrs(
                 %{"dataset" => @dataset, "scope_source" => "explicit"},
                 []
               )

      assert stamped["scope_source"] == "default_fallback"
    end
  end
end
