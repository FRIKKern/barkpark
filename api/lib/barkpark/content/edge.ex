defmodule Barkpark.Content.Edge do
  @moduledoc """
  A single typed, materialised edge in the content graph between two
  `documents` rows.

  Mirrors `Barkpark.Tasks.Edge` structurally (binary-id PK, two `documents`
  FKs, a `:string` `kind`, the same `(from_id, to_id, kind)` uniqueness) but
  with one deliberate divergence:

  > These rows carry MUTABLE metadata (`weight`, `plugin_source`) and therefore
  > `updated_at` — unlike `Tasks.Edge` whose rows are immutable
  > (`updated_at: false`). The Phase-3 projector re-extracts and upserts edges
  > via `on_conflict: {:replace, [:weight, :plugin_source, :updated_at]}`, so
  > the timestamp MUST exist to be bumped. Do NOT copy `Tasks.Edge`'s
  > `updated_at: false` back over this schema.

  ## Dangling targets are NEVER stored

  The `to_id` FK rejects any `to_id` that is not a real `documents.id`, so a
  dangling edge is UNSTORABLE — this table holds ONLY resolvable edges. There
  is deliberately NO `:dangling` field. The live dangling signal is the
  `get_document/4` (typed) + `Repo.exists?` (untyped) resolution pass in
  `Barkpark.Content.resolve_target_existence/4` and the Phase-4
  `Barkpark.Content.Graph`, NOT a table flag.

  ## Weight is layout-only

  `weight` is a layout hint (edge thickness / spring length) consumed ONLY by
  the Studio Canvas2D graph renderer's force sim (bp-graph.js). Ranking is
  topology and never reads it.

  ## Direction

  `from_id` = the source document (it points AT something).
  `to_id`   = the target document (it is pointed at).

  ## Kinds

  Core + plugin-projected kinds the graph understands. The column is `:string`
  so a new kind lands without a migration. Reference-field edges now carry the
  SOURCE FIELD NAME as their kind (graph-edge-seam): a `dependencies` reference
  → kind `"dependencies"`, `intentions` → `"intentions"`, `related` →
  `"related"`. Because a schema may declare ANY reference field name, the
  changeset no longer validates `kind` against a closed allowlist — that would
  force a code edit for every new reference field. The boundary is now
  structural: `kind` must be a non-empty string. `@kinds` below stays as the
  documented set of well-known core/plugin kinds (for reference / tests), not as
  a gate.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Barkpark.Content.Document

  # `valueref` (Bulldocs body-walk, wire §7) is spelled IDENTICALLY to the
  # inline node type that projects it — `valueref`, never `value-ref`.
  @kinds ~w(references embeds related-to parent blocks discovered-from valueref
            design_doc wave_paper papers)

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "content_edges" do
    belongs_to :from, Document, foreign_key: :from_id, type: :binary_id
    belongs_to :to, Document, foreign_key: :to_id, type: :binary_id
    field :kind, :string

    # LAYOUT-ONLY — Canvas2D force-sim edge thickness / spring; never read by ranking.
    field :weight, :float
    field :plugin_source, :string

    # PRESENT (NOT updated_at: false) — diverges from Tasks.Edge deliberately;
    # these rows are mutable and the Phase-3 upsert bumps updated_at on conflict.
    timestamps(type: :utc_datetime_usec)
  end

  @doc "The known edge kinds. Extending is a one-line edit; no migration."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc """
  Changeset for inserting / upserting an edge. Validates
  `from_id`/`to_id`/`kind` presence (kind must be a non-empty string — reference
  edges carry the source field name, so there is no closed kind allowlist);
  rejects self-edges. The FK + uniqueness constraints in the migration are
  surfaced as changeset errors for friendlier callers. `weight` and
  `plugin_source` are optional mutable metadata.
  """
  def changeset(edge, attrs) do
    edge
    |> cast(attrs, [:from_id, :to_id, :kind, :weight, :plugin_source])
    |> validate_required([:from_id, :to_id, :kind])
    |> validate_format(:kind, ~r/\S/, message: "must be a non-empty string")
    |> validate_not_self_edge()
    |> foreign_key_constraint(:from_id)
    |> foreign_key_constraint(:to_id)
    |> unique_constraint([:from_id, :to_id, :kind],
      name: :content_edges_from_to_kind_uniq
    )
  end

  defp validate_not_self_edge(changeset) do
    from_id = get_field(changeset, :from_id)
    to_id = get_field(changeset, :to_id)

    if from_id && to_id && from_id == to_id do
      add_error(changeset, :to_id, "edge cannot reference the same document on both sides")
    else
      changeset
    end
  end
end
