defmodule Barkpark.EdgeProjector.ProjectorWorkerPerformTest do
  @moduledoc """
  Covers the `perform/1` cancellation and error-routing paths of
  `ProjectorWorker` that are NOT exercised by `ProjectorTest` (which covers
  the happy-path rebuild/delete/missing-scope ops against the real DB).

  What this file adds:
    * `{:cancel, :missing_id}` on both delete and upsert ops when `"_id"` is
      absent or blank.
    * `{:cancel, :no_type_for_upsert}` when the upsert op has no `"types"`.
    * `{:cancel, :doc_gone}` when the content seam returns `{:error, :not_found}`.
    * Upsert happy path via the `"projector"` / `"content"` test-seam overrides
      (atom-keyed modules injected directly, bypassing the real DB).

  Uses `Oban.Testing.perform_job/2` (config/test.exs is `testing: :manual`).
  Fake modules are defined in this file so their atoms are pre-existing.
  """

  use Barkpark.DataCase, async: true
  use Oban.Testing, repo: Barkpark.Repo

  alias Barkpark.EdgeProjector.ProjectorWorker

  # ── Fake seam: content module that returns :not_found for any get_document call ──
  defmodule FakeContentNotFound do
    @moduledoc false
    def get_document(_id, _type, _scope), do: {:error, :not_found}
    def list_documents(_type, _scope, _opts), do: []
  end

  # ── Fake seam: content module that always returns a minimal doc ──
  defmodule FakeContentFound do
    @moduledoc false
    def get_document(id, _type, _scope),
      do: {:ok, %{"doc_id" => id, "dataset" => "test", "_type" => "post"}}

    def list_documents(_type, _scope, _opts), do: []
  end

  # ── Fake seam: projector module that records calls + returns success ──
  defmodule FakeProjectorOk do
    @moduledoc false
    def rebuild_scope(_scope, _docs, _opts), do: {:ok, %{added: 0, deleted: 0}}
    def upsert_record(_doc, _opts), do: {:ok, %{added: 1, removed: 0}}
    def delete_record(_ref, _opts), do: {:ok, 0}
  end

  # ── delete op ─────────────────────────────────────────────────────────────────

  describe "delete op — missing / blank _id" do
    test "cancels with :missing_id when _id is absent" do
      assert {:cancel, :missing_id} =
               perform_job(ProjectorWorker, %{
                 "op" => "delete",
                 "scope" => "production"
               })
    end

    test "cancels with :missing_id when _id is an empty string" do
      assert {:cancel, :missing_id} =
               perform_job(ProjectorWorker, %{
                 "op" => "delete",
                 "scope" => "production",
                 "_id" => ""
               })
    end
  end

  # ── upsert op ─────────────────────────────────────────────────────────────────

  describe "upsert op — missing / blank _id" do
    test "cancels with :missing_id when _id is absent" do
      assert {:cancel, :missing_id} =
               perform_job(ProjectorWorker, %{
                 "op" => "upsert",
                 "scope" => "production",
                 "types" => ["post"]
               })
    end

    test "cancels with :missing_id when _id is an empty string" do
      assert {:cancel, :missing_id} =
               perform_job(ProjectorWorker, %{
                 "op" => "upsert",
                 "scope" => "production",
                 "_id" => "",
                 "types" => ["post"]
               })
    end
  end

  describe "upsert op — no type" do
    test "cancels with :no_type_for_upsert when types list is empty" do
      assert {:cancel, :no_type_for_upsert} =
               perform_job(ProjectorWorker, %{
                 "op" => "upsert",
                 "scope" => "production",
                 "_id" => "doc-1",
                 "types" => []
               })
    end

    test "cancels with :no_type_for_upsert when types key is absent" do
      assert {:cancel, :no_type_for_upsert} =
               perform_job(ProjectorWorker, %{
                 "op" => "upsert",
                 "scope" => "production",
                 "_id" => "doc-1"
               })
    end
  end

  describe "upsert op — doc gone (content seam returns :not_found)" do
    test "cancels with :doc_gone when the content module cannot find the doc" do
      # Oban serialises args to JSON → atoms become strings.
      # projector_mod/content_mod call String.to_existing_atom, so we must pass
      # the full module name string (the atom is pre-existing because the module
      # is compiled in this test file).
      assert {:cancel, :doc_gone} =
               perform_job(ProjectorWorker, %{
                 "op" => "upsert",
                 "scope" => "production",
                 "_id" => "ghost-doc",
                 "types" => ["post"],
                 "content" =>
                   "Barkpark.EdgeProjector.ProjectorWorkerPerformTest.FakeContentNotFound",
                 "projector" =>
                   "Barkpark.EdgeProjector.ProjectorWorkerPerformTest.FakeProjectorOk"
               })
    end
  end

  describe "upsert op — success path via test-seam overrides" do
    test "returns :ok when the content and projector seams both succeed" do
      assert :ok =
               perform_job(ProjectorWorker, %{
                 "op" => "upsert",
                 "scope" => "production",
                 "_id" => "real-doc",
                 "types" => ["post"],
                 "content" =>
                   "Barkpark.EdgeProjector.ProjectorWorkerPerformTest.FakeContentFound",
                 "projector" =>
                   "Barkpark.EdgeProjector.ProjectorWorkerPerformTest.FakeProjectorOk"
               })
    end
  end
end
