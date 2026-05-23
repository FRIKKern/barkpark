defmodule Barkpark.Papers do
  @moduledoc """
  Context for paperflow papers (convergence MVP, masterplan Figure 6).

  A paper is a slug-keyed row holding opaque pre-rendered article HTML.
  `upsert_paper/1` writes the latest HTML and broadcasts on the **same**
  per-doc PubSub topic shape Barkpark already uses for documents —
  `doc:<dataset>:<type>:<id>` (see `Barkpark.Content.tap_broadcast/5`) — so
  `BarkparkWeb.PaperLive` rides the existing `tap_broadcast → Phoenix.PubSub
  → LiveView` spine. No new broadcast engine, no GenServer-per-document.

  The "no reload" win comes purely from LiveView re-assigning `@html` on
  each broadcast and letting morphdom diff the DOM — there are no delta
  frames here, by design.
  """

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Repo
  alias Barkpark.Papers.Paper

  @default_dataset "paperflow"
  # Matches the `type` segment used in the documents per-doc topic; papers
  # are their own logical type on the shared spine.
  @paper_type "paper"

  @doc "The default dataset papers live under (mirrors the paperflow side)."
  def default_dataset, do: @default_dataset

  @doc """
  Per-doc PubSub topic for a paper. Same shape as the documents spine:
  `doc:<dataset>:<type>:<id>`. PaperLive subscribes to this; `upsert_paper/1`
  broadcasts to it.
  """
  def topic(slug, dataset \\ @default_dataset) when is_binary(slug) do
    "doc:#{dataset}:#{@paper_type}:#{slug}"
  end

  @doc "Fetch a paper by slug (and dataset). Returns the struct or nil."
  def get_paper(slug, dataset \\ @default_dataset) when is_binary(slug) do
    Repo.one(from p in Paper, where: p.slug == ^slug and p.dataset == ^dataset)
  end

  @doc """
  Upsert a paper keyed by `{dataset, slug}` and broadcast the new HTML on the
  per-doc topic.

  `attrs` accepts string or atom keys: `slug` (required), `body_html`
  (required), and optionally `dataset`, `source_doc`, `goal_id`,
  `event_type`. A fresh `rev` is minted on every write.

  On success, broadcasts `{:paper_updated, %{slug:, dataset:, html:, rev:,
  ...}}` to `topic(slug, dataset)` and returns `{:ok, paper}`. Returns
  `{:error, changeset}` on validation/constraint failure.
  """
  def upsert_paper(attrs) when is_map(attrs) do
    attrs = normalize(attrs)
    slug = attrs["slug"]
    dataset = attrs["dataset"] || @default_dataset
    attrs = Map.put(attrs, "dataset", dataset)

    existing = slug && get_paper(slug, dataset)

    changeset =
      (existing || %Paper{})
      |> Paper.changeset(Map.put(attrs, "rev", generate_rev()))

    result =
      if existing do
        Repo.update(changeset)
      else
        Repo.insert(changeset)
      end

    case result do
      {:ok, paper} ->
        broadcast_update(paper)
        {:ok, paper}

      error ->
        error
    end
  end

  # ── Internal ────────────────────────────────────────────────────────────

  defp broadcast_update(%Paper{} = paper) do
    msg =
      {:paper_updated,
       %{
         slug: paper.slug,
         dataset: paper.dataset,
         html: paper.body_html,
         rev: paper.rev,
         source_doc: paper.source_doc,
         goal_id: paper.goal_id,
         event_type: paper.event_type
       }}

    Phoenix.PubSub.broadcast(Barkpark.PubSub, topic(paper.slug, paper.dataset), msg)
  end

  # Allow callers to pass atom OR string keys (controller params are strings,
  # internal callers/tests may use atoms). Stringify, dropping nils.
  defp normalize(attrs) do
    Enum.reduce(attrs, %{}, fn {k, v}, acc ->
      key = if is_atom(k), do: Atom.to_string(k), else: k
      if is_nil(v), do: acc, else: Map.put(acc, key, v)
    end)
  end

  defp generate_rev do
    16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  end
end
