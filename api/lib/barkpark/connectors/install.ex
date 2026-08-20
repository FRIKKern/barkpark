defmodule Barkpark.Connectors.Install do
  @moduledoc """
  READ-ONLY Ecto schema over `chat_bridge.connector_installs` — the connector
  bridge's install table (Connectors D47/D54/D55).

  ## The first `@schema_prefix` in the codebase

  There is genuinely no prior pattern to copy: `grep -rn "@schema_prefix" lib/`
  returned nothing before this module. The bridge (a standalone Node service,
  `connectors/`) OWNS this table — it creates the schema and the DDL at its own
  boot (charter D28: no Ecto migration may create `chat_bridge`), and it is the
  ONLY WRITER. Elixir reads. That asymmetry is the whole contract:

    * Studio reads installs to render the Connectors catalog.
    * Studio mints + revokes `api_tokens` (Barkpark's OWN table).
    * The bridge writes/deletes `chat_bridge.connector_installs`, via the
      loopback connect seam (`Barkpark.Connectors.BridgeClient`).

  ## Two traps, both proven, neither to be rediscovered

    1. **`workspace_id` is Postgres `text`, not `uuid`** (D55). `Workspace.id`
       is `:binary_id`. An uncast compare raises
       `ERROR 42883 operator does not exist: uuid = text`. EVERY compare must
       go through `type(ci.workspace_id, Ecto.UUID)` — see
       `Barkpark.Connectors.Catalog`, which is the only query surface.

    2. **The table does not exist in the Elixir test DB** (D54). No migration
       creates it, so `api/test/test_helper.exs` creates the schema + table
       THROUGH `Barkpark.Repo` before the sandbox goes `:manual`. Through Repo
       specifically — a raw Postgrex connection would make a different role the
       owner and re-introduce the creator≠reader split.

  ## Secrets

  `credential_ref` and `chat_token_ref` are declared here ONLY so the struct
  mirrors the real table (and so the column-set pin test can see them). They are
  SEALED AES-256-GCM blobs whose AAD is the row identity, and **no Elixir will
  ever decrypt one** (D38). Every query in `Catalog` uses an EXPLICIT `select:`
  that omits both. Do not add a bare `Repo.all(Install)` — that would pull
  ciphertext into a LiveView's assigns for nothing.

  ## DDL cross-reference (D54, named cost)

  The column set below is a TRANSCRIPTION of the bridge's DDL:
  `connectors/src/db/schema.ts` → `CREATE_CONNECTOR_INSTALLS_SQL`. It is a
  second source of truth and it has already drifted once (`ADD_CHAT_TOKEN_REF_SQL`
  exists precisely because `CREATE TABLE IF NOT EXISTS` was a no-op against the
  older four-column table). Mitigations, both shipped with this module:

    * `connectors/src/db/schema.ts` carries a comment pointing back here.
    * `test/barkpark/connectors/install_schema_test.exs` pins the EXACT column
      set the catalog reads against `information_schema.columns`, so a bridge-side
      column rename reds the Elixir suite instead of 500ing Studio in prod.
  """

  use Ecto.Schema

  @schema_prefix "chat_bridge"
  @primary_key false

  @type t :: %__MODULE__{}

  schema "connector_installs" do
    field(:provider, :string, primary_key: true)
    field(:install_key, :string, primary_key: true)

    # TEXT in Postgres — NOT :binary_id. See D55 / the moduledoc.
    field(:workspace_id, :string)

    # Sealed blobs. NEVER selected (D38).
    field(:credential_ref, :string)
    field(:chat_token_ref, :string)

    field(:created_at, :utc_datetime_usec)
  end

  @doc """
  The exact column set this codebase relies on, in DDL order. The pin test
  asserts Postgres agrees; the bridge's `schema.ts` is the upstream truth.
  """
  @spec columns() :: [String.t()]
  def columns,
    do: ~w(provider install_key workspace_id credential_ref chat_token_ref created_at)

  @doc "The columns the catalog is allowed to SELECT — never a secret (D38)."
  @spec readable_columns() :: [String.t()]
  def readable_columns, do: ~w(provider install_key workspace_id created_at)
end
