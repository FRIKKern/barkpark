defmodule Barkpark.Repo.Migrations.AddBlocksAndRevToPapers do
  use Ecto.Migration

  # Convergence Wave 4 (block-streaming). T4.1 storage.
  #
  # The block list (portable-doc AST) becomes the source of truth; `body_html`
  # becomes a derived cache rendered by `Barkpark.PortableDoc.Render` on write.
  # HTML-only papers (blocks IS NULL) keep rendering from their stored
  # `body_html` — there is NO backfill of legacy rows into blocks.
  #
  # `rev` changes from a random hex string (Wave 3) to a monotonic per-paper
  # INTEGER so PaperLive can detect a missed delta frame (received rev !=
  # expected rev) and refetch. The old string column is dropped and re-added as
  # an integer; Wave-3 papers are dev-only so there is nothing to preserve in
  # the column itself (the HTML cache survives untouched).
  def change do
    alter table(:papers) do
      # Source of truth. NULL ⇒ this is a legacy HTML-only paper.
      add :blocks, :jsonb, null: true

      # Drop the Wave-3 random-hex string rev and re-add as a monotonic int.
      remove :rev, :text
      add :rev, :integer, null: false, default: 0
    end
  end
end
