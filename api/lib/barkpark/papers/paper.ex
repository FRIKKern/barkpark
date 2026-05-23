defmodule Barkpark.Papers.Paper do
  @moduledoc """
  A paperflow paper mirrored into Barkpark for live rendering (convergence
  MVP, masterplan Figure 6).

  Stores the paper's pre-rendered article-body HTML **opaquely** — no schema
  validation, no portable-doc block list, no AST. The HTML is our own
  (produced by paperflow's doc pipeline); it is dropped into a LiveView
  container verbatim via `raw/1`. Block-by-block streaming is a later
  refinement.
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
    field :body_html, :string, default: ""
    field :rev, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(paper, attrs) do
    paper
    |> cast(attrs, [:slug, :dataset, :source_doc, :goal_id, :event_type, :body_html, :rev])
    |> validate_required([:slug, :dataset, :body_html])
    |> unique_constraint([:dataset, :slug])
  end
end
