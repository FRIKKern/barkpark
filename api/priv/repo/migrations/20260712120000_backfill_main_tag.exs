defmodule Barkpark.Repo.Migrations.BackfillMainTag do
  use Ecto.Migration

  @moduledoc """
  One-time backfill of `content.main_tag` (authoring-excellence D7/D20).

  From this release on, `Barkpark.Content.Lifecycle` stamps the derived main
  tag (the strength argmax) onto every published row's content at the publish
  chokepoint. This migration stamps the rows published BEFORE the stamp
  existed — the weighted-tag corpus that accumulated between the wall's merge
  (553a65b2) and this release (~10 published docs at ship time).

  It calls `Barkpark.Content.LabelSpine.main_tag/1` — the SAME derivation the
  chokepoint uses — so backfilled and freshly published rows can never
  disagree on the argmax rule. Rows whose tags don't validate as weighted
  labels (legacy flat strings under the exemption ratchet, tagless docs)
  return `:error` and are left byte-untouched.

  Idempotent: `main_tag` is recomputed from `tags` and overwritten via
  `jsonb_set`; re-running converges to the same value. Sized for the real
  corpus (one UPDATE per stamped row over a ~10-row set) — NOT a batched
  streaming pass, deliberately.
  """

  def up do
    %{rows: rows} =
      repo().query!(
        "SELECT id, content FROM documents WHERE status = 'published' AND jsonb_typeof(content->'tags') = 'array'"
      )

    for [id, content] <- rows do
      case Barkpark.Content.LabelSpine.main_tag(content) do
        {:ok, tag} ->
          repo().query!(
            "UPDATE documents SET content = jsonb_set(content, '{main_tag}', to_jsonb($1::text)) WHERE id = $2",
            [tag, id]
          )

        :error ->
          :ok
      end
    end

    :ok
  end

  def down do
    repo().query!(
      "UPDATE documents SET content = content - 'main_tag' WHERE content ? 'main_tag'"
    )

    :ok
  end
end
