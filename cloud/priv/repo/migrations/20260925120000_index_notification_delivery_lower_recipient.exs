defmodule BarkparkCloud.Repo.Migrations.IndexNotificationDeliveryLowerRecipient do
  use Ecto.Migration

  @moduledoc """
  cch-w34-bl-lower-recipient-index — the member's SELF-SCOPED delivery log.

  `GET /v1/notifications/deliveries` fences a non-admin read with
  `lower(recipient) = $email` (`Notifications.maybe_delivery_recipient/2`). No
  index carried `lower(recipient)`, so the read DEGRADES AS RECIPIENT
  CARDINALITY RISES: with few recipients per team the planner keeps
  `(team_id, inserted_at)` and filters a handful of rows; with many it abandons
  that index, bitmap-scans the team and top-N sorts. The measured plans, before
  and after, at both cardinality shapes and with the index set named, are in the
  route comment above `GET /v1/notifications/deliveries` in `Web.Router`.

  The fix is one expression index, `(team_id, lower(recipient), inserted_at)`,
  so the fence becomes an Index Cond and the ORDER BY walks the index backwards
  to the LIMIT.

  ## Plain build, not CONCURRENTLY (house pattern, charter D366)

  Same decision and same reason as `20260918110000`: an interrupted
  `CREATE INDEX CONCURRENTLY` leaves `indisvalid = false`, and the build this
  file would otherwise lean on — `CREATE INDEX IF NOT EXISTS` — answers
  `NOTICE … already exists, skipping` and RETURNS SUCCESS over that dead index,
  so `schema_migrations` stamps the version and a permanently ignored index
  ships green. A plain build inside the migration transaction either commits a
  valid index or rolls back unstamped. The table is small (~2k rows in
  production per the route note; `AgentRetentionWorker` prunes it past 180
  days), so the SHARE lock is shorter than a normal statement.

  ## The guard — because a plain build does not cover a HAND-BUILT index

  Production has zero invalid indexes today, but an operator hot-fixing this
  exact read with a hand-run `CREATE INDEX CONCURRENTLY` under the same name
  (the `tmp_dep_site_live` precedent, `20260807140000`) can leave one behind.
  `IF NOT EXISTS` would then adopt the corpse. So `up/0` runs three statements:

    1. `drop_invalid_sql/1` — if an index of this name exists with
       `indisvalid = false`, DROP it (drop-and-rebuild);
    2. `create_sql/0` — `CREATE INDEX IF NOT EXISTS`, which adopts a VALID
       hand-built index of the same name rather than failing on it;
    3. `assert_valid_sql/2` — RAISE unless the index now exists, is
       `indisvalid AND indisready`, and its definition is the expected column
       list. A same-named index over the wrong columns is refused too.

  Step 3 alone is the tripwire; step 1 makes the common case self-healing.
  `test/barkpark_cloud/notifications/delivery_recipient_index_test.exs` proves
  both by CONSTRUCTING an invalid index (production has none to observe).
  """

  @table "notification_deliveries"
  # 62 bytes. The natural `…_team_id_lower_recipient_inserted_at_index` is 65,
  # and Postgres TRUNCATES an over-long identifier to 63 bytes with only a
  # NOTICE — every later lookup by the full name would then miss (or, cast to
  # `name`, silently match the truncation). Keep it under the limit.
  @index "notification_deliveries_team_lower_recipient_inserted_at_index"
  # pg_get_indexdef's rendering of the key, which is what step 3 compares.
  @key "(team_id, lower((recipient)::text), inserted_at)"

  def index_name, do: @index
  def key, do: @key

  def up do
    execute(drop_invalid_sql(@index))
    execute(create_sql())
    execute(assert_valid_sql(@index, @key))
  end

  def down do
    execute("DROP INDEX IF EXISTS #{@index}")
  end

  def create_sql do
    "CREATE INDEX IF NOT EXISTS #{@index} ON #{@table} (team_id, lower(recipient), inserted_at)"
  end

  @doc "Drop the named index when it exists but `indisvalid = false`."
  def drop_invalid_sql(index) do
    """
    DO $guard$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
        WHERE c.relname = '#{index}' AND NOT i.indisvalid
      ) THEN
        RAISE NOTICE 'dropping INVALID index % before rebuilding it', '#{index}';
        EXECUTE 'DROP INDEX #{index}';
      END IF;
    END
    $guard$
    """
  end

  @doc "Raise unless the named index exists, is valid and ready, and has `key`."
  def assert_valid_sql(index, key) do
    """
    DO $guard$
    DECLARE
      v boolean;
      r boolean;
      def text;
    BEGIN
      SELECT i.indisvalid, i.indisready, pg_get_indexdef(i.indexrelid)
        INTO v, r, def
        FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
       WHERE c.relname = '#{index}';

      IF NOT FOUND THEN
        RAISE EXCEPTION 'index % is missing after its migration', '#{index}';
      END IF;
      IF NOT (v AND r) THEN
        RAISE EXCEPTION 'index % is INVALID (indisvalid=%, indisready=%): the planner will ignore it', '#{index}', v, r;
      END IF;
      IF position('#{key}' in def) = 0 THEN
        RAISE EXCEPTION 'index % has the wrong definition: %', '#{index}', def;
      END IF;
    END
    $guard$
    """
  end
end
