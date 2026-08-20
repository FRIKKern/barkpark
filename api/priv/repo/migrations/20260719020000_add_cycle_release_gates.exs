defmodule Barkpark.Repo.Migrations.AddCycleReleaseGates do
  use Ecto.Migration

  def up do
    alter table(:cycle_waves) do
      add :release_gate_required, :boolean
    end

    execute "ALTER TABLE cycle_waves DISABLE TRIGGER cycle_waves_no_update_delete"
    execute "UPDATE cycle_waves SET release_gate_required = false"
    execute "ALTER TABLE cycle_waves ENABLE TRIGGER cycle_waves_no_update_delete"
    execute "ALTER TABLE cycle_waves ALTER COLUMN release_gate_required SET DEFAULT true"
    execute "ALTER TABLE cycle_waves ALTER COLUMN release_gate_required SET NOT NULL"

    create table(:cycle_release_gate_admissions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :stage, :text, null: false

      add :root_wave_id, references(:cycle_waves, type: :uuid, on_delete: :delete_all),
        null: false

      add :parent_wave_id, references(:cycle_waves, type: :uuid, on_delete: :delete_all),
        null: false

      add :target_wave_id, references(:cycle_waves, type: :uuid, on_delete: :delete_all)
      add :reserved_target_revision, :uuid, null: false
      add :workspace_id, references(:workspaces, type: :uuid, on_delete: :delete_all), null: false
      add :project_id, references(:projects, type: :uuid, on_delete: :delete_all), null: false
      add :epic_id, :text, null: false
      add :target_wave_key, :text, null: false
      add :idempotency_key, :text, null: false
      add :challenge_id, :uuid
      add :evidence_bundle, :map, null: false, default: %{}
      add :receipt, :map, null: false
      add :bundle_digest, :text, null: false
      add :receipt_digest, :text, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:cycle_release_gate_admissions, :cycle_release_gate_stage,
             check: "stage IN ('open','activate')"
           )

    create unique_index(:cycle_release_gate_admissions, [:root_wave_id, :stage, :idempotency_key],
             name: :cycle_release_gate_admissions_replay_index
           )

    create unique_index(:cycle_release_gate_admissions, [:stage, :reserved_target_revision],
             name: :cycle_release_gate_admissions_reserved_index
           )

    create unique_index(:cycle_release_gate_admissions, [:target_wave_id],
             where: "stage = 'activate'",
             name: :cycle_release_gate_admissions_activate_target_index
           )

    create table(:cycle_release_paper_candidates, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :target_wave_id, references(:cycle_waves, type: :uuid, on_delete: :delete_all),
        null: false

      add :role, :text, null: false
      add :document_id, references(:documents, type: :uuid, on_delete: :delete_all), null: false
      add :doc_id, :text, null: false
      add :base_document_rev, :text, null: false
      add :base_current_revision_id, references(:revisions, type: :uuid), null: false
      add :base_released_revision_id, references(:revisions, type: :uuid), null: false
      add :title, :text, null: false
      add :status, :text, null: false, default: "published"
      add :content, :map, null: false
      add :content_digest, :text, null: false
      add :source_digest, :text, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:cycle_release_paper_candidates, :cycle_release_paper_candidate_role,
             check: "role IN ('campaign','successor')"
           )

    create unique_index(:cycle_release_paper_candidates, [:target_wave_id, :role])

    create table(:cycle_release_gate_challenges, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :target_wave_id, references(:cycle_waves, type: :uuid, on_delete: :delete_all),
        null: false

      add :workspace_id, references(:workspaces, type: :uuid, on_delete: :delete_all), null: false
      add :project_id, references(:projects, type: :uuid, on_delete: :delete_all), null: false
      add :epic_id, :text, null: false
      add :nonce, :text, null: false
      add :request, :map, null: false
      add :request_digest, :text, null: false
      add :claimed_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:cycle_release_gate_challenges, [:nonce])

    create unique_index(:cycle_release_gate_challenges, [:target_wave_id],
             where: "completed_at IS NULL",
             name: :cycle_release_gate_challenges_live_target_index
           )

    create table(:cycle_release_gate_captures, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :challenge_id,
          references(:cycle_release_gate_challenges, type: :uuid, on_delete: :delete_all),
          null: false

      add :name, :text, null: false
      add :producer, :text, null: false
      add :raw_bytes, :binary, null: false
      add :byte_count, :bigint, null: false
      add :content_digest, :text, null: false
      add :provenance, :map, null: false
      add :provenance_digest, :text, null: false
      add :verdict, :map, null: false
      add :verdict_digest, :text, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:cycle_release_gate_captures, [:challenge_id, :name])

    create table(:cycle_release_gate_consumptions, primary_key: false) do
      add :admission_id,
          references(:cycle_release_gate_admissions, type: :uuid, on_delete: :delete_all),
          primary_key: true

      add :wave_id, references(:cycle_waves, type: :uuid, on_delete: :delete_all), null: false
      add :kind, :text, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:cycle_release_gate_consumptions, [:wave_id, :kind])

    create constraint(:cycle_release_gate_consumptions, :cycle_release_gate_consumption_kind,
             check: "kind IN ('open','activate')"
           )

    alter table(:cycle_correction_promotion_events) do
      add :release_gate_admission_id,
          references(:cycle_release_gate_admissions, type: :uuid)

      add :release_materialization, :map
    end

    execute immutable_function()
    execute challenge_transition_function()
    execute validation_function()

    for table <-
          ~w(cycle_release_gate_admissions cycle_release_paper_candidates cycle_release_gate_captures cycle_release_gate_consumptions) do
      execute "CREATE TRIGGER #{table}_immutable BEFORE UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION barkpark_release_gate_immutable()"
    end

    execute "CREATE TRIGGER cycle_release_gate_challenges_transition BEFORE UPDATE OR DELETE ON cycle_release_gate_challenges FOR EACH ROW EXECUTE FUNCTION barkpark_release_gate_challenge_transition()"

    execute "CREATE CONSTRAINT TRIGGER cycle_release_gate_validate_admission AFTER INSERT ON cycle_release_gate_admissions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION barkpark_validate_release_gate()"

    execute "CREATE CONSTRAINT TRIGGER cycle_release_gate_validate_paper_candidate AFTER INSERT ON cycle_release_paper_candidates DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION barkpark_validate_release_gate()"

    execute "CREATE CONSTRAINT TRIGGER cycle_release_gate_validate_consumption AFTER INSERT ON cycle_release_gate_consumptions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION barkpark_validate_release_gate()"

    execute "CREATE CONSTRAINT TRIGGER cycle_release_gate_require_open AFTER INSERT ON cycle_waves DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.correction_of_wave_id IS NOT NULL) EXECUTE FUNCTION barkpark_validate_release_gate()"

    execute "CREATE CONSTRAINT TRIGGER cycle_release_gate_require_activate AFTER INSERT ON cycle_correction_promotion_events DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.action = 'promote') EXECUTE FUNCTION barkpark_validate_release_gate()"
  end

  def down do
    execute "DROP TRIGGER IF EXISTS cycle_release_gate_require_activate ON cycle_correction_promotion_events"
    execute "DROP TRIGGER IF EXISTS cycle_release_gate_require_open ON cycle_waves"

    execute "DROP TRIGGER IF EXISTS cycle_release_gate_validate_consumption ON cycle_release_gate_consumptions"

    execute "DROP TRIGGER IF EXISTS cycle_release_gate_validate_admission ON cycle_release_gate_admissions"

    execute "DROP TRIGGER IF EXISTS cycle_release_gate_validate_paper_candidate ON cycle_release_paper_candidates"

    execute "DROP TRIGGER IF EXISTS cycle_release_gate_challenges_transition ON cycle_release_gate_challenges"

    for table <-
          ~w(cycle_release_gate_admissions cycle_release_paper_candidates cycle_release_gate_captures cycle_release_gate_consumptions) do
      execute "DO $$ BEGIN IF to_regclass('#{table}') IS NOT NULL THEN EXECUTE 'DROP TRIGGER IF EXISTS #{table}_immutable ON #{table}'; END IF; END $$"
    end

    execute "DROP FUNCTION IF EXISTS barkpark_validate_release_gate()"
    execute "DROP FUNCTION IF EXISTS barkpark_release_gate_challenge_transition()"
    execute "DROP FUNCTION IF EXISTS barkpark_release_gate_immutable()"

    alter table(:cycle_correction_promotion_events) do
      remove_if_exists :release_materialization
      remove_if_exists :release_gate_admission_id
    end

    drop table(:cycle_release_gate_consumptions)
    drop table(:cycle_release_gate_captures)
    drop table(:cycle_release_gate_challenges)
    drop_if_exists table(:cycle_release_paper_candidates)
    drop table(:cycle_release_gate_admissions)
    execute "ALTER TABLE cycle_waves DISABLE TRIGGER cycle_waves_no_update_delete"
    alter table(:cycle_waves), do: remove(:release_gate_required)
    execute "ALTER TABLE cycle_waves ENABLE TRIGGER cycle_waves_no_update_delete"
  end

  defp immutable_function do
    """
    CREATE FUNCTION barkpark_release_gate_immutable() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' AND pg_trigger_depth() > 1 THEN RETURN OLD; END IF;
      RAISE EXCEPTION 'release-gate-v1 rows are immutable';
    END; $$ LANGUAGE plpgsql;
    """
  end

  defp challenge_transition_function do
    """
    CREATE FUNCTION barkpark_release_gate_challenge_transition() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' AND pg_trigger_depth() > 1 THEN RETURN OLD; END IF;
      IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'release gate challenge is immutable'; END IF;
      IF (NEW.id, NEW.target_wave_id, NEW.workspace_id, NEW.project_id, NEW.epic_id, NEW.nonce,
          NEW.request, NEW.request_digest, NEW.inserted_at) IS DISTINCT FROM
         (OLD.id, OLD.target_wave_id, OLD.workspace_id, OLD.project_id, OLD.epic_id, OLD.nonce,
          OLD.request, OLD.request_digest, OLD.inserted_at) THEN
        RAISE EXCEPTION 'release gate challenge authority is immutable';
      END IF;
      IF OLD.claimed_at IS NOT NULL AND NEW.claimed_at IS DISTINCT FROM OLD.claimed_at THEN
        RAISE EXCEPTION 'release gate challenge claim cannot change';
      END IF;
      IF OLD.completed_at IS NOT NULL AND NEW.completed_at IS DISTINCT FROM OLD.completed_at THEN
        RAISE EXCEPTION 'release gate challenge completion cannot change';
      END IF;
      IF NEW.completed_at IS NOT NULL AND NEW.claimed_at IS NULL THEN
        RAISE EXCEPTION 'release gate challenge cannot complete before claim';
      END IF;
      IF NEW.claimed_at IS NOT NULL AND NEW.claimed_at < OLD.inserted_at OR
         NEW.completed_at IS NOT NULL AND NEW.completed_at < NEW.claimed_at THEN
        RAISE EXCEPTION 'release gate challenge timestamps regress';
      END IF;
      RETURN NEW;
    END; $$ LANGUAGE plpgsql;
    """
  end

  def validation_function do
    """
    CREATE FUNCTION barkpark_validate_release_gate() RETURNS trigger AS $$
    DECLARE gate cycle_release_gate_admissions%ROWTYPE;
    BEGIN
      IF TG_TABLE_NAME = 'cycle_release_gate_admissions' THEN
        IF NEW.receipt->>'format' <> 'cycle-release-gate-v1' OR NEW.receipt->>'stage' <> NEW.stage OR
           NEW.receipt_digest <> barkpark_jsonb_canonical_digest(NEW.receipt - 'receipt_digest') OR
           NEW.receipt->>'receipt_digest' <> NEW.receipt_digest OR
           NEW.bundle_digest <> barkpark_jsonb_canonical_digest(NEW.evidence_bundle) THEN
          RAISE EXCEPTION 'release gate canonical digest or stage mismatch';
        END IF;
        IF NEW.stage = 'open' AND (NEW.target_wave_id IS NOT NULL OR NEW.challenge_id IS NOT NULL OR NEW.evidence_bundle <> '{}'::jsonb) THEN
          RAISE EXCEPTION 'open gate cannot contain post-open evidence';
        END IF;
        IF NEW.stage = 'activate' AND (NEW.target_wave_id IS NULL OR NEW.challenge_id IS NULL OR NOT EXISTS (
          SELECT 1 FROM cycle_release_gate_challenges c WHERE c.id = NEW.challenge_id AND c.target_wave_id = NEW.target_wave_id
            AND c.workspace_id = NEW.workspace_id AND c.project_id = NEW.project_id AND c.epic_id = NEW.epic_id
            AND c.completed_at IS NOT NULL AND c.request_digest = barkpark_jsonb_canonical_digest(c.request)
        ) OR (SELECT count(*) FROM cycle_release_gate_captures cap WHERE cap.challenge_id = NEW.challenge_id) <> 10 OR EXISTS (
          SELECT 1 FROM cycle_release_gate_captures cap WHERE cap.challenge_id = NEW.challenge_id AND (
            cap.name NOT IN ('campaign.source_json','campaign.public_html','campaign.cli','campaign.task_board','campaign.tui',
              'successor.source_json','successor.public_html','successor.cli','successor.task_board','successor.tui') OR
            cap.producer NOT IN ('server_http','server_cli','server_tui') OR cap.byte_count <> octet_length(cap.raw_bytes) OR
            cap.content_digest <> encode(digest(cap.raw_bytes, 'sha256'), 'hex') OR
            cap.provenance_digest <> barkpark_jsonb_canonical_digest(cap.provenance) OR
            cap.verdict_digest <> barkpark_jsonb_canonical_digest(cap.verdict) OR cap.verdict->>'status' <> 'pass'
          )
        )) THEN RAISE EXCEPTION 'activate gate requires ten exact server-owned captures'; END IF;
        RETURN NEW;
      END IF;

      IF TG_TABLE_NAME = 'cycle_release_paper_candidates' THEN
        IF NEW.content_digest <> barkpark_jsonb_canonical_digest(NEW.content) OR
           NEW.source_digest <> barkpark_jsonb_canonical_digest(jsonb_build_object('kind','blocks','blocks',NEW.content->'blocks')) OR
           jsonb_typeof(NEW.content->'blocks') <> 'array' OR NOT EXISTS (
             SELECT 1 FROM cycle_waves wave JOIN documents document ON document.id = NEW.document_id
             WHERE wave.id = NEW.target_wave_id AND document.workspace_id = wave.workspace_id
               AND document.project_id = wave.project_id AND document.type = 'paper'
               AND document.dataset = 'production' AND document.doc_id = NEW.doc_id
               AND document.rev = NEW.base_document_rev
               AND document.current_revision_id IS NOT DISTINCT FROM NEW.base_current_revision_id
               AND document.released_revision_id IS NOT DISTINCT FROM NEW.base_released_revision_id
           ) THEN RAISE EXCEPTION 'Paper candidate digest, source, or scope mismatch'; END IF;
        RETURN NEW;
      END IF;

      IF TG_TABLE_NAME = 'cycle_release_gate_consumptions' THEN
        SELECT * INTO gate FROM cycle_release_gate_admissions WHERE id = NEW.admission_id;
        IF NOT FOUND OR gate.stage <> NEW.kind OR gate.reserved_target_revision <> NEW.wave_id OR
           (NEW.kind = 'activate' AND gate.target_wave_id IS DISTINCT FROM NEW.wave_id) THEN
          RAISE EXCEPTION 'release gate consumption does not match its immutable admission';
        END IF;
        RETURN NEW;
      END IF;

      IF TG_TABLE_NAME = 'cycle_waves' THEN
        IF NEW.correction_of_wave_id IS NOT NULL AND NEW.release_gate_required AND NOT EXISTS (
          SELECT 1 FROM cycle_release_gate_consumptions c JOIN cycle_release_gate_admissions a ON a.id = c.admission_id
          WHERE c.wave_id = NEW.id AND c.kind = 'open' AND a.parent_wave_id = NEW.correction_of_wave_id
            AND a.workspace_id = NEW.workspace_id AND a.project_id = NEW.project_id AND a.epic_id = NEW.epic_id AND a.target_wave_key = NEW.wave_id
            AND a.receipt->'proposed'->>'correction_of_digest' = NEW.correction_of_digest
        ) THEN RAISE EXCEPTION 'new correction requires an exact consumed open release gate'; END IF;
        RETURN NEW;
      END IF;

      IF TG_TABLE_NAME = 'cycle_correction_promotion_events' AND NEW.action = 'promote' THEN
        IF NEW.release_gate_admission_id IS NULL OR NOT EXISTS (
          SELECT 1 FROM cycle_release_gate_admissions a JOIN cycle_release_gate_consumptions c ON c.admission_id = a.id
          WHERE a.id = NEW.release_gate_admission_id AND a.stage = 'activate' AND a.root_wave_id = NEW.root_wave_id
            AND a.target_wave_id = NEW.target_wave_id AND c.wave_id = NEW.target_wave_id AND c.kind = 'activate'
        ) OR NEW.release_materialization IS NULL OR
          jsonb_typeof(NEW.release_materialization->'documents') IS DISTINCT FROM 'array' OR
          jsonb_array_length(NEW.release_materialization->'documents') <> 2 OR
          NEW.release_materialization->>'digest' IS DISTINCT FROM barkpark_jsonb_canonical_digest(NEW.release_materialization - 'digest')
          OR EXISTS (
            SELECT 1 FROM jsonb_array_elements(NEW.release_materialization->'documents') row
            LEFT JOIN cycle_release_paper_candidates candidate
              ON candidate.id = (row->>'candidate_id')::uuid AND candidate.target_wave_id = NEW.target_wave_id
            LEFT JOIN revisions revision ON revision.id = candidate.id AND revision.document_id = candidate.document_id
            LEFT JOIN documents document ON document.id = candidate.document_id
            WHERE candidate.id IS NULL OR revision.id IS NULL OR document.id IS NULL OR
              row->>'role' <> candidate.role OR row->>'document_id' <> candidate.document_id::text OR
              row->>'doc_id' <> candidate.doc_id OR row->>'title' <> candidate.title OR
              row->>'status' <> candidate.status OR row->>'content_digest' <> candidate.content_digest OR
              row->>'source_digest' <> candidate.source_digest OR
              row->'after'->>'current_revision_id' <> candidate.id::text OR
              row->'after'->>'released_revision_id' <> candidate.id::text OR
              document.current_revision_id IS DISTINCT FROM candidate.id OR
              document.released_revision_id IS DISTINCT FROM candidate.id OR
              barkpark_jsonb_canonical_digest(revision.content) <> candidate.content_digest
          ) OR (SELECT array_agg(row->>'role' ORDER BY row->>'role')
                FROM jsonb_array_elements(NEW.release_materialization->'documents') row)
               IS DISTINCT FROM ARRAY['campaign','successor']::text[]
        THEN RAISE EXCEPTION 'promotion requires an exact consumed activate release gate'; END IF;
      END IF;
      RETURN NEW;
    END; $$ LANGUAGE plpgsql;
    """
  end
end
