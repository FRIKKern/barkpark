defmodule Barkpark.Repo.Migrations.RescopePaperEventsDatasetIdTest do
  @moduledoc """
  Correctness gate for the corrective migration 20260527143000 (84bn).

  The Wave-2 backfill (20260527132000) blanket-stamped every paper_event's
  dataset_id to the Default project's `production` dataset, IGNORING the
  per-row project_id the W1.5 backfill had derived from the paper's scope. A
  non-Default paper_event therefore ended up with a dataset_id pointing at a
  dataset OWNED BY A DIFFERENT PROJECT than the row's own project_id — a
  structurally-impossible scope tuple.

  These fixtures prove up/0:
    * CORRECTS a mismatched row → its dataset_id now points at a dataset UNDER
      the row's OWN project_id (re-resolved from the paper's dataset string).
    * LEAVES a correct row untouched.
    * falls the ORPHAN (no paper join) back to Default `production`.
    * is IDEMPOTENT (a 2nd up/0 changes nothing).
  And down/0 restores the pre-correction dataset_id from the snapshot table.

  Driven through `apply_up(Repo)` / `apply_down(Repo)` — the generated wrappers
  that run the migration body against the TEST's own sandbox connection, so
  they avoid the `Ecto.Migrator`-spawns-its-own-connection flake noted in
  codelist_issue_version_test.exs.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @migration_file Path.expand(
                    "../../../../priv/repo/migrations/20260527143000_rescope_paper_events_dataset_id.exs",
                    __DIR__
                  )

  setup_all do
    Code.require_file(@migration_file)
    :ok
  end

  alias Barkpark.Repo.Migrations.RescopePaperEventsDatasetId

  # ── low-level helpers (raw SQL — paper_events.dataset_id isn't cast) ───────
  #
  # uuid params for raw `Repo.query!` must be 16-byte binaries; the ids carried
  # on structs are string UUIDs, so dump on the way IN and load on the way OUT.
  defp uuid_in(nil), do: nil
  defp uuid_in(id) when is_binary(id), do: Ecto.UUID.dump!(id)

  defp uuid_out(nil), do: nil
  defp uuid_out(<<_::128>> = bin), do: Ecto.UUID.load!(bin)
  defp uuid_out(str) when is_binary(str), do: str

  # Insert a `documents` row of type "paper" carrying a dataset STRING under a
  # scope. doc_id == the paper slug (the W1.5 join key).
  defp insert_paper!(slug, dataset_string, ws, project) do
    Repo.query!(
      """
      INSERT INTO documents
        (id, doc_id, type, dataset, title, status, rev, workspace_id, project_id,
         inserted_at, updated_at)
      VALUES
        (gen_random_uuid(), $1, 'paper', $2, $3, 'draft', $4, $5, $6, now(), now())
      """,
      [
        slug,
        dataset_string,
        "Paper #{slug}",
        "rev-#{slug}-#{System.unique_integer([:positive])}",
        uuid_in(ws.id),
        uuid_in(project.id)
      ]
    )
  end

  # Insert a paper_event with an explicit project_id + dataset_id (the
  # backfilled, possibly-mismatched shape). Returns the new event id (string).
  defp insert_event!(slug, project_id, dataset_id) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO paper_events
          (id, paper_slug, event_type, branch, project_id, dataset_id,
           inserted_at, updated_at)
        VALUES
          (gen_random_uuid(), $1, 'plan-written', 'main', $2, $3, now(), now())
        RETURNING id
        """,
        [slug, uuid_in(project_id), uuid_in(dataset_id)]
      )

    uuid_out(id)
  end

  defp dataset_id_of(event_id) do
    %{rows: [[dataset_id]]} =
      Repo.query!("SELECT dataset_id FROM paper_events WHERE id = $1", [uuid_in(event_id)])

    uuid_out(dataset_id)
  end

  # The datasets.project_id that a given dataset_id belongs to.
  defp dataset_project_of(dataset_id) do
    %{rows: [[project_id]]} =
      Repo.query!("SELECT project_id FROM datasets WHERE id = $1", [uuid_in(dataset_id)])

    uuid_out(project_id)
  end

  # Stand up a NON-Default project with its OWN `production` dataset.
  defp non_default_project_with_production do
    ws = create_workspace!()
    project = create_project!(ws)
    {:ok, ds} = Tenancy.get_or_create_dataset(project, "production")
    {ws, project, ds}
  end

  describe "up/0 — re-stamp from each row's own project" do
    test "CORRECTS a mismatched row: dataset_id moves to a dataset under the row's OWN project" do
      {ws, project, own_production} = non_default_project_with_production()

      # The paper lives under the NON-Default project, dataset string "production".
      insert_paper!("paper-mismatch", "production", ws, project)

      # The bug shape: project_id = the non-Default project, but dataset_id =
      # the DEFAULT project's production dataset (a different project's dataset).
      default_project = Tenancy.get_default_project()
      default_production = Tenancy.get_dataset(default_project, "production")

      event_id = insert_event!("paper-mismatch", project.id, default_production.id)

      # Precondition: the row is mismatched (dataset's project ≠ row's project).
      assert dataset_project_of(default_production.id) == default_project.id
      assert default_project.id != project.id

      RescopePaperEventsDatasetId.apply_up(Repo)

      corrected = dataset_id_of(event_id)
      # Now points at the OWN-project production dataset (re-resolved via paper).
      assert corrected == own_production.id
      # And the structural invariant holds: dataset's project == row's project.
      assert dataset_project_of(corrected) == project.id
    end

    test "LEAVES a correct row untouched" do
      {ws, project, own_production} = non_default_project_with_production()
      insert_paper!("paper-correct", "production", ws, project)

      # Already correct: dataset_id is the row's OWN-project production dataset.
      event_id = insert_event!("paper-correct", project.id, own_production.id)

      RescopePaperEventsDatasetId.apply_up(Repo)

      assert dataset_id_of(event_id) == own_production.id
    end

    test "ORPHAN (no paper join) falls back to Default production" do
      {_ws, project, _own_production} = non_default_project_with_production()

      default_project = Tenancy.get_default_project()
      default_production = Tenancy.get_dataset(default_project, "production")

      # paper_slug references a slug with NO matching type-'paper' document → the
      # paper-derived pass can't resolve it. It's still mismatched (project's own
      # dataset vs the row), so the orphan fallback re-stamps Default production.
      # Seed the mismatch by pointing at the row's OWN-project production first,
      # but with a project that is NOT where the (Default) fallback lives — use a
      # dataset under a THIRD project to force the mismatch + the orphan path.
      ws_other = create_workspace!()
      project_other = create_project!(ws_other)
      {:ok, other_production} = Tenancy.get_or_create_dataset(project_other, "production")

      # Row's project = `project`; dataset_id = a dataset owned by `project_other`
      # → mismatched. No paper document for "ghost-slug" → orphan → Default.
      event_id = insert_event!("ghost-slug", project.id, other_production.id)

      RescopePaperEventsDatasetId.apply_up(Repo)

      assert dataset_id_of(event_id) == default_production.id
    end

    test "IDEMPOTENT: a 2nd up/0 changes nothing" do
      {ws, project, own_production} = non_default_project_with_production()
      insert_paper!("paper-idem", "production", ws, project)

      default_project = Tenancy.get_default_project()
      default_production = Tenancy.get_dataset(default_project, "production")
      event_id = insert_event!("paper-idem", project.id, default_production.id)

      RescopePaperEventsDatasetId.apply_up(Repo)
      after_first = dataset_id_of(event_id)
      assert after_first == own_production.id

      RescopePaperEventsDatasetId.apply_up(Repo)
      after_second = dataset_id_of(event_id)

      assert after_second == after_first
    end
  end

  describe "down/0 — restore the pre-correction dataset_id" do
    test "restores the snapshot value and is a no-op without a snapshot" do
      {ws, project, own_production} = non_default_project_with_production()
      insert_paper!("paper-down", "production", ws, project)

      default_project = Tenancy.get_default_project()
      default_production = Tenancy.get_dataset(default_project, "production")
      event_id = insert_event!("paper-down", project.id, default_production.id)

      RescopePaperEventsDatasetId.apply_up(Repo)
      assert dataset_id_of(event_id) == own_production.id

      RescopePaperEventsDatasetId.apply_down(Repo)
      # Restored to exactly the pre-correction (Default production) value.
      assert dataset_id_of(event_id) == default_production.id

      # A second down with the snapshot already dropped is a documented no-op
      # (does not crash, does not mutate).
      RescopePaperEventsDatasetId.apply_down(Repo)
      assert dataset_id_of(event_id) == default_production.id
    end
  end
end
