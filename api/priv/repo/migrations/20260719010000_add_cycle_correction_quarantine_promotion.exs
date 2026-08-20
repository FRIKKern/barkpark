defmodule Barkpark.Repo.Migrations.AddCycleCorrectionQuarantinePromotion do
  use Ecto.Migration

  def up do
    alter table(:revisions) do
      add :document_id, references(:documents, type: :uuid, on_delete: :nilify_all)
    end

    alter table(:documents) do
      add :current_revision_id, references(:revisions, type: :uuid, on_delete: :nilify_all)
      add :released_revision_id, references(:revisions, type: :uuid, on_delete: :nilify_all)
    end

    execute """
    WITH bindings AS (
      SELECT revision.id AS revision_id, (
        SELECT document.id
        FROM documents document
        WHERE revision.doc_id = CASE
            WHEN left(document.doc_id, 7) = 'drafts.' THEN substr(document.doc_id, 8)
            ELSE document.doc_id
          END AND
          revision.type = document.type AND
          revision.dataset IS NOT DISTINCT FROM document.dataset AND
          revision.dataset_id IS NOT DISTINCT FROM document.dataset_id AND
          revision.workspace_id IS NOT DISTINCT FROM document.workspace_id AND
          revision.project_id IS NOT DISTINCT FROM document.project_id AND
          revision.title IS NOT DISTINCT FROM document.title AND
          revision.status IS NOT DISTINCT FROM document.status AND
          revision.content IS NOT DISTINCT FROM document.content
        ORDER BY CASE WHEN document.doc_id = revision.doc_id THEN 0 ELSE 1 END, document.id
        LIMIT 1
      ) AS document_id
      FROM revisions revision
      WHERE revision.document_id IS NULL
    )
    UPDATE revisions revision
    SET document_id = bindings.document_id
    FROM bindings
    WHERE revision.id = bindings.revision_id AND bindings.document_id IS NOT NULL;
    """

    create index(:revisions, [:document_id])
    execute "ANALYZE revisions (document_id)"

    execute """
    WITH current_revisions AS (
      SELECT DISTINCT ON (revision.document_id)
        revision.document_id, revision.id
      FROM revisions revision
      JOIN documents document ON document.id = revision.document_id
      WHERE revision.content IS NOT DISTINCT FROM document.content AND
        revision.title IS NOT DISTINCT FROM document.title AND
        revision.status IS NOT DISTINCT FROM document.status
      ORDER BY revision.document_id, revision.inserted_at DESC, revision.id DESC
    )
    UPDATE documents document
    SET current_revision_id = current_revision.id
    FROM current_revisions current_revision
    WHERE document.id = current_revision.document_id;
    """

    execute """
    WITH released_revisions AS (
      SELECT DISTINCT ON (revision.document_id)
        revision.document_id, revision.id
      FROM revisions revision
      JOIN documents document ON document.id = revision.document_id
      WHERE revision.status = 'published' AND
        revision.content IS NOT DISTINCT FROM document.content AND
        revision.title IS NOT DISTINCT FROM document.title
      ORDER BY revision.document_id, revision.inserted_at DESC, revision.id DESC
    )
    UPDATE documents document
    SET released_revision_id = released_revision.id
    FROM released_revisions released_revision
    WHERE document.id = released_revision.document_id;
    """

    create table(:cycle_correction_roots, primary_key: false) do
      add :root_wave_id, references(:cycle_waves, type: :uuid, on_delete: :restrict),
        primary_key: true

      add :workspace_id, references(:workspaces, type: :uuid, on_delete: :restrict), null: false
      add :project_id, references(:projects, type: :uuid, on_delete: :restrict), null: false
      add :epic_id, :text, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create table(:cycle_correction_targets, primary_key: false) do
      add :wave_id, references(:cycle_waves, type: :uuid, on_delete: :restrict), primary_key: true

      add :root_wave_id,
          references(:cycle_correction_roots,
            column: :root_wave_id,
            type: :uuid,
            on_delete: :restrict
          ),
          null: false

      add :previous_wave_id, references(:cycle_waves, type: :uuid, on_delete: :restrict),
        null: false

      add :workspace_id, references(:workspaces, type: :uuid, on_delete: :restrict), null: false
      add :project_id, references(:projects, type: :uuid, on_delete: :restrict), null: false
      add :epic_id, :text, null: false
      add :correction_receipt, :map, null: false
      add :correction_receipt_digest, :text, null: false
      add :semantic_digest, :text, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:cycle_correction_targets, [:root_wave_id, :previous_wave_id],
             name: :cycle_correction_targets_previous_child_index
           )

    create table(:cycle_correction_admissions, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :root_wave_id, references(:cycle_correction_roots, column: :root_wave_id, type: :uuid),
        null: false

      add :target_wave_id, references(:cycle_correction_targets, column: :wave_id, type: :uuid),
        null: false

      add :workspace_id, references(:workspaces, type: :uuid), null: false
      add :project_id, references(:projects, type: :uuid), null: false
      add :epic_id, :text, null: false
      add :idempotency_key, :text, null: false
      add :reconciliation_digest, :text, null: false
      add :fleet_digest, :text, null: false
      add :b1_scope_receipt, :map, null: false
      add :b1_scope_receipt_digest, :text, null: false
      add :b1_experiment_id, references(:epic_benchmark_experiments, type: :uuid), null: false
      add :b1_ledger_digest, :text, null: false
      add :b1_bytes_digest, :text, null: false
      add :paper_document_id, references(:documents, type: :uuid), null: false
      add :paper_revision_id, references(:revisions, type: :uuid), null: false
      add :paper_doc_id, :text, null: false
      add :paper_content_digest, :text, null: false
      add :gate_receipt, :map, null: false
      add :gate_receipt_digest, :text, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:cycle_correction_admissions, [:root_wave_id, :idempotency_key],
             name: :cycle_correction_admissions_idempotency_index
           )

    create table(:cycle_correction_quarantines, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :root_wave_id, references(:cycle_correction_roots, column: :root_wave_id, type: :uuid),
        null: false

      add :correction_wave_id,
          references(:cycle_correction_targets, column: :wave_id, type: :uuid),
          null: false

      add :workspace_id, references(:workspaces, type: :uuid), null: false
      add :project_id, references(:projects, type: :uuid), null: false
      add :epic_id, :text, null: false
      add :idempotency_key, :text, null: false
      add :reason, :text, null: false
      add :actor, :map, null: false
      add :evidence, :text, null: false
      add :evidence_revision, :text, null: false
      add :correction_receipt, :map, null: false
      add :correction_receipt_digest, :text, null: false
      add :event_payload, :map, null: false
      add :event_digest, :text, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:cycle_correction_quarantines, [:root_wave_id, :idempotency_key],
             name: :cycle_correction_quarantines_idempotency_index
           )

    create index(:cycle_correction_quarantines, [:correction_wave_id])

    create table(:cycle_correction_promotion_events, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :admission_id, references(:cycle_correction_admissions, type: :uuid)

      add :root_wave_id, references(:cycle_correction_roots, column: :root_wave_id, type: :uuid),
        null: false

      add :target_wave_id, references(:cycle_waves, type: :uuid), null: false
      add :previous_event_id, :uuid
      add :restore_event_id, :uuid
      add :workspace_id, references(:workspaces, type: :uuid), null: false
      add :project_id, references(:projects, type: :uuid), null: false
      add :epic_id, :text, null: false
      add :action, :text, null: false
      add :idempotency_key, :text, null: false
      add :actor, :map, null: false
      add :evidence, :text, null: false
      add :evidence_revision, :text, null: false
      add :gate_receipt, :map
      add :event_payload, :map, null: false
      add :event_digest, :text, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    execute """
    ALTER TABLE cycle_correction_promotion_events
      ADD CONSTRAINT cycle_correction_promotion_events_previous_fkey
      FOREIGN KEY (previous_event_id) REFERENCES cycle_correction_promotion_events(id)
      ON DELETE RESTRICT DEFERRABLE INITIALLY IMMEDIATE,
      ADD CONSTRAINT cycle_correction_promotion_events_restore_fkey
      FOREIGN KEY (restore_event_id) REFERENCES cycle_correction_promotion_events(id)
      ON DELETE RESTRICT DEFERRABLE INITIALLY IMMEDIATE;
    """

    create unique_index(:cycle_correction_promotion_events, [:root_wave_id, :idempotency_key],
             name: :cycle_correction_promotion_events_idempotency_index
           )

    create unique_index(:cycle_correction_promotion_events, [:root_wave_id],
             where: "previous_event_id IS NULL",
             name: :cycle_correction_promotion_events_genesis_index
           )

    create unique_index(:cycle_correction_promotion_events, [:previous_event_id],
             where: "previous_event_id IS NOT NULL",
             name: :cycle_correction_promotion_events_previous_child_index
           )

    create constraint(:cycle_correction_promotion_events, :cycle_correction_promotion_action,
             check: "action IN ('promote', 'rollback')"
           )

    for table <- [
          :cycle_correction_targets,
          :cycle_correction_admissions,
          :cycle_correction_quarantines,
          :cycle_correction_promotion_events
        ],
        field <- [
          :correction_receipt_digest,
          :semantic_digest,
          :event_digest,
          :reconciliation_digest,
          :fleet_digest,
          :b1_scope_receipt_digest,
          :b1_ledger_digest,
          :b1_bytes_digest,
          :paper_content_digest,
          :gate_receipt_digest
        ],
        field_exists?(table, field) do
      create constraint(table, String.to_atom("#{table}_#{field}"),
               check: "#{field} ~ '^[0-9a-f]{64}$'"
             )
    end

    execute canonical_json_function()
    execute canonical_digest_function()
    execute paper_authority_function()
    execute b1_document_function()
    execute validation_function()
    execute immutability_function()
    execute guarded_teardown_function()
    execute workspace_cycle_teardown_function()
    execute "REVOKE ALL ON FUNCTION barkpark_prepare_workspace_cycle_teardown(uuid) FROM PUBLIC;"

    for table <- [
          :cycle_correction_roots,
          :cycle_correction_targets,
          :cycle_correction_admissions,
          :cycle_correction_quarantines,
          :cycle_correction_promotion_events
        ] do
      execute """
      CREATE TRIGGER #{table}_validate
      BEFORE INSERT ON #{table}
      FOR EACH ROW EXECUTE FUNCTION barkpark_validate_cycle_correction();
      """

      execute """
      CREATE TRIGGER #{table}_no_update_delete
      BEFORE UPDATE OR DELETE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION barkpark_cycle_correction_immutable();
      """
    end

    execute """
    CREATE FUNCTION barkpark_bind_document_revision() RETURNS trigger AS $$
    BEGIN
      IF NEW.document_id IS NULL THEN
        RETURN NEW;
      END IF;
      IF NOT EXISTS (
        SELECT 1 FROM documents document
        WHERE document.id = NEW.document_id AND
          NEW.doc_id = CASE
            WHEN left(document.doc_id, 7) = 'drafts.' THEN substr(document.doc_id, 8)
            ELSE document.doc_id
          END AND
          document.type = NEW.type AND
          document.dataset IS NOT DISTINCT FROM NEW.dataset AND
          document.dataset_id IS NOT DISTINCT FROM NEW.dataset_id AND
          document.workspace_id IS NOT DISTINCT FROM NEW.workspace_id AND
          document.project_id IS NOT DISTINCT FROM NEW.project_id AND
          document.title IS NOT DISTINCT FROM NEW.title AND
          document.status IS NOT DISTINCT FROM NEW.status AND
          document.content IS NOT DISTINCT FROM NEW.content
      ) THEN
        RAISE EXCEPTION 'revision snapshot does not exactly match its document';
      END IF;
      UPDATE documents SET current_revision_id = NEW.id,
        released_revision_id = CASE
          WHEN NEW.action = 'publish' AND NEW.status = 'published' THEN NEW.id
          ELSE released_revision_id END
      WHERE id = NEW.document_id;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER revisions_bind_document
    AFTER INSERT ON revisions
    FOR EACH ROW EXECUTE FUNCTION barkpark_bind_document_revision();
    """

    execute """
    CREATE FUNCTION barkpark_revision_immutable() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'UPDATE' AND pg_trigger_depth() > 1 AND
         OLD.document_id IS NOT NULL AND NEW.document_id IS NULL AND
         to_jsonb(NEW) - 'document_id' = to_jsonb(OLD) - 'document_id' AND
         NOT EXISTS (SELECT 1 FROM documents WHERE id = OLD.document_id) THEN
        RETURN NEW;
      END IF;
      IF TG_OP = 'DELETE' AND pg_trigger_depth() > 1 THEN
        RETURN OLD;
      END IF;
      RAISE EXCEPTION 'revision history is append-only';
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER revisions_immutable
    BEFORE UPDATE OR DELETE ON revisions
    FOR EACH ROW EXECUTE FUNCTION barkpark_revision_immutable();
    """
  end

  def down do
    execute """
    DO $$
    DECLARE table_name text;
    DECLARE has_rows boolean;
    BEGIN
      FOREACH table_name IN ARRAY ARRAY['cycle_correction_roots','cycle_correction_targets',
        'cycle_correction_admissions','cycle_correction_quarantines','cycle_correction_promotion_events'] LOOP
        IF to_regclass(table_name) IS NOT NULL THEN
          EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I)', table_name) INTO has_rows;
          IF has_rows THEN
            RAISE EXCEPTION 'cannot roll back quarantine-promotion-v1 after immutable correction history exists';
          END IF;
        END IF;
      END LOOP;
    END;
    $$;
    """

    execute previous_teardown_function()
    execute "DROP TRIGGER IF EXISTS revisions_immutable ON revisions;"
    execute "DROP FUNCTION IF EXISTS barkpark_revision_immutable();"
    execute "DROP TRIGGER IF EXISTS revisions_bind_document ON revisions;"
    execute "DROP FUNCTION IF EXISTS barkpark_bind_document_revision();"
    drop table(:cycle_correction_promotion_events)
    drop table(:cycle_correction_quarantines)
    drop_if_exists table(:cycle_correction_admissions)
    drop table(:cycle_correction_targets)
    drop table(:cycle_correction_roots)

    alter table(:documents) do
      remove_if_exists :released_revision_id
      remove_if_exists :current_revision_id
    end

    alter table(:revisions) do
      remove_if_exists :document_id
    end

    execute "DROP FUNCTION IF EXISTS barkpark_cycle_correction_immutable();"
    execute "DROP FUNCTION IF EXISTS barkpark_prepare_workspace_cycle_teardown(uuid);"
    execute "DROP FUNCTION IF EXISTS barkpark_validate_cycle_correction();"

    execute "DROP FUNCTION IF EXISTS barkpark_paper_has_cycle_authority(jsonb, uuid, uuid, text, text, uuid, text, text, text, text, jsonb);"

    execute "DROP FUNCTION IF EXISTS barkpark_b1_document(uuid);"
    execute "DROP FUNCTION IF EXISTS barkpark_jsonb_canonical_digest(jsonb);"
    execute "DROP FUNCTION IF EXISTS barkpark_canonical_jsonb(jsonb);"
  end

  defp field_exists?(:cycle_correction_targets, field),
    do: field in [:correction_receipt_digest, :semantic_digest]

  defp field_exists?(:cycle_correction_quarantines, field),
    do: field in [:correction_receipt_digest, :event_digest]

  defp field_exists?(:cycle_correction_admissions, field),
    do:
      field in [
        :reconciliation_digest,
        :fleet_digest,
        :b1_scope_receipt_digest,
        :b1_ledger_digest,
        :b1_bytes_digest,
        :paper_content_digest,
        :gate_receipt_digest
      ]

  defp field_exists?(:cycle_correction_promotion_events, field), do: field == :event_digest

  defp validation_function do
    """
    CREATE OR REPLACE FUNCTION barkpark_validate_cycle_correction() RETURNS trigger AS $$
    DECLARE
      root_row cycle_waves%ROWTYPE;
      target_row cycle_waves%ROWTYPE;
      previous_row cycle_waves%ROWTYPE;
      target_contract cycle_correction_targets%ROWTYPE;
      admission_row cycle_correction_admissions%ROWTYPE;
      current_head uuid;
      restored_target uuid;
      expected_plan_digest text;
      payload_digest text;
    BEGIN
      IF TG_TABLE_NAME = 'cycle_correction_roots' THEN
        SELECT * INTO root_row FROM cycle_waves WHERE id = NEW.root_wave_id;
        IF NOT FOUND OR root_row.correction_of_wave_id IS NOT NULL OR
           root_row.workspace_id <> NEW.workspace_id OR
           root_row.project_id IS DISTINCT FROM NEW.project_id OR root_row.epic_id <> NEW.epic_id THEN
          RAISE EXCEPTION 'correction root scope does not match its cycle wave';
        END IF;
        RETURN NEW;
      END IF;

      SELECT wave.* INTO root_row
      FROM cycle_correction_roots root
      JOIN cycle_waves wave ON wave.id = root.root_wave_id
      WHERE root.root_wave_id = NEW.root_wave_id
      FOR UPDATE OF root;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'correction ancestry root is missing';
      END IF;

      IF root_row.workspace_id <> NEW.workspace_id OR
         root_row.project_id IS DISTINCT FROM NEW.project_id OR root_row.epic_id <> NEW.epic_id THEN
        RAISE EXCEPTION 'correction row scope does not match ancestry root';
      END IF;

      IF TG_TABLE_NAME = 'cycle_correction_targets' THEN
        SELECT * INTO target_row FROM cycle_waves WHERE id = NEW.wave_id;
        SELECT * INTO previous_row FROM cycle_waves WHERE id = NEW.previous_wave_id;

        IF NOT FOUND OR target_row.id IS NULL OR previous_row.id IS NULL OR
           target_row.id = root_row.id OR target_row.workspace_id <> root_row.workspace_id OR
           target_row.project_id IS DISTINCT FROM root_row.project_id OR
           target_row.epic_id <> root_row.epic_id OR previous_row.workspace_id <> root_row.workspace_id OR
           previous_row.project_id IS DISTINCT FROM root_row.project_id OR previous_row.epic_id <> root_row.epic_id OR
           target_row.correction_of_wave_id IS DISTINCT FROM NEW.previous_wave_id THEN
          RAISE EXCEPTION 'correction target or predecessor has foreign scope';
        END IF;

        IF NEW.previous_wave_id <> NEW.root_wave_id AND NOT EXISTS (
          SELECT 1 FROM cycle_correction_targets prior
          WHERE prior.wave_id = NEW.previous_wave_id AND prior.root_wave_id = NEW.root_wave_id
        ) THEN
          RAISE EXCEPTION 'correction predecessor is not in the ancestry chain';
        END IF;

        IF jsonb_typeof(NEW.correction_receipt) <> 'object' OR
           (SELECT count(*) FROM jsonb_object_keys(NEW.correction_receipt)) <> 5 OR
           NOT NEW.correction_receipt ?& ARRAY['version','successor_wave_revision','parent_wave_revision','correction_of_digest','targets'] OR
           NEW.correction_receipt->>'version' <> 'correction_receipt-v1' OR
           NEW.correction_receipt->>'successor_wave_revision' <> NEW.wave_id::text OR
           NEW.correction_receipt->>'parent_wave_revision' <> NEW.previous_wave_id::text OR
           NEW.correction_receipt->>'correction_of_digest' <> target_row.correction_of_digest OR
           NEW.correction_receipt->'targets' IS DISTINCT FROM target_row.correction_of->'targets' OR
           NEW.correction_receipt_digest <> barkpark_jsonb_canonical_digest(NEW.correction_receipt) OR
           NEW.semantic_digest <> barkpark_jsonb_canonical_digest(NEW.correction_receipt->'targets') THEN
          RAISE EXCEPTION 'correction receipt has invalid shape or scope pins';
        END IF;
        RETURN NEW;
      END IF;

      IF TG_TABLE_NAME = 'cycle_correction_admissions' THEN
        SELECT * INTO target_contract FROM cycle_correction_targets
        WHERE wave_id = NEW.target_wave_id AND root_wave_id = NEW.root_wave_id;
        IF NOT FOUND OR NEW.workspace_id <> root_row.workspace_id OR
           NEW.project_id IS DISTINCT FROM root_row.project_id OR NEW.epic_id <> root_row.epic_id THEN
          RAISE EXCEPTION 'promotion admission has foreign or unregistered correction authority';
        END IF;
        SELECT * INTO target_row FROM cycle_waves WHERE id = NEW.target_wave_id;
        IF jsonb_typeof(NEW.b1_scope_receipt) <> 'object' OR
           (SELECT count(*) FROM jsonb_object_keys(NEW.b1_scope_receipt)) <> 11 OR
           NOT NEW.b1_scope_receipt ?& ARRAY['version','workspace_id','project_id','epic_id','wave_id','wave_revision','inventory_digest','plan_digest','reconciliation_digest','fleet_digest','receipt_digest'] OR
           NEW.b1_scope_receipt->>'version' <> 'b1-scope-fence-v1' OR
           NEW.b1_scope_receipt->>'workspace_id' <> root_row.workspace_id::text OR
           NEW.b1_scope_receipt->>'project_id' <> root_row.project_id::text OR
           NEW.b1_scope_receipt->>'epic_id' <> root_row.epic_id OR
           NEW.b1_scope_receipt->>'wave_id' <> target_row.wave_id OR
           NEW.b1_scope_receipt->>'wave_revision' <> target_row.id::text OR
           NEW.b1_scope_receipt->>'inventory_digest' <> target_row.inventory_digest OR
           NEW.b1_scope_receipt->>'plan_digest' <> COALESCE((SELECT plan_digest FROM cycle_build_plans WHERE wave_id = target_row.id), target_row.plan_digest) OR
           NEW.b1_scope_receipt->>'reconciliation_digest' <> NEW.reconciliation_digest OR
           NEW.b1_scope_receipt->>'fleet_digest' <> NEW.fleet_digest OR
           NEW.b1_scope_receipt->>'receipt_digest' <> barkpark_jsonb_canonical_digest(NEW.b1_scope_receipt - 'receipt_digest') OR
           NEW.b1_scope_receipt_digest <> NEW.b1_scope_receipt->>'receipt_digest' THEN
          RAISE EXCEPTION 'promotion admission B1 scope authority is invalid';
        END IF;
        IF NOT EXISTS (
          SELECT 1 FROM epic_benchmark_experiments experiment
          WHERE experiment.id = NEW.b1_experiment_id AND
            experiment.workspace_id = root_row.workspace_id AND
            experiment.epic_id = root_row.epic_id AND experiment.wave_id = target_row.wave_id AND
            experiment.artifact_format = 'barkpark-epic-benchmark-v1' AND
            experiment.manifest->'cycle_scope_fence' = NEW.b1_scope_receipt AND
            experiment.manifest->'fleet_contract' = jsonb_build_object('version', 1, 'paper_fleet_digest', NEW.fleet_digest)
        ) OR NOT EXISTS (
          SELECT 1 FROM epic_benchmark_attempts attempt WHERE attempt.experiment_id = NEW.b1_experiment_id
        ) OR EXISTS (
          SELECT 1 FROM epic_benchmark_attempts attempt
          WHERE attempt.experiment_id = NEW.b1_experiment_id AND
            (attempt.provenance->>'wave_revision' <> target_row.id::text OR
             attempt.provenance->>'scope_receipt_digest' <> NEW.b1_scope_receipt_digest)
        ) THEN
          RAISE EXCEPTION 'promotion admission B1 experiment authority is stale or foreign';
        END IF;
        IF NEW.b1_ledger_digest <> barkpark_b1_document(NEW.b1_experiment_id)->>'ledger_digest' OR
           NEW.b1_bytes_digest <> barkpark_jsonb_canonical_digest(barkpark_b1_document(NEW.b1_experiment_id)) OR
           EXISTS (
             SELECT 1 FROM epic_benchmark_attempts attempt
             WHERE attempt.experiment_id = NEW.b1_experiment_id AND
               attempt.attempt_digest <> barkpark_jsonb_canonical_digest(jsonb_build_object(
                 'attempt_id', attempt.attempt_id, 'replaces_attempt_id', attempt.replaces_attempt_id,
                 'ordinal', attempt.ordinal, 'treatment', attempt.treatment, 'status', attempt.status,
                 'costs', attempt.costs, 'provenance', attempt.provenance, 'payload', attempt.payload
               ))
           ) THEN
          RAISE EXCEPTION 'promotion admission B1 canonical ledger or bytes digest is invalid';
        END IF;
        IF EXISTS (
          WITH expected AS (
            SELECT row_number() OVER (
                     ORDER BY CASE fleet_phase.key
                       WHEN 'survey' THEN 1 WHEN 'verify' THEN 2 WHEN 'experiment' THEN 3
                       WHEN 'build' THEN 4 WHEN 'review' THEN 5 ELSE 99 END,
                       assignment.value::jsonb->>'id'
                   )::integer AS ordinal,
                   fleet_phase.key AS phase, assignment.value AS fleet_assignment
            FROM revisions paper
            CROSS JOIN LATERAL jsonb_array_elements(paper.content->'blocks') block
            CROSS JOIN LATERAL jsonb_each(block->'fleet') fleet_phase
            CROSS JOIN LATERAL jsonb_array_elements(COALESCE(fleet_phase.value->'assignments', '[]'::jsonb)) assignment(value)
            WHERE paper.id = NEW.paper_revision_id AND block ? 'cycle_ledger' AND block ? 'fleet'
          ), actual AS (
            SELECT ordinal, attempt_id, status, treatment,
                   payload->'fleet_assignment' AS fleet_assignment
            FROM epic_benchmark_attempts
            WHERE experiment_id = NEW.b1_experiment_id
          )
          SELECT 1 FROM expected
          FULL JOIN actual USING (ordinal)
          WHERE actual.ordinal IS NULL OR expected.ordinal IS NULL OR
                actual.attempt_id IS DISTINCT FROM
                  ('cycle-' || expected.phase || '-' || (expected.fleet_assignment::jsonb->>'id')) OR
                actual.status IS DISTINCT FROM 'completed' OR
                actual.treatment IS DISTINCT FROM 'cyclefleet-reconciliation' OR
                (actual.fleet_assignment::jsonb->>'phase') IS DISTINCT FROM expected.phase OR
                (actual.fleet_assignment::jsonb->>'assignment_id') IS DISTINCT FROM (expected.fleet_assignment::jsonb->>'id') OR
                (actual.fleet_assignment::jsonb->>'agent_type') IS DISTINCT FROM (expected.fleet_assignment::jsonb->>'agent_type') OR
                (actual.fleet_assignment::jsonb->>'evidence') IS DISTINCT FROM (expected.fleet_assignment::jsonb->>'evidence') OR
                (actual.fleet_assignment::jsonb->>'model_reasoning_effort') IS DISTINCT FROM
                  CASE WHEN expected.phase IN ('build', 'review') THEN 'high' ELSE 'medium' END
        ) THEN
          RAISE EXCEPTION 'promotion admission B1 attempts do not exactly cover the authoritative Paper fleet';
        END IF;
        IF EXISTS (
          WITH ancestry AS (
            SELECT (entry->>'wave_revision')::uuid AS wave_revision
            FROM jsonb_array_elements(target_row.correction_of->'ancestry') entry
          ), expected AS (
            SELECT fleet_phase.key AS phase,
                   fleet_phase.value->>'effort' AS expected_effort,
                   assignment.value AS fleet_assignment
            FROM revisions paper
            CROSS JOIN LATERAL jsonb_array_elements(paper.content->'blocks') block
            CROSS JOIN LATERAL jsonb_each(block->'fleet') fleet_phase
            CROSS JOIN LATERAL jsonb_array_elements(
              COALESCE(fleet_phase.value->'assignments', '[]'::jsonb)
            ) assignment(value)
            WHERE paper.id = NEW.paper_revision_id AND block ? 'cycle_ledger' AND block ? 'fleet'
          ), actual AS (
            SELECT assignment.phase, assignment.assignment_id, assignment.agent_type,
                   assignment.effort, result.status, result.evidence
            FROM epic_assignments assignment
            JOIN ancestry ON ancestry.wave_revision = assignment.cycle_wave_id
            LEFT JOIN epic_assignment_results result ON result.assignment_id = assignment.id
            WHERE NOT EXISTS (
              SELECT 1 FROM epic_assignments replacement
              JOIN ancestry replacement_ancestry
                ON replacement_ancestry.wave_revision = replacement.cycle_wave_id
              WHERE replacement.replaces_assignment_id = assignment.id
            )
          )
          SELECT 1 FROM expected
          FULL JOIN actual ON actual.phase = expected.phase AND
            actual.assignment_id = expected.fleet_assignment::jsonb->>'id'
          WHERE actual.assignment_id IS NULL OR expected.fleet_assignment IS NULL OR
            actual.status IS DISTINCT FROM 'completed' OR
            actual.agent_type IS DISTINCT FROM
              (expected.fleet_assignment::jsonb->>'agent_type') OR
            actual.evidence IS DISTINCT FROM (expected.fleet_assignment::jsonb->>'evidence') OR
            actual.effort IS DISTINCT FROM expected.expected_effort
        ) OR EXISTS (
          SELECT 1
          FROM revisions paper
          CROSS JOIN LATERAL jsonb_array_elements(paper.content->'blocks') block
          CROSS JOIN LATERAL jsonb_each(block->'fleet') fleet_phase
          WHERE paper.id = NEW.paper_revision_id AND block ? 'cycle_ledger' AND block ? 'fleet' AND
            (
              (fleet_phase.value->>'planned')::integer IS DISTINCT FROM
                jsonb_array_length(fleet_phase.value->'assignments') OR
              (fleet_phase.value->>'started')::integer IS DISTINCT FROM
                jsonb_array_length(fleet_phase.value->'assignments') OR
              (fleet_phase.value->>'completed')::integer IS DISTINCT FROM
                jsonb_array_length(fleet_phase.value->'assignments') OR
              (fleet_phase.value->>'missing')::integer <> 0 OR
              (fleet_phase.value->>'failed')::integer <> 0 OR
              (fleet_phase.value->>'invalid_assignments')::integer <> 0 OR
              (fleet_phase.value->>'unresolved_failures')::integer <> 0 OR
              (fleet_phase.value->>'unresolved_missing')::integer <> 0 OR
              (fleet_phase.value->'terminal_counts'->>'completed')::integer IS DISTINCT FROM
                jsonb_array_length(fleet_phase.value->'assignments') OR
              ((fleet_phase.value->'terminal_counts') - 'completed'::text) IS DISTINCT FROM
                '{"failed":0,"cancelled":0,"missing":0,"invalid":0}'::jsonb
            )
        ) THEN
          RAISE EXCEPTION 'promotion admission Paper and B1 fleet is not backed by complete live Cycle rows';
        END IF;
        IF EXISTS (
          WITH ancestry AS (
            SELECT (entry->>'wave_revision')::uuid AS wave_revision
            FROM jsonb_array_elements(target_row.correction_of->'ancestry') entry
          ), live_build AS (
            SELECT assignment.*, result.payload AS result_payload, result.status AS result_status,
                   task.id AS task_id, task.doc_id AS task_doc_id, task.rev AS task_rev,
                   task.workspace_id AS task_workspace_id, task.project_id AS task_project_id,
                   task.dataset_id AS task_dataset_id, task.content AS task_content
            FROM epic_assignments assignment
            JOIN ancestry ON ancestry.wave_revision = assignment.cycle_wave_id
            LEFT JOIN epic_assignment_results result ON result.assignment_id = assignment.id
            LEFT JOIN epic_assignment_tasks binding ON binding.assignment_id = assignment.id
            LEFT JOIN documents task ON task.id = binding.task_id AND task.type = 'task'
            WHERE assignment.phase = 'build' AND NOT EXISTS (
              SELECT 1 FROM epic_assignments replacement
              JOIN ancestry replacement_ancestry
                ON replacement_ancestry.wave_revision = replacement.cycle_wave_id
              WHERE replacement.replaces_assignment_id = assignment.id
            )
          )
          SELECT 1 FROM live_build build
          WHERE NOT EXISTS (
            SELECT 1 FROM jsonb_array_elements(target_row.correction_of->'targets') target
            WHERE target->>'assignment_revision' = build.id::text AND
              target->>'result_revision' IS NOT NULL
          ) AND (
            build.result_status IS DISTINCT FROM 'completed' OR build.task_id IS NULL OR
            build.task_workspace_id IS DISTINCT FROM build.workspace_id OR
            build.task_project_id IS DISTINCT FROM root_row.project_id OR
            build.task_rev IS NULL OR btrim(build.task_rev) = '' OR
            build.task_content->>'lifecycle_status' IS DISTINCT FROM 'done' OR
            jsonb_typeof(build.task_content->'acceptance_criteria') IS DISTINCT FROM 'array' OR
            jsonb_array_length(build.task_content->'acceptance_criteria') = 0 OR
            EXISTS (
              SELECT 1 FROM jsonb_array_elements(build.task_content->'acceptance_criteria') criterion
              WHERE criterion->'met' IS DISTINCT FROM 'true'::jsonb OR
                btrim(COALESCE(criterion->>'criterion','')) = '' OR
                btrim(COALESCE(criterion->>'evidence','')) = ''
            ) OR jsonb_typeof(build.task_content->'claim') IS DISTINCT FROM 'object' OR
            btrim(COALESCE(build.task_content->'claim'->>'worker','')) = '' OR
            COALESCE((build.task_content->'claim'->>'epoch')::integer, 0) <= 0 OR
            build.result_payload->>'semantic_receipt_version' IS DISTINCT FROM 'semantic_receipt-v1' OR
            jsonb_typeof(build.result_payload->'semantic_receipts') IS DISTINCT FROM 'array' OR
            jsonb_array_length(build.result_payload->'semantic_receipts') IS DISTINCT FROM
              jsonb_array_length(build.snapshot->'unit_ids') OR
            build.result_payload->>'terminal_payload_digest' IS DISTINCT FROM
              barkpark_jsonb_canonical_digest(
                build.result_payload - 'semantic_receipts'::text -
                  'semantic_receipt_version'::text - 'semantic_receipt_index_hash'::text -
                  'terminal_payload_digest'::text
              ) OR EXISTS (
              SELECT 1
              FROM jsonb_array_elements(build.result_payload->'semantic_receipts') WITH ORDINALITY submitted(receipt, ordinal)
              WHERE submitted.receipt->>'unit_id' IS DISTINCT FROM
                  (SELECT unit #>> '{}' FROM jsonb_array_elements(build.snapshot->'unit_ids') unit
                   ORDER BY unit #>> '{}' OFFSET submitted.ordinal - 1::bigint LIMIT 1) OR
                submitted.receipt->>'assignment_id' IS DISTINCT FROM build.id::text OR
                submitted.receipt->>'task_id' IS DISTINCT FROM build.task_id::text OR
                submitted.receipt->>'task_doc_id' IS DISTINCT FROM build.task_doc_id OR
                submitted.receipt->>'task_rev' IS DISTINCT FROM build.task_rev OR
                submitted.receipt->>'lifecycle_status' IS DISTINCT FROM 'done' OR
                submitted.receipt->'criteria' IS DISTINCT FROM (
                  SELECT jsonb_agg(jsonb_build_object(
                    'criterion', criterion->>'criterion', 'met', true,
                    'evidence', criterion->>'evidence'
                  ) ORDER BY ordinal)
                  FROM jsonb_array_elements(build.task_content->'acceptance_criteria')
                    WITH ORDINALITY criteria(criterion, ordinal)
                ) OR submitted.receipt->'claim' IS DISTINCT FROM jsonb_build_object(
                  'worker', build.task_content->'claim'->>'worker',
                  'epoch', (build.task_content->'claim'->>'epoch')::integer
                ) OR
                submitted.receipt->'ownership' IS DISTINCT FROM jsonb_build_object(
                  'assignment_id', build.id, 'assignment_key', build.assignment_id,
                  'cycle_wave_id', build.cycle_wave_id, 'snapshot_digest', build.snapshot_digest,
                  'workspace_id', build.workspace_id, 'project_id', root_row.project_id,
                  'dataset_id', build.task_dataset_id
                ) OR submitted.receipt->>'disposition' IS DISTINCT FROM CASE
                  WHEN build.result_payload->'completed_unit_ids' ? (submitted.receipt->>'unit_id') THEN 'shipped'
                  WHEN build.result_payload->'stalled_unit_ids' ? (submitted.receipt->>'unit_id') THEN 'stalled'
                  WHEN build.result_payload->'excluded_unit_ids' ? (submitted.receipt->>'unit_id') THEN 'excluded'
                END OR submitted.receipt->>'receipt_hash' IS DISTINCT FROM
                  barkpark_jsonb_canonical_digest(submitted.receipt - 'receipt_hash'::text)
            ) OR build.result_payload->>'semantic_receipt_index_hash' IS DISTINCT FROM (
              SELECT barkpark_jsonb_canonical_digest(jsonb_build_object(
                'version', 'semantic_receipt-index-v1',
                'terminal_payload_digest', build.result_payload->>'terminal_payload_digest',
                'receipt_hashes', jsonb_agg(receipt->'receipt_hash' ORDER BY ordinal)
              ))
              FROM jsonb_array_elements(build.result_payload->'semantic_receipts')
                WITH ORDINALITY receipts(receipt, ordinal)
            )
          )
        ) THEN
          RAISE EXCEPTION 'promotion admission live Cycle semantic receipts are invalid or stale';
        END IF;
        IF EXISTS (
          WITH RECURSIVE lineage AS (
            SELECT target_row.id, target_row.correction_of_wave_id, target_row.correction_of,
                   0 AS depth
            UNION ALL
            SELECT parent.id, parent.correction_of_wave_id, parent.correction_of,
                   child.depth + 1
            FROM cycle_waves parent JOIN lineage child ON parent.id = child.correction_of_wave_id
          ), ancestry AS (
            SELECT id AS wave_revision FROM lineage
          ), live_build AS (
            SELECT assignment.*, result.payload AS result_payload
            FROM epic_assignments assignment
            JOIN ancestry ON ancestry.wave_revision = assignment.cycle_wave_id
            JOIN epic_assignment_results result ON result.assignment_id = assignment.id
            WHERE assignment.phase = 'build' AND NOT EXISTS (
              SELECT 1 FROM epic_assignments replacement
              JOIN ancestry replacement_ancestry
                ON replacement_ancestry.wave_revision = replacement.cycle_wave_id
              WHERE replacement.replaces_assignment_id = assignment.id
            )
          ), owned AS (
            SELECT unit #>> '{}' AS unit_id FROM live_build,
              LATERAL jsonb_array_elements(live_build.snapshot->'unit_ids') unit
          ), outcomes AS (
            SELECT 'shipped'::text AS disposition, unit #>> '{}' AS unit_id FROM live_build,
              LATERAL jsonb_array_elements(live_build.result_payload->'completed_unit_ids') unit
            UNION ALL
            SELECT 'stalled', unit #>> '{}' FROM live_build,
              LATERAL jsonb_array_elements(live_build.result_payload->'stalled_unit_ids') unit
            UNION ALL
            SELECT 'excluded', unit #>> '{}' FROM live_build,
              LATERAL jsonb_array_elements(live_build.result_payload->'excluded_unit_ids') unit
          ), inventory AS (
            SELECT unit->>'unit_id' AS unit_id
            FROM jsonb_array_elements(to_jsonb(target_row.inventory)) unit
          ), base_counts AS (
            SELECT jsonb_build_object(
              'shipped', count(*) FILTER (WHERE disposition='shipped'),
              'stalled', count(*) FILTER (WHERE disposition='stalled'),
              'excluded', count(*) FILTER (WHERE disposition='excluded')
            ) AS counts FROM outcomes
          ), base_state AS (
            SELECT COALESCE(jsonb_object_agg(unit_id, to_jsonb(disposition)), '{}'::jsonb)
                   AS dispositions
            FROM outcomes
          ), corrections AS (
            SELECT row_number() OVER (ORDER BY depth DESC)::integer AS step, correction_of
            FROM lineage WHERE correction_of IS NOT NULL
          ), correction_state(step, dispositions, invalid) AS (
            SELECT 0, base_state.dispositions, false FROM base_state
            UNION ALL
            SELECT correction.step, applied.dispositions,
              state.invalid OR
              changes.change_count <> changes.distinct_change_count OR
              changes.wrong_before OR
              correction.correction_of->'before_counts' IS DISTINCT FROM prior_counts.counts OR
              correction.correction_of->'delta' IS DISTINCT FROM changes.delta OR
              correction.correction_of->'after_counts' IS DISTINCT FROM applied_counts.counts
            FROM correction_state state
            JOIN corrections correction ON correction.step = state.step + 1
            CROSS JOIN LATERAL (
              SELECT
                count(*)::integer AS change_count,
                count(DISTINCT change->>'unit_id')::integer AS distinct_change_count,
                COALESCE(bool_or(
                  NOT state.dispositions ? (change->>'unit_id') OR
                  state.dispositions->>(change->>'unit_id') IS DISTINCT FROM change->>'before'
                ), false) AS wrong_before,
                COALESCE(
                  jsonb_object_agg(change->>'unit_id', to_jsonb(change->>'after')),
                  '{}'::jsonb
                ) AS patch,
                jsonb_build_object(
                  'shipped', COALESCE(sum(
                    (change->>'after' = 'shipped')::integer -
                    (change->>'before' = 'shipped')::integer
                  ), 0),
                  'stalled', COALESCE(sum(
                    (change->>'after' = 'stalled')::integer -
                    (change->>'before' = 'stalled')::integer
                  ), 0),
                  'excluded', COALESCE(sum(
                    (change->>'after' = 'excluded')::integer -
                    (change->>'before' = 'excluded')::integer
                  ), 0)
                ) AS delta
              FROM jsonb_array_elements(correction.correction_of->'changes') change
            ) changes
            CROSS JOIN LATERAL (
              SELECT jsonb_build_object(
                'shipped', count(*) FILTER (WHERE disposition='shipped'),
                'stalled', count(*) FILTER (WHERE disposition='stalled'),
                'excluded', count(*) FILTER (WHERE disposition='excluded')
              ) AS counts
              FROM jsonb_each_text(state.dispositions) current(unit_id, disposition)
            ) prior_counts
            CROSS JOIN LATERAL (
              SELECT state.dispositions || changes.patch AS dispositions
            ) applied
            CROSS JOIN LATERAL (
              SELECT jsonb_build_object(
                'shipped', count(*) FILTER (WHERE disposition='shipped'),
                'stalled', count(*) FILTER (WHERE disposition='stalled'),
                'excluded', count(*) FILTER (WHERE disposition='excluded')
              ) AS counts
              FROM jsonb_each_text(applied.dispositions) current(unit_id, disposition)
            ) applied_counts
          ), invalid AS (
            SELECT 1 WHERE
              (SELECT count(*) FROM owned) <> (SELECT count(*) FROM inventory) OR
              (SELECT count(DISTINCT unit_id) FROM owned) <> (SELECT count(*) FROM inventory) OR
              EXISTS ((SELECT unit_id FROM owned EXCEPT SELECT unit_id FROM inventory)
                UNION ALL (SELECT unit_id FROM inventory EXCEPT SELECT unit_id FROM owned)) OR
              (SELECT count(*) FROM outcomes) <> (SELECT count(*) FROM inventory) OR
              (SELECT count(DISTINCT unit_id) FROM outcomes) <> (SELECT count(*) FROM inventory) OR
              EXISTS ((SELECT unit_id FROM outcomes EXCEPT SELECT unit_id FROM inventory)
                UNION ALL (SELECT unit_id FROM inventory EXCEPT SELECT unit_id FROM outcomes)) OR
              EXISTS (SELECT 1 FROM correction_state WHERE invalid)
          ) SELECT 1 FROM invalid
        ) THEN
          RAISE EXCEPTION 'promotion admission live Cycle ownership or semantic outcome partition is invalid';
        END IF;
        IF NOT EXISTS (
          SELECT 1
          FROM revisions paper
          CROSS JOIN LATERAL jsonb_array_elements(paper.content->'blocks') block
          WHERE paper.id = NEW.paper_revision_id AND block ? 'cycle_ledger' AND block ? 'fleet' AND
            block->'cycle_ledger'->>'live_authority_digest' ~ '^[0-9a-f]{64}$' AND
            (block->'cycle_ledger'->>'inventory_count')::integer =
              jsonb_array_length(to_jsonb(target_row.inventory)) AND
            (block->'cycle_ledger'->>'assigned_count')::integer =
              jsonb_array_length(to_jsonb(target_row.inventory)) AND
            (block->'cycle_ledger'->>'assigned_occurrences')::integer =
              jsonb_array_length(to_jsonb(target_row.inventory)) AND
            block->'cycle_ledger'->'shipped_count' = target_row.correction_of->'after_counts'->'shipped' AND
            block->'cycle_ledger'->'stalled_count' = target_row.correction_of->'after_counts'->'stalled' AND
            block->'cycle_ledger'->'excluded_count' = target_row.correction_of->'after_counts'->'excluded'
        ) THEN
          RAISE EXCEPTION 'promotion admission reconciliation digest or semantic counts are not live Cycle authority';
        END IF;
        IF NOT EXISTS (
          SELECT 1 FROM revisions paper
          JOIN documents document ON document.id = NEW.paper_document_id AND
            paper.document_id = document.id AND document.current_revision_id = paper.id AND
            document.released_revision_id = paper.id
          JOIN datasets dataset ON dataset.id = document.dataset_id AND dataset.slug = 'production'
          WHERE paper.id = NEW.paper_revision_id AND paper.type = 'paper' AND
            paper.dataset = 'production' AND document.dataset = 'production' AND
            paper.status = 'published' AND document.status = 'published' AND
            paper.workspace_id = root_row.workspace_id AND paper.project_id = root_row.project_id AND
            paper.doc_id = NEW.paper_doc_id AND
            document.doc_id = paper.doc_id AND document.type = paper.type AND
            document.dataset_id = paper.dataset_id AND
            document.workspace_id = paper.workspace_id AND
            document.project_id IS NOT DISTINCT FROM paper.project_id AND
            document.content = paper.content AND document.title IS NOT DISTINCT FROM paper.title AND
            barkpark_jsonb_canonical_digest(paper.content) = NEW.paper_content_digest AND
            barkpark_paper_has_cycle_authority(
              paper.content, root_row.workspace_id, root_row.project_id, root_row.epic_id,
              target_row.wave_id, target_row.id, target_row.inventory_digest,
              COALESCE((SELECT plan_digest FROM cycle_build_plans WHERE wave_id = target_row.id), target_row.plan_digest),
              NEW.reconciliation_digest, NEW.fleet_digest, target_contract.correction_receipt
            )
        ) THEN
          RAISE EXCEPTION 'promotion admission Paper authority is stale or foreign';
        END IF;
        IF NEW.gate_receipt_digest <> barkpark_jsonb_canonical_digest(NEW.gate_receipt) OR
           NEW.gate_receipt->>'b1_scope_receipt_digest' <> NEW.b1_scope_receipt_digest OR
           NEW.gate_receipt->>'b1_experiment_id' <> NEW.b1_experiment_id::text OR
           NEW.gate_receipt->>'b1_ledger_digest' <> NEW.b1_ledger_digest OR
           NEW.gate_receipt->>'b1_bytes_digest' <> NEW.b1_bytes_digest OR
           NEW.gate_receipt->>'paper_document_id' <> NEW.paper_document_id::text OR
           NEW.gate_receipt->>'paper_revision_id' <> NEW.paper_revision_id::text OR
           NEW.gate_receipt->>'paper_doc_id' <> NEW.paper_doc_id OR
           NEW.gate_receipt->>'paper_content_digest' <> NEW.paper_content_digest THEN
          RAISE EXCEPTION 'promotion admission gate does not join its B1 and Paper authorities';
        END IF;
        RETURN NEW;
      END IF;

      IF jsonb_typeof(NEW.actor) <> 'object' OR
         (SELECT count(*) FROM jsonb_object_keys(NEW.actor)) <> 2 OR
         NOT NEW.actor ?& ARRAY['type','id'] OR
         jsonb_typeof(NEW.actor->'type') <> 'string' OR btrim(NEW.actor->>'type') = '' OR
         jsonb_typeof(NEW.actor->'id') <> 'string' OR btrim(NEW.actor->>'id') = '' OR
         btrim(NEW.idempotency_key) = '' OR btrim(NEW.evidence) = '' OR
         NEW.evidence_revision !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'correction event actor/evidence shape is invalid';
      END IF;

      payload_digest := barkpark_jsonb_canonical_digest(NEW.event_payload);
      IF NEW.event_digest <> payload_digest THEN
        RAISE EXCEPTION 'correction event digest does not match canonical jsonb payload';
      END IF;

      IF TG_TABLE_NAME = 'cycle_correction_quarantines' THEN
        SELECT * INTO target_contract FROM cycle_correction_targets
        WHERE wave_id = NEW.correction_wave_id AND root_wave_id = NEW.root_wave_id;
        IF NOT FOUND OR target_contract.correction_receipt_digest <> NEW.correction_receipt_digest OR
           target_contract.correction_receipt <> NEW.correction_receipt OR btrim(NEW.reason) = '' OR
           jsonb_typeof(NEW.event_payload) <> 'object' OR
           (SELECT count(*) FROM jsonb_object_keys(NEW.event_payload)) <> 9 OR
           NOT NEW.event_payload ?& ARRAY['action','root_wave_revision','target_wave_revision','idempotency_key','reason','actor','evidence','evidence_revision','correction_receipt_digest'] OR
           NEW.event_payload->>'action' <> 'quarantine' OR
           NEW.event_payload->>'root_wave_revision' <> NEW.root_wave_id::text OR
           NEW.event_payload->>'target_wave_revision' <> NEW.correction_wave_id::text OR
           NEW.event_payload->>'idempotency_key' <> NEW.idempotency_key OR
           NEW.event_payload->>'reason' <> NEW.reason OR
           NEW.event_payload->'actor' <> NEW.actor OR
           NEW.event_payload->>'evidence' <> NEW.evidence OR
           NEW.event_payload->>'evidence_revision' <> NEW.evidence_revision OR
           NEW.event_payload->>'correction_receipt_digest' <> NEW.correction_receipt_digest THEN
          RAISE EXCEPTION 'quarantine must pin an exact registered correction';
        END IF;
        IF EXISTS (
          SELECT 1 FROM cycle_correction_promotion_events event
          LEFT JOIN cycle_correction_promotion_events child ON child.previous_event_id = event.id
          WHERE event.root_wave_id = NEW.root_wave_id AND child.id IS NULL AND
            event.target_wave_id = NEW.correction_wave_id
        ) THEN
          RAISE EXCEPTION 'current promoted correction requires rollback before quarantine';
        END IF;
        RETURN NEW;
      END IF;

      IF jsonb_typeof(NEW.event_payload) <> 'object' OR
         (SELECT count(*) FROM jsonb_object_keys(NEW.event_payload)) <> 11 OR
         NOT NEW.event_payload ?& ARRAY['action','admission_id','root_wave_revision','target_wave_revision','previous_event_id','restore_event_id','idempotency_key','actor','evidence','evidence_revision','gate_receipt'] OR
         NEW.event_payload->>'action' <> NEW.action OR
         (NEW.event_payload->>'admission_id') IS DISTINCT FROM NEW.admission_id::text OR
         NEW.event_payload->>'root_wave_revision' <> NEW.root_wave_id::text OR
         NEW.event_payload->>'target_wave_revision' <> NEW.target_wave_id::text OR
         (NEW.event_payload->>'previous_event_id') IS DISTINCT FROM NEW.previous_event_id::text OR
         (NEW.event_payload->>'restore_event_id') IS DISTINCT FROM NEW.restore_event_id::text OR
         NEW.event_payload->>'idempotency_key' <> NEW.idempotency_key OR
         NEW.event_payload->'actor' <> NEW.actor OR
         NEW.event_payload->>'evidence' <> NEW.evidence OR
         NEW.event_payload->>'evidence_revision' <> NEW.evidence_revision OR
         NEW.event_payload->'gate_receipt' IS DISTINCT FROM COALESCE(to_jsonb(NEW.gate_receipt), 'null'::jsonb) THEN
        RAISE EXCEPTION 'promotion event payload contradicts stored transition';
      END IF;

      SELECT event.id INTO current_head
      FROM cycle_correction_promotion_events event
      LEFT JOIN cycle_correction_promotion_events child ON child.previous_event_id = event.id
      WHERE event.root_wave_id = NEW.root_wave_id AND child.id IS NULL;

      IF current_head IS NULL THEN
        IF NEW.previous_event_id IS NOT NULL OR NEW.action <> 'promote' THEN
          RAISE EXCEPTION 'promotion genesis requires a promote with no previous head';
        END IF;
      ELSIF NEW.previous_event_id IS DISTINCT FROM current_head THEN
        RAISE EXCEPTION 'promotion previous head is stale or missing';
      END IF;

      IF NEW.action = 'promote' THEN
        SELECT * INTO admission_row FROM cycle_correction_admissions
        WHERE id = NEW.admission_id AND root_wave_id = NEW.root_wave_id AND
          target_wave_id = NEW.target_wave_id AND idempotency_key = NEW.idempotency_key AND
          gate_receipt = NEW.gate_receipt;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'promotion requires an exact server-issued admission receipt';
        END IF;
        SELECT * INTO target_contract FROM cycle_correction_targets
        WHERE wave_id = NEW.target_wave_id AND root_wave_id = NEW.root_wave_id;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'promotion target is not a registered correction';
        END IF;
        IF EXISTS (SELECT 1 FROM cycle_correction_quarantines q WHERE q.correction_wave_id = NEW.target_wave_id) THEN
          RAISE EXCEPTION 'quarantined correction cannot be promoted';
        END IF;
        IF current_head IS NOT NULL AND EXISTS (
          SELECT 1 FROM cycle_correction_promotion_events
          WHERE id = current_head AND target_wave_id = NEW.target_wave_id
        ) THEN
          RAISE EXCEPTION 'correction target is already current';
        END IF;
        SELECT COALESCE(plan.plan_digest, wave.plan_digest) INTO expected_plan_digest
        FROM cycle_waves wave LEFT JOIN cycle_build_plans plan ON plan.wave_id = wave.id
        WHERE wave.id = NEW.target_wave_id;
        IF jsonb_typeof(NEW.gate_receipt) <> 'object' OR
           (SELECT count(*) FROM jsonb_object_keys(NEW.gate_receipt)) <> 16 OR
           NOT NEW.gate_receipt ?& ARRAY['format','wave_revision','inventory_digest','plan_digest','reconciliation_digest','correction_receipt_digest','semantic_digest','b1_scope_receipt_digest','b1_experiment_id','b1_ledger_digest','b1_bytes_digest','paper_document_id','paper_revision_id','paper_doc_id','paper_content_digest','receipt_digest'] OR
           NEW.gate_receipt->>'format' <> 'cycle-promotion-gate-v1' OR
           NEW.gate_receipt->>'wave_revision' <> NEW.target_wave_id::text OR
           NEW.gate_receipt->>'inventory_digest' <> (SELECT inventory_digest FROM cycle_waves WHERE id = NEW.target_wave_id) OR
           NEW.gate_receipt->>'plan_digest' <> expected_plan_digest OR
           NEW.gate_receipt->>'correction_receipt_digest' <> target_contract.correction_receipt_digest OR
           NEW.gate_receipt->>'semantic_digest' <> target_contract.semantic_digest OR
           NEW.gate_receipt->>'reconciliation_digest' !~ '^[0-9a-f]{64}$' OR
           NEW.gate_receipt->>'b1_scope_receipt_digest' <> admission_row.b1_scope_receipt_digest OR
           NEW.gate_receipt->>'b1_experiment_id' <> admission_row.b1_experiment_id::text OR
           NEW.gate_receipt->>'b1_ledger_digest' <> admission_row.b1_ledger_digest OR
           NEW.gate_receipt->>'b1_bytes_digest' <> admission_row.b1_bytes_digest OR
           NEW.gate_receipt->>'paper_document_id' <> admission_row.paper_document_id::text OR
           NEW.gate_receipt->>'paper_revision_id' <> admission_row.paper_revision_id::text OR
           NEW.gate_receipt->>'paper_doc_id' <> admission_row.paper_doc_id OR
           NEW.gate_receipt->>'paper_content_digest' <> admission_row.paper_content_digest OR
           NEW.gate_receipt->>'receipt_digest' !~ '^[0-9a-f]{64}$' OR
           NEW.gate_receipt->>'receipt_digest' <>
             barkpark_jsonb_canonical_digest(NEW.gate_receipt - 'receipt_digest') THEN
          RAISE EXCEPTION 'promotion gate has invalid shape or authority pins';
        END IF;
        IF NEW.restore_event_id IS NOT NULL THEN
          RAISE EXCEPTION 'promote cannot restore an earlier event';
        END IF;
      ELSE
        IF NEW.admission_id IS NOT NULL THEN
          RAISE EXCEPTION 'rollback cannot carry a promotion admission';
        END IF;
        IF NEW.gate_receipt IS NOT NULL THEN
          RAISE EXCEPTION 'rollback cannot carry a promotion gate';
        END IF;
        IF NEW.restore_event_id = current_head THEN
          RAISE EXCEPTION 'rollback cannot restore its current head';
        ELSIF NEW.restore_event_id IS NULL THEN
          restored_target := NEW.root_wave_id;
        ELSE
          WITH RECURSIVE ancestry AS (
            SELECT event.id, event.previous_event_id, event.action, event.target_wave_id
            FROM cycle_correction_promotion_events event WHERE event.id = current_head
            UNION ALL
            SELECT parent.id, parent.previous_event_id, parent.action, parent.target_wave_id
            FROM cycle_correction_promotion_events parent
            JOIN ancestry child ON child.previous_event_id = parent.id
          )
          SELECT target_wave_id INTO restored_target FROM ancestry
          WHERE id = NEW.restore_event_id AND action = 'promote';
          IF restored_target IS NULL THEN
            RAISE EXCEPTION 'rollback restore target is not an earlier successful promote';
          END IF;
        END IF;
        IF NEW.target_wave_id <> restored_target THEN
          RAISE EXCEPTION 'rollback target does not match restored promotion ancestry';
        END IF;
        IF restored_target <> NEW.root_wave_id AND EXISTS (
          SELECT 1 FROM cycle_correction_quarantines q WHERE q.correction_wave_id = restored_target
        ) THEN
          RAISE EXCEPTION 'rollback cannot restore a quarantined correction';
        END IF;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """
  end

  defp canonical_json_function do
    """
    CREATE OR REPLACE FUNCTION barkpark_canonical_jsonb(value jsonb) RETURNS text AS $$
    DECLARE result text;
    BEGIN
      CASE jsonb_typeof(value)
        WHEN 'object' THEN
          SELECT '{' || COALESCE(string_agg(to_jsonb(key)::text || ':' || barkpark_canonical_jsonb(child), ',' ORDER BY key), '') || '}'
          INTO result FROM jsonb_each(value) entry(key, child);
        WHEN 'array' THEN
          SELECT '[' || COALESCE(string_agg(barkpark_canonical_jsonb(child), ',' ORDER BY ordinal), '') || ']'
          INTO result FROM jsonb_array_elements(value) WITH ORDINALITY entry(child, ordinal);
        ELSE
          result := value::text;
      END CASE;
      RETURN result;
    END;
    $$ LANGUAGE plpgsql IMMUTABLE STRICT;
    """
  end

  defp canonical_digest_function do
    """
    CREATE OR REPLACE FUNCTION barkpark_jsonb_canonical_digest(value jsonb) RETURNS text AS $$
      SELECT encode(digest(convert_to(barkpark_canonical_jsonb(value), 'UTF8'), 'sha256'), 'hex');
    $$ LANGUAGE sql IMMUTABLE STRICT;
    """
  end

  defp paper_authority_function do
    """
    CREATE OR REPLACE FUNCTION barkpark_paper_has_cycle_authority(
      value jsonb, workspace uuid, project uuid, epic text, wave text, wave_revision uuid,
      inventory_digest text, plan_digest text, reconciliation_digest text, fleet_digest text,
      correction_receipt jsonb
    ) RETURNS boolean AS $$
      SELECT jsonb_typeof(value->'blocks') = 'array' AND 1 = (
        SELECT count(*) FROM jsonb_array_elements(value->'blocks') block
        WHERE block ? 'cycle_ledger' OR block ? 'fleet'
      ) AND 1 = (
        SELECT count(*) FROM jsonb_array_elements(value->'blocks') block
        WHERE block ? 'cycle_ledger' AND block ? 'fleet' AND
          block->'cycle_ledger'->'scope'->>'workspace_id' = workspace::text AND
          block->'cycle_ledger'->'scope'->>'project_id' = project::text AND
          block->'cycle_ledger'->'scope'->>'epic_id' = epic AND
          block->'cycle_ledger'->'scope'->>'wave_id' = wave AND
          block->'cycle_ledger'->>'wave_revision' = wave_revision::text AND
          block->'cycle_ledger'->>'inventory_digest' = inventory_digest AND
          block->'cycle_ledger'->>'plan_digest' = plan_digest AND
          block->'cycle_ledger'->>'reconciliation_digest' = reconciliation_digest AND
          block->'cycle_ledger'->'exact' = 'true'::jsonb AND
          block->'cycle_ledger'->'fleet_complete' = 'true'::jsonb AND
          block->'cycle_ledger'->'experiment'->'complete?' = 'true'::jsonb AND
          block->'cycle_ledger'->'correction_receipt' = correction_receipt AND
          block->'cycle_ledger'->'duplicate_assignment_unit_ids' = '[]'::jsonb AND
          block->'cycle_ledger'->'unknown_assignment_unit_ids' = '[]'::jsonb AND
          block->'cycle_ledger'->'unknown_outcome_unit_ids' = '[]'::jsonb AND
          block->'cycle_ledger'->'outcome_overlap_unit_ids' = '[]'::jsonb AND
          block->'cycle_ledger'->'outcome_ownership_violation_unit_ids' = '[]'::jsonb AND
          block->'cycle_ledger'->'invalid_build_assignment_ids' = '[]'::jsonb AND
          block->'cycle_ledger'->'invalid_build_result_assignment_ids' = '[]'::jsonb AND
          block->'cycle_ledger'->'unassigned_unit_ids' = '[]'::jsonb AND
          block->'cycle_ledger'->'unaccounted_unit_ids' = '[]'::jsonb AND
          barkpark_jsonb_canonical_digest(block->'fleet') = fleet_digest
      );
    $$ LANGUAGE sql IMMUTABLE STRICT;
    """
  end

  defp b1_document_function do
    """
    CREATE OR REPLACE FUNCTION barkpark_b1_document(experiment_uuid uuid) RETURNS jsonb AS $$
    DECLARE experiment epic_benchmark_experiments%ROWTYPE;
    DECLARE attempts jsonb;
    DECLARE summary jsonb;
    DECLARE base jsonb;
    BEGIN
      SELECT * INTO experiment FROM epic_benchmark_experiments WHERE id = experiment_uuid;
      IF NOT FOUND THEN RETURN NULL; END IF;
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'attempt_id', attempt_id, 'replaces_attempt_id', replaces_attempt_id,
        'ordinal', ordinal, 'treatment', treatment, 'status', status, 'costs', costs,
        'provenance', provenance, 'payload', payload, 'attempt_digest', attempt_digest
      ) ORDER BY ordinal, attempt_id), '[]'::jsonb) INTO attempts
      FROM epic_benchmark_attempts WHERE experiment_id = experiment_uuid;
      summary := jsonb_build_object(
        'attempt_count', jsonb_array_length(attempts),
        'outcomes', jsonb_build_object(
          'completed', (SELECT count(*) FROM epic_benchmark_attempts WHERE experiment_id=experiment_uuid AND status='completed'),
          'failed', (SELECT count(*) FROM epic_benchmark_attempts WHERE experiment_id=experiment_uuid AND status='failed'),
          'timeout', (SELECT count(*) FROM epic_benchmark_attempts WHERE experiment_id=experiment_uuid AND status='timeout'),
          'contaminated', (SELECT count(*) FROM epic_benchmark_attempts WHERE experiment_id=experiment_uuid AND status='contaminated'),
          'cancelled', (SELECT count(*) FROM epic_benchmark_attempts WHERE experiment_id=experiment_uuid AND status='cancelled')
        ),
        'cost_states', jsonb_build_object(
          'observed', (SELECT count(*) FROM epic_benchmark_attempts a, LATERAL jsonb_each(a.costs) metric WHERE a.experiment_id=experiment_uuid AND metric.value->>'state'='observed'),
          'unsupported', (SELECT count(*) FROM epic_benchmark_attempts a, LATERAL jsonb_each(a.costs) metric WHERE a.experiment_id=experiment_uuid AND metric.value->>'state'='unsupported'),
          'missing', (SELECT count(*) FROM epic_benchmark_attempts a, LATERAL jsonb_each(a.costs) metric WHERE a.experiment_id=experiment_uuid AND metric.value->>'state'='missing'),
          'invalid', (SELECT count(*) FROM epic_benchmark_attempts a, LATERAL jsonb_each(a.costs) metric WHERE a.experiment_id=experiment_uuid AND metric.value->>'state'='invalid')
        ),
        'treatments', COALESCE((SELECT jsonb_object_agg(treatment, amount) FROM (SELECT treatment, count(*) amount FROM epic_benchmark_attempts WHERE experiment_id=experiment_uuid GROUP BY treatment) rows), '{}'::jsonb)
      );
      base := jsonb_build_object(
        'format', 'barkpark-epic-benchmark-v1',
        'experiment', jsonb_build_object('workspace_id', experiment.workspace_id, 'epic_id', experiment.epic_id, 'wave_id', experiment.wave_id, 'experiment_id', experiment.experiment_id, 'phase', experiment.phase, 'protocol_version', experiment.protocol_version),
        'manifest', experiment.manifest,
        'manifest_digest', barkpark_jsonb_canonical_digest(experiment.manifest),
        'attempts', attempts,
        'attempts_digest', barkpark_jsonb_canonical_digest(attempts),
        'summary', summary,
        'summary_digest', barkpark_jsonb_canonical_digest(summary)
      );
      RETURN base || jsonb_build_object('ledger_digest', barkpark_jsonb_canonical_digest(base));
    END;
    $$ LANGUAGE plpgsql STABLE STRICT;
    """
  end

  defp immutability_function do
    """
    CREATE OR REPLACE FUNCTION barkpark_cycle_correction_immutable() RETURNS trigger AS $$
    DECLARE teardown_workspace text;
    DECLARE call_stack text;
    BEGIN
      teardown_workspace := current_setting('barkpark.cycle_teardown_workspace', true);
      GET DIAGNOSTICS call_stack = PG_CONTEXT;
      IF TG_OP = 'DELETE' AND pg_trigger_depth() > 1 AND teardown_workspace <> '' AND
         OLD.workspace_id::text = teardown_workspace THEN
        RETURN OLD;
      END IF;
      IF TG_OP = 'DELETE' AND OLD.workspace_id::text = teardown_workspace AND
         call_stack LIKE '%barkpark_prepare_workspace_cycle_teardown%' THEN
        RETURN OLD;
      END IF;
      RAISE EXCEPTION '% is append-only (% forbidden)', TG_TABLE_NAME, TG_OP;
    END;
    $$ LANGUAGE plpgsql;
    """
  end

  defp workspace_cycle_teardown_function do
    """
    CREATE FUNCTION barkpark_prepare_workspace_cycle_teardown(teardown_workspace uuid)
    RETURNS void AS $$
    BEGIN
      PERFORM set_config('barkpark.cycle_teardown_workspace', teardown_workspace::text, true);
      DELETE FROM cycle_correction_promotion_events WHERE workspace_id = teardown_workspace;
      DELETE FROM cycle_correction_quarantines WHERE workspace_id = teardown_workspace;
      DELETE FROM cycle_correction_admissions WHERE workspace_id = teardown_workspace;
      DELETE FROM cycle_correction_targets WHERE workspace_id = teardown_workspace;
      DELETE FROM cycle_correction_roots WHERE workspace_id = teardown_workspace;
      PERFORM set_config('barkpark.cycle_teardown_workspace', '', true);
    EXCEPTION WHEN OTHERS THEN
      PERFORM set_config('barkpark.cycle_teardown_workspace', '', true);
      RAISE;
    END;
    $$ LANGUAGE plpgsql SECURITY DEFINER;
    """
  end

  defp guarded_teardown_function do
    teardown_function(true)
  end

  defp previous_teardown_function do
    teardown_function(false)
  end

  defp teardown_function(include_corrections?) do
    correction_project =
      if include_corrections?,
        do: """
        DELETE FROM cycle_correction_promotion_events WHERE project_id = OLD.id;
        DELETE FROM cycle_correction_quarantines WHERE project_id = OLD.id;
        DELETE FROM cycle_correction_admissions WHERE project_id = OLD.id;
        DELETE FROM cycle_correction_targets WHERE project_id = OLD.id;
        DELETE FROM cycle_correction_roots WHERE project_id = OLD.id;
        """,
        else: ""

    correction_workspace =
      if include_corrections?,
        do: """
        DELETE FROM cycle_correction_promotion_events WHERE workspace_id = OLD.id;
        DELETE FROM cycle_correction_quarantines WHERE workspace_id = OLD.id;
        DELETE FROM cycle_correction_admissions WHERE workspace_id = OLD.id;
        DELETE FROM cycle_correction_targets WHERE workspace_id = OLD.id;
        DELETE FROM cycle_correction_roots WHERE workspace_id = OLD.id;
        """,
        else: ""

    """
    CREATE OR REPLACE FUNCTION barkpark_teardown_cycle_ledger() RETURNS trigger AS $$
    DECLARE teardown_workspace uuid;
    BEGIN
      IF TG_TABLE_NAME = 'projects' THEN
        SELECT workspace_id INTO teardown_workspace FROM projects WHERE id = OLD.id;
      ELSE
        teardown_workspace := OLD.id;
      END IF;
      PERFORM set_config('barkpark.cycle_teardown_workspace', teardown_workspace::text, true);
      SET CONSTRAINTS epic_assignments_replaces_assignment_id_fkey DEFERRED;
      IF TG_TABLE_NAME = 'projects' THEN
        #{correction_project}
        DELETE FROM epic_assignment_runtime_attempts attempt USING epic_assignments assignment, cycle_waves wave
        WHERE attempt.assignment_id = assignment.id AND assignment.cycle_wave_id = wave.id AND wave.project_id = OLD.id;
        DELETE FROM epic_assignment_results result USING epic_assignments assignment, cycle_waves wave
        WHERE result.assignment_id = assignment.id AND assignment.cycle_wave_id = wave.id AND wave.project_id = OLD.id;
        DELETE FROM epic_assignment_tasks binding USING epic_assignments assignment, cycle_waves wave
        WHERE binding.assignment_id = assignment.id AND assignment.cycle_wave_id = wave.id AND wave.project_id = OLD.id;
        DELETE FROM epic_assignments assignment USING cycle_waves wave
        WHERE assignment.cycle_wave_id = wave.id AND wave.project_id = OLD.id;
        DELETE FROM cycle_build_plans plan USING cycle_waves wave
        WHERE plan.wave_id = wave.id AND wave.project_id = OLD.id;
        DELETE FROM cycle_waves WHERE project_id = OLD.id;
      ELSE
        #{correction_workspace}
        DELETE FROM epic_assignment_runtime_attempts attempt USING epic_assignments assignment
        WHERE attempt.assignment_id = assignment.id AND assignment.workspace_id = OLD.id;
        DELETE FROM epic_assignment_results result USING epic_assignments assignment
        WHERE result.assignment_id = assignment.id AND assignment.workspace_id = OLD.id;
        DELETE FROM epic_assignment_tasks binding USING epic_assignments assignment
        WHERE binding.assignment_id = assignment.id AND assignment.workspace_id = OLD.id;
        DELETE FROM epic_assignments WHERE workspace_id = OLD.id;
        DELETE FROM cycle_build_plans plan USING cycle_waves wave
        WHERE plan.wave_id = wave.id AND wave.workspace_id = OLD.id;
        DELETE FROM cycle_waves WHERE workspace_id = OLD.id;
      END IF;
      SET CONSTRAINTS epic_assignments_replaces_assignment_id_fkey IMMEDIATE;
      PERFORM set_config('barkpark.cycle_teardown_workspace', '', true);
      RETURN OLD;
    EXCEPTION WHEN OTHERS THEN
      SET CONSTRAINTS epic_assignments_replaces_assignment_id_fkey IMMEDIATE;
      PERFORM set_config('barkpark.cycle_teardown_workspace', '', true);
      RAISE;
    END;
    $$ LANGUAGE plpgsql;
    """
  end
end
