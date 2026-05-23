defmodule Barkpark.Papers.Paper do
  @moduledoc """
  A paperflow paper mirrored into Barkpark for live rendering (convergence
  masterplan Figure 6; block-streaming in Wave 4).

  ## Storage model (Wave 4)

  `blocks` (jsonb) is the **source of truth** — a portable-doc block list
  (`[%{"id" => …, "type" => …}, …]`). `body_html` is a **derived cache**
  produced by `Barkpark.PortableDoc.Render` from `blocks` on every write.

  Wave-3 papers predate the block list: their `blocks` is `nil` and they
  render from the stored opaque `body_html` verbatim (no backfill). Both
  paths coexist by design — `Barkpark.Papers` chooses per paper.

  `rev` is a **monotonic per-paper integer** (Wave 4). Every write bumps it by
  one and stamps the broadcast so `BarkparkWeb.PaperLive` can detect a missed
  delta frame and refetch the full doc.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "papers" do
    field :slug, :string
    field :dataset, :string, default: "paperflow"
    field :source_doc, :string
    field :goal_id, :string
    field :event_type, :string
    # Derived HTML cache, rendered from `blocks` when present.
    field :body_html, :string, default: ""
    # Source of truth: portable-doc block list. `nil` ⇒ legacy HTML-only paper.
    field :blocks, {:array, :map}
    # Monotonic per-paper revision; bumped on every write.
    field :rev, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(paper, attrs) do
    paper
    |> cast(attrs, [:slug, :dataset, :source_doc, :goal_id, :event_type, :body_html, :blocks, :rev])
    |> validate_required([:slug, :dataset, :body_html])
    |> unique_constraint([:dataset, :slug])
  end
end
