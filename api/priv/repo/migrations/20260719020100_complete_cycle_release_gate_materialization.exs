defmodule Barkpark.Repo.Migrations.CompleteCycleReleaseGateMaterialization do
  use Ecto.Migration

  @state_table "cycle_release_gate_migration_state_20260719020100"
  @failure_archive "cycle_release_gate_failed_challenge_rollback_20260719020100"

  def up do
    anchor = release_hmac_anchor!()

    execute """
    CREATE TABLE IF NOT EXISTS #{@state_table} (
      singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
      validation_function text NOT NULL
    )
    """

    execute """
    INSERT INTO #{@state_table} (singleton, validation_function)
    SELECT true, pg_get_functiondef('barkpark_validate_release_gate()'::regprocedure)
    ON CONFLICT (singleton) DO NOTHING
    """

    execute """
    ALTER TABLE cycle_correction_promotion_events
      ADD COLUMN IF NOT EXISTS release_gate_admission_id uuid,
      ADD COLUMN IF NOT EXISTS release_materialization jsonb
    """

    execute """
    ALTER TABLE cycle_release_paper_candidates
      ADD COLUMN IF NOT EXISTS base_document_rev text,
      ADD COLUMN IF NOT EXISTS base_current_revision_id uuid,
      ADD COLUMN IF NOT EXISTS base_released_revision_id uuid
    """

    ensure_foreign_key(
      "cycle_correction_promotion_events",
      "release_gate_admission_id",
      "cycle_release_gate_admissions",
      "cycle_correction_promotion_events_release_gate_admission_id_fkey"
    )

    execute "ALTER TABLE cycle_release_gate_challenges ADD COLUMN IF NOT EXISTS failed_at timestamptz"
    execute "ALTER TABLE cycle_release_gate_challenges ADD COLUMN IF NOT EXISTS failure text"

    execute "ALTER TABLE cycle_release_gate_captures ADD COLUMN IF NOT EXISTS server_signature text"

    execute "DROP INDEX IF EXISTS cycle_release_gate_challenges_live_target_index"

    execute "DROP TRIGGER IF EXISTS cycle_release_gate_challenges_transition ON cycle_release_gate_challenges"

    execute """
    DO $restore_failures$
    BEGIN
      IF to_regclass('#{@failure_archive}') IS NOT NULL THEN
        EXECUTE 'UPDATE cycle_release_gate_challenges challenge
          SET completed_at = archive.original_completed_at,
              failed_at = archive.failed_at,
              failure = archive.failure
          FROM #{@failure_archive} archive
          WHERE challenge.id = archive.challenge_id';
      END IF;
    END
    $restore_failures$
    """

    execute challenge_transition_function()

    execute """
    CREATE TRIGGER cycle_release_gate_challenges_transition
    BEFORE UPDATE OR DELETE ON cycle_release_gate_challenges
    FOR EACH ROW EXECUTE FUNCTION barkpark_release_gate_challenge_transition()
    """

    execute """
    CREATE UNIQUE INDEX cycle_release_gate_challenges_live_target_index
    ON cycle_release_gate_challenges (target_wave_id)
    WHERE completed_at IS NULL AND failed_at IS NULL
    """

    execute "DROP TABLE IF EXISTS #{@failure_archive}"

    ensure_foreign_key(
      "cycle_release_paper_candidates",
      "base_current_revision_id",
      "revisions",
      "cycle_release_paper_candidates_base_current_revision_id_fkey"
    )

    ensure_foreign_key(
      "cycle_release_paper_candidates",
      "base_released_revision_id",
      "revisions",
      "cycle_release_paper_candidates_base_released_revision_id_fkey"
    )

    create_if_not_exists table(:cycle_release_public_smokes, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :promotion_event_id,
          references(:cycle_correction_promotion_events, type: :uuid, on_delete: :delete_all),
          null: false

      add :root_wave_id, references(:cycle_waves, type: :uuid, on_delete: :delete_all),
        null: false

      add :target_wave_id, references(:cycle_waves, type: :uuid, on_delete: :delete_all),
        null: false

      add :state, :text, null: false
      add :request, :map, null: false
      add :proof, :map
      add :proof_digest, :text
      add :failure, :map

      add :compensation_event_id,
          references(:cycle_correction_promotion_events, type: :uuid, on_delete: :restrict)

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists unique_index(:cycle_release_public_smokes, [:promotion_event_id])

    create constraint(:cycle_release_public_smokes, :cycle_release_public_smoke_state,
             check: "state IN ('pending','pass','failed','compensated')"
           )

    execute """
    CREATE FUNCTION barkpark_release_public_smoke_transition() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'INSERT' THEN
        IF NEW.state IS DISTINCT FROM 'pending' OR NEW.proof IS NOT NULL OR NEW.proof_digest IS NOT NULL OR
           NEW.failure IS NOT NULL OR NEW.compensation_event_id IS NOT NULL OR
           NEW.request->>'format' IS DISTINCT FROM 'cycle-release-public-smoke-request-v1' OR
           NEW.request->>'promotion_event_id' IS DISTINCT FROM NEW.promotion_event_id::text OR
           NEW.request->>'root_wave_revision' IS DISTINCT FROM NEW.root_wave_id::text OR
           NEW.request->>'target_wave_revision' IS DISTINCT FROM NEW.target_wave_id::text OR
           (NEW.request->>'deployment_digest' ~ '^[0-9a-f]{64}$') IS DISTINCT FROM true OR
           (NEW.request->>'canonical_origin' ~ '^https?://[^/]+$') IS DISTINCT FROM true OR
           jsonb_typeof(NEW.request->'documents') IS DISTINCT FROM 'array' OR
           jsonb_array_length(NEW.request->'documents') <> 2 OR NOT EXISTS (
             SELECT 1 FROM cycle_correction_promotion_events event
             WHERE event.id = NEW.promotion_event_id AND event.action = 'promote'
               AND event.root_wave_id = NEW.root_wave_id AND event.target_wave_id = NEW.target_wave_id
               AND NOT EXISTS (
                 SELECT 1 FROM jsonb_array_elements(NEW.request->'documents') request_document
                 LEFT JOIN jsonb_array_elements(event.release_materialization->'documents') materialized
                   ON materialized->>'role' = request_document->>'role'
                 WHERE materialized IS NULL OR
                   request_document->>'document_id' IS DISTINCT FROM materialized->>'document_id' OR
                   request_document->>'doc_id' IS DISTINCT FROM materialized->>'doc_id' OR
                   request_document->>'title' IS DISTINCT FROM materialized->>'title' OR
                   request_document->>'content_digest' IS DISTINCT FROM materialized->>'content_digest' OR
                   request_document->>'revision_id' IS DISTINCT FROM materialized->'after'->>'released_revision_id'
               )
           ) OR (SELECT array_agg(document->>'role' ORDER BY document->>'role')
                 FROM jsonb_array_elements(NEW.request->'documents') document)
                IS DISTINCT FROM ARRAY['campaign','successor']::text[] OR
             (SELECT count(DISTINCT document->>'document_id') = 2 AND
                     count(DISTINCT document->>'doc_id') = 2 AND
                     count(DISTINCT document->>'url') = 2
                FROM jsonb_array_elements(NEW.request->'documents') document) IS DISTINCT FROM true OR EXISTS (
             SELECT 1 FROM jsonb_array_elements(NEW.request->'documents') document
             WHERE (document->>'url' LIKE (NEW.request->>'canonical_origin') || '/w/%/p/%/papers/%') IS DISTINCT FROM true
               OR document->>'url' ~ '[?#]'
           ) THEN RAISE EXCEPTION 'invalid pending public smoke authority'; END IF;
        RETURN NEW;
      END IF;

      IF TG_OP = 'DELETE' THEN
        IF pg_trigger_depth() > 1 THEN RETURN OLD; END IF;
        RAISE EXCEPTION 'release public smoke rows cannot be deleted';
      END IF;

      IF NEW.promotion_event_id <> OLD.promotion_event_id OR
         NEW.root_wave_id <> OLD.root_wave_id OR NEW.target_wave_id <> OLD.target_wave_id OR
         NEW.request <> OLD.request OR NEW.inserted_at <> OLD.inserted_at THEN
        RAISE EXCEPTION 'release public smoke authority is immutable';
      END IF;

      IF OLD.state = 'pending' AND NEW.state = 'pass' AND
         NEW.proof IS NOT NULL AND NEW.proof_digest IS NOT NULL AND NEW.failure IS NULL AND
         NEW.compensation_event_id IS NULL AND
         current_setting('barkpark.release_capture_hmac_secret', true) IS NOT NULL AND
         encode(digest(convert_to(current_setting('barkpark.release_capture_hmac_secret', true), 'UTF8'), 'sha256'), 'hex') = '#{anchor}' AND
         NEW.proof_digest = barkpark_jsonb_canonical_digest(NEW.proof - 'digest' - 'attestation') AND
         NEW.proof->>'digest' = NEW.proof_digest AND NEW.proof->'request' = OLD.request AND
         (NEW.proof->>'attestation' ~ '^[0-9a-f]{64}$') IS NOT DISTINCT FROM true AND
         NEW.proof->>'attestation' = encode(hmac(convert_to(NEW.proof_digest, 'UTF8'),
           convert_to(current_setting('barkpark.release_capture_hmac_secret', true), 'UTF8'), 'sha256'), 'hex') AND
         NEW.proof->'proof'->>'format' = 'cycle-release-public-smoke-v1' AND
         jsonb_typeof(NEW.proof->'proof'->'attempts') = 'array' AND
         jsonb_array_length(NEW.proof->'proof'->'attempts') = 2 AND
         (SELECT array_agg(attempt->>'role' ORDER BY attempt->>'role')
            FROM jsonb_array_elements(NEW.proof->'proof'->'attempts') attempt)
           IS NOT DISTINCT FROM ARRAY['campaign','successor']::text[] AND NOT EXISTS (
           SELECT 1
           FROM jsonb_array_elements(NEW.proof->'proof'->'attempts') attempt
           LEFT JOIN jsonb_array_elements(OLD.request->'documents') document
             ON document->>'role' = attempt->>'role'
           WHERE document IS NULL OR attempt->>'document_id' IS DISTINCT FROM document->>'document_id' OR
             attempt->>'doc_id' IS DISTINCT FROM document->>'doc_id' OR attempt->>'url' IS DISTINCT FROM document->>'url' OR
             attempt->>'deployment_digest' IS DISTINCT FROM OLD.request->>'deployment_digest' OR
             attempt->>'verdict' IS DISTINCT FROM 'pass' OR attempt->>'status' IS DISTINCT FROM '200' OR
             attempt->>'redirect_count' IS DISTINCT FROM '0' OR
             (attempt->>'byte_count' ~ '^[1-9][0-9]*$') IS DISTINCT FROM true OR
             (attempt->>'response_digest' ~ '^[0-9a-f]{64}$') IS DISTINCT FROM true OR
             (attempt->'response_headers'->>'content_type' ILIKE 'text/html%') IS DISTINCT FROM true OR
             attempt->'response_headers'->>'x_barkpark_paper_revision' IS DISTINCT FROM document->>'revision_id' OR
             attempt->'response_headers'->>'etag' IS DISTINCT FROM ('"sha256:' || (document->>'content_digest') || '"')
         ) THEN RETURN NEW; END IF;

      IF OLD.state = 'pending' AND NEW.state = 'failed' AND
         NEW.failure IS NOT NULL AND NEW.proof IS NULL AND NEW.proof_digest IS NULL AND
         NEW.compensation_event_id IS NULL THEN RETURN NEW; END IF;

      IF OLD.state = 'failed' AND NEW.state = 'compensated' AND
         NEW.failure = OLD.failure AND NEW.proof IS NULL AND NEW.proof_digest IS NULL AND
         NEW.compensation_event_id IS NOT NULL AND EXISTS (
           SELECT 1
           FROM cycle_correction_promotion_events promoted
           JOIN cycle_correction_promotion_events rollback
             ON rollback.id = NEW.compensation_event_id
           LEFT JOIN cycle_correction_promotion_events previous
             ON previous.id = promoted.previous_event_id
           LEFT JOIN cycle_correction_promotion_events restore
             ON restore.id = CASE
               WHEN previous.action = 'rollback' THEN previous.restore_event_id
               ELSE promoted.previous_event_id
             END
           WHERE promoted.id = OLD.promotion_event_id AND promoted.action = 'promote'
             AND promoted.root_wave_id = OLD.root_wave_id
             AND promoted.target_wave_id = OLD.target_wave_id
             AND rollback.action = 'rollback'
             AND rollback.root_wave_id = OLD.root_wave_id
             AND rollback.previous_event_id = OLD.promotion_event_id
             AND rollback.restore_event_id IS NOT DISTINCT FROM CASE
               WHEN previous.action = 'rollback' THEN previous.restore_event_id
               ELSE promoted.previous_event_id
             END
             AND rollback.target_wave_id = COALESCE(restore.target_wave_id, OLD.root_wave_id)
         ) AND EXISTS (
           SELECT 1 FROM cycle_correction_quarantines quarantine
           WHERE quarantine.root_wave_id = OLD.root_wave_id
             AND quarantine.correction_wave_id = OLD.target_wave_id
             AND quarantine.evidence = 'public-reader-smoke://' || OLD.promotion_event_id::text || '/failed'
             AND quarantine.evidence_revision = barkpark_jsonb_canonical_digest(OLD.failure)
         ) THEN RETURN NEW; END IF;

      RAISE EXCEPTION 'invalid release public smoke state transition';
    END; $$ LANGUAGE plpgsql;

    """

    execute """
    CREATE TRIGGER cycle_release_public_smokes_transition
    BEFORE INSERT OR UPDATE OR DELETE ON cycle_release_public_smokes
    FOR EACH ROW EXECUTE FUNCTION barkpark_release_public_smoke_transition()
    """

    execute validation_function(anchor)
  end

  def down do
    drop_if_exists table(:cycle_release_public_smokes)
    execute "DROP FUNCTION IF EXISTS barkpark_release_public_smoke_transition()"

    execute "DROP TRIGGER IF EXISTS cycle_release_gate_challenges_transition ON cycle_release_gate_challenges"

    execute """
    CREATE TABLE IF NOT EXISTS #{@failure_archive} (
      challenge_id uuid PRIMARY KEY,
      failed_at timestamptz NOT NULL,
      failure text NOT NULL,
      original_completed_at timestamptz
    )
    """

    execute """
    INSERT INTO #{@failure_archive} (challenge_id, failed_at, failure, original_completed_at)
    SELECT id, failed_at, failure, completed_at
    FROM cycle_release_gate_challenges
    WHERE failed_at IS NOT NULL
    ON CONFLICT (challenge_id) DO UPDATE
      SET failed_at = EXCLUDED.failed_at,
          failure = EXCLUDED.failure,
          original_completed_at = EXCLUDED.original_completed_at
    """

    execute """
    UPDATE cycle_release_gate_challenges
    SET completed_at = failed_at
    WHERE failed_at IS NOT NULL
    """

    execute prior_challenge_transition_function()

    execute """
    CREATE TRIGGER cycle_release_gate_challenges_transition
    BEFORE UPDATE OR DELETE ON cycle_release_gate_challenges
    FOR EACH ROW EXECUTE FUNCTION barkpark_release_gate_challenge_transition()
    """

    execute "DROP INDEX IF EXISTS cycle_release_gate_challenges_live_target_index"

    execute """
    CREATE UNIQUE INDEX cycle_release_gate_challenges_live_target_index
    ON cycle_release_gate_challenges (target_wave_id)
    WHERE completed_at IS NULL
    """

    execute "ALTER TABLE cycle_release_gate_challenges DROP COLUMN IF EXISTS failure"
    execute "ALTER TABLE cycle_release_gate_challenges DROP COLUMN IF EXISTS failed_at"
    execute "ALTER TABLE cycle_release_gate_captures DROP COLUMN IF EXISTS server_signature"

    execute """
    DO $restore$
    DECLARE prior_definition text;
    BEGIN
      SELECT validation_function INTO prior_definition
      FROM #{@state_table}
      WHERE singleton = true;

      IF prior_definition IS NULL THEN
        RAISE EXCEPTION 'missing prior release-gate validation definition';
      END IF;

      EXECUTE prior_definition;
    END
    $restore$
    """

    execute "DROP TABLE #{@state_table}"
  end

  defp ensure_foreign_key(table, column, target, constraint) do
    execute """
    DO $foreign_key$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint constraint_row
        JOIN pg_attribute attribute
          ON attribute.attrelid = constraint_row.conrelid
         AND attribute.attnum = ANY (constraint_row.conkey)
        WHERE constraint_row.contype = 'f'
          AND constraint_row.conrelid = '#{table}'::regclass
          AND constraint_row.confrelid = '#{target}'::regclass
          AND attribute.attname = '#{column}'
      ) THEN
        ALTER TABLE #{table}
          ADD CONSTRAINT #{constraint}
          FOREIGN KEY (#{column}) REFERENCES #{target}(id);
      END IF;
    END
    $foreign_key$
    """
  end

  defp challenge_transition_function do
    """
    CREATE OR REPLACE FUNCTION barkpark_release_gate_challenge_transition() RETURNS trigger AS $$
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
      IF OLD.failed_at IS NOT NULL AND
         (NEW.failed_at IS DISTINCT FROM OLD.failed_at OR NEW.failure IS DISTINCT FROM OLD.failure) THEN
        RAISE EXCEPTION 'release gate challenge failure cannot change';
      END IF;
      IF NEW.completed_at IS NOT NULL AND (NEW.claimed_at IS NULL OR NEW.failed_at IS NOT NULL) OR
         NEW.failed_at IS NOT NULL AND (NEW.claimed_at IS NULL OR NEW.completed_at IS NOT NULL OR
           NEW.failure NOT IN ('capture_failed','finalize_failed')) OR
         NEW.failed_at IS NULL AND NEW.failure IS NOT NULL OR
         NEW.failed_at IS NOT NULL AND NEW.failure IS NULL THEN
        RAISE EXCEPTION 'release gate challenge terminal state is invalid';
      END IF;
      IF NEW.claimed_at IS NOT NULL AND NEW.claimed_at < OLD.inserted_at OR
         NEW.completed_at IS NOT NULL AND NEW.completed_at < NEW.claimed_at OR
         NEW.failed_at IS NOT NULL AND NEW.failed_at < NEW.claimed_at THEN
        RAISE EXCEPTION 'release gate challenge timestamps regress';
      END IF;
      RETURN NEW;
    END; $$ LANGUAGE plpgsql;
    """
  end

  defp prior_challenge_transition_function do
    """
    CREATE OR REPLACE FUNCTION barkpark_release_gate_challenge_transition() RETURNS trigger AS $$
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

  defp validation_function(anchor) do
    """
    CREATE OR REPLACE FUNCTION barkpark_validate_release_gate() RETURNS trigger AS $$
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
            AND c.request->>'format' IS NOT DISTINCT FROM 'cycle-release-capture-request-v1'
            AND c.request->>'release_gate_id' IS NOT DISTINCT FROM NEW.receipt->'authority'->>'open_gate_id'
            AND c.request->>'wave_revision' IS NOT DISTINCT FROM NEW.target_wave_id::text
            AND c.request->>'workspace_id' IS NOT DISTINCT FROM NEW.workspace_id::text
            AND c.request->>'project_id' IS NOT DISTINCT FROM NEW.project_id::text
            AND c.request->>'epic_id' IS NOT DISTINCT FROM NEW.epic_id
            AND c.request->>'wave_id' IS NOT DISTINCT FROM NEW.target_wave_key
            AND (c.request->>'deployment_digest' ~ '^[0-9a-f]{64}$') IS NOT DISTINCT FROM true
            AND c.request->>'b1_experiment_id' IS NOT DISTINCT FROM NEW.receipt->>'b1_experiment_id'
            AND NEW.receipt->'papers' IS NOT DISTINCT FROM jsonb_build_array(c.request->'candidates'->'campaign', c.request->'candidates'->'successor')
        ) OR (SELECT count(*) FROM cycle_release_gate_captures cap WHERE cap.challenge_id = NEW.challenge_id) <> 10 OR EXISTS (
          SELECT 1 FROM cycle_release_gate_captures cap
          JOIN cycle_release_gate_challenges c ON c.id = cap.challenge_id
          CROSS JOIN LATERAL (SELECT split_part(cap.name,'.',1) AS role, split_part(cap.name,'.',2) AS surface) identity
          WHERE cap.challenge_id = NEW.challenge_id AND (
            cap.name NOT IN ('campaign.source_json','campaign.public_html','campaign.cli','campaign.task_board','campaign.tui',
              'successor.source_json','successor.public_html','successor.cli','successor.task_board','successor.tui') OR
            cap.producer IS DISTINCT FROM CASE identity.surface WHEN 'source_json' THEN 'server_http' WHEN 'public_html' THEN 'server_http'
              WHEN 'cli' THEN 'server_cli' WHEN 'task_board' THEN 'server_cli' WHEN 'tui' THEN 'server_tui' END OR
            cap.byte_count IS DISTINCT FROM octet_length(cap.raw_bytes) OR cap.byte_count <= 31 OR
            cap.content_digest IS DISTINCT FROM encode(digest(cap.raw_bytes, 'sha256'), 'hex') OR
            cap.provenance_digest IS DISTINCT FROM barkpark_jsonb_canonical_digest(cap.provenance) OR
            cap.verdict_digest IS DISTINCT FROM barkpark_jsonb_canonical_digest(cap.verdict) OR
            cap.verdict IS DISTINCT FROM jsonb_build_object('status','pass','wave_revision',NEW.target_wave_id::text) OR
            current_setting('barkpark.release_capture_hmac_secret', true) IS NULL OR
            encode(digest(convert_to(current_setting('barkpark.release_capture_hmac_secret', true), 'UTF8'), 'sha256'), 'hex') IS DISTINCT FROM '#{anchor}' OR
            (cap.server_signature ~ '^[0-9a-f]{64}$') IS DISTINCT FROM true OR
            cap.server_signature IS DISTINCT FROM encode(hmac(
              convert_to(concat_ws(E'\n', cap.challenge_id::text, cap.name, cap.producer, cap.byte_count::text,
                cap.content_digest, cap.provenance_digest, cap.verdict_digest), 'UTF8'),
              convert_to(current_setting('barkpark.release_capture_hmac_secret', true), 'UTF8'), 'sha256'), 'hex') OR
            cap.provenance->>'release_gate_id' IS DISTINCT FROM c.request->>'release_gate_id' OR
            cap.provenance->>'wave_revision' IS DISTINCT FROM NEW.target_wave_id::text OR
            cap.provenance->>'candidate_id' IS DISTINCT FROM c.request->'candidates'->identity.role->>'candidate_id' OR
            cap.provenance->>'role' IS DISTINCT FROM identity.role OR cap.provenance->>'surface' IS DISTINCT FROM identity.surface OR
            cap.provenance->>'redirect_count' IS DISTINCT FROM '0' OR
            cap.provenance->'request' IS DISTINCT FROM c.request->'readers'->identity.role->identity.surface OR
            cap.provenance->>'deployment_digest' IS DISTINCT FROM c.request->>'deployment_digest' OR
            (cap.provenance->>'binary_digest' ~ '^[0-9a-f]{64}$') IS DISTINCT FROM true OR
            (cap.provenance->>'parser_digest' ~ '^[0-9a-f]{64}$') IS DISTINCT FROM true OR
            CASE WHEN identity.surface IN ('source_json','public_html') THEN
              cap.provenance->>'status' IS DISTINCT FROM '200' OR
              cap.provenance->'response_headers'->>'etag' IS DISTINCT FROM ('"sha256:' || (c.request->'candidates'->identity.role->>'content_digest') || '"') OR
              cap.provenance->'response_headers'->>'x_barkpark_release_gate' IS DISTINCT FROM c.request->>'release_gate_id' OR
              cap.provenance->'response_headers'->>'x_barkpark_wave_revision' IS DISTINCT FROM NEW.target_wave_id::text OR
              cap.provenance->'response_headers'->>'x_barkpark_paper_candidate' IS DISTINCT FROM c.request->'candidates'->identity.role->>'candidate_id' OR
              cap.provenance->'response_headers'->>'x_barkpark_paper_role' IS DISTINCT FROM identity.role
            ELSE
              cap.provenance->>'status' IS DISTINCT FROM '0' OR cap.provenance->'argv' IS DISTINCT FROM c.request->'readers'->identity.role->identity.surface->'argv' OR
              cap.provenance->>'geometry' IS DISTINCT FROM CASE identity.surface WHEN 'tui' THEN '120xunbounded;measure=100' ELSE '120xunbounded' END OR
              cap.provenance->>'theme' IS DISTINCT FROM CASE identity.surface WHEN 'task_board' THEN 'task-board-dark' ELSE 'evergreen-dark' END OR
              cap.provenance->>'profile' IS DISTINCT FROM CASE identity.surface WHEN 'cli' THEN 'none' ELSE 'ansi256' END
            END OR
            CASE WHEN identity.surface = 'source_json' THEN
              convert_from(cap.raw_bytes,'UTF8')::jsonb->>'release_gate_id' IS DISTINCT FROM c.request->>'release_gate_id' OR
              convert_from(cap.raw_bytes,'UTF8')::jsonb->>'wave_revision' IS DISTINCT FROM NEW.target_wave_id::text OR
              convert_from(cap.raw_bytes,'UTF8')::jsonb->>'candidate_id' IS DISTINCT FROM c.request->'candidates'->identity.role->>'candidate_id' OR
              convert_from(cap.raw_bytes,'UTF8')::jsonb->>'role' IS DISTINCT FROM identity.role OR
              convert_from(cap.raw_bytes,'UTF8')::jsonb->>'document_id' IS DISTINCT FROM c.request->'candidates'->identity.role->>'document_id' OR
              convert_from(cap.raw_bytes,'UTF8')::jsonb->>'doc_id' IS DISTINCT FROM c.request->'candidates'->identity.role->>'doc_id' OR
              convert_from(cap.raw_bytes,'UTF8')::jsonb->>'title' IS DISTINCT FROM c.request->'candidates'->identity.role->>'title' OR
              convert_from(cap.raw_bytes,'UTF8')::jsonb->>'content_digest' IS DISTINCT FROM c.request->'candidates'->identity.role->>'content_digest' OR
              barkpark_jsonb_canonical_digest(convert_from(cap.raw_bytes,'UTF8')::jsonb->'source') IS DISTINCT FROM c.request->'candidates'->identity.role->>'source_digest'
            ELSE
              coalesce(position(lower(c.request->'candidates'->identity.role->>'title') in lower(convert_from(cap.raw_bytes,'UTF8'))), 0) = 0 OR
              (lower(convert_from(cap.raw_bytes,'UTF8')) LIKE '%503%' AND lower(convert_from(cap.raw_bytes,'UTF8')) LIKE '%42%' AND
                lower(convert_from(cap.raw_bytes,'UTF8')) LIKE '%291%' AND lower(convert_from(cap.raw_bytes,'UTF8')) LIKE '%170%' AND
                lower(convert_from(cap.raw_bytes,'UTF8')) LIKE '%current%' AND lower(convert_from(cap.raw_bytes,'UTF8')) LIKE '%superseded%' AND
                lower(convert_from(cap.raw_bytes,'UTF8')) LIKE '%-11%' AND lower(convert_from(cap.raw_bytes,'UTF8')) LIKE '%+11%') IS DISTINCT FROM true OR
              identity.surface = 'public_html' AND
                (position('<' in convert_from(cap.raw_bytes,'UTF8')) = 0 OR
                 lower(convert_from(cap.raw_bytes,'UTF8')) LIKE '%data-release-debug%')
            END
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
        IF NEW.release_gate_admission_id IS NULL OR
          (SELECT count(*) FROM cycle_release_public_smokes smoke
           WHERE smoke.promotion_event_id = NEW.id) <> 1 OR EXISTS (
            SELECT 1 FROM cycle_release_public_smokes smoke
            WHERE smoke.root_wave_id = NEW.root_wave_id AND
              smoke.promotion_event_id <> NEW.id AND smoke.state IN ('pending','failed')
          ) OR NOT EXISTS (
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

  defp release_hmac_anchor! do
    # The database stores only this one-way migration-time anchor. Rotating the
    # runtime secret deliberately fails closed until a forward migration
    # replaces both anchored verifier functions atomically.
    case Application.get_env(:barkpark, :cycle_release_capture_hmac_secret) do
      secret when is_binary(secret) and byte_size(secret) >= 32 ->
        :sha256
        |> :crypto.hash(secret)
        |> Base.encode16(case: :lower)

      _ ->
        raise "cycle release capture HMAC secret must contain at least 32 bytes during migration"
    end
  end
end
