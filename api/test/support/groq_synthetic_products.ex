defmodule Barkpark.Test.GroqSyntheticProducts do
  @moduledoc """
  Synthetic products for GROQ tests and the GROQ benchmark at scale. `seed!/2`
  copies the tenant columns of a published `product` row with `_id`
  `template` in `dataset`, which the caller creates first, into `n` products
  with one INSERT ... SELECT, then runs ANALYZE so the planner sees them.

  Product `p<g>` for g in 1..n:

    * `isbn` is `978` followed by g padded to seven digits
    * `series._ref` is `series-<g mod 50>`, and `seriesIds` is the array
      `["series-<g mod 50>"]`
    * `department._ref` is `dept-big` for g <= 10,200 and `dept-small` after
    * `onix.contributors[0]` is `c-<g mod 700>` with role A01 when g is even,
      B06 when odd
    * `onix.publicationId` is `pub-<g div 4>`
    * `slugHistory[0].value` is `/bok/p<g>`
    * for 4 <= g <= 400 the products form families of four: `p<4k>` is the
      main product, the other three carry `mainProduct._ref == "p<4k>"`, all
      four are titled `Book <k>`, and `p<4k+1>` lists `p<4k+401>` as a
      language variant; every other product is titled `Product <g>`
    * `isMainProduct` is true except for the three children in each family
  """

  alias Barkpark.Repo

  @spec seed!(String.t(), pos_integer()) :: :ok
  def seed!(dataset, n) do
    Repo.query!(
      """
      INSERT INTO documents (id, doc_id, type, dataset, title, status, content, inserted_at,
                             updated_at, rev, workspace_id, project_id, dataset_id, scope_source)
      SELECT gen_random_uuid(), 'p' || g, t.type, t.dataset,
             CASE WHEN g BETWEEN 4 AND 400 THEN 'Book ' || (g / 4) ELSE 'Product ' || g END,
             t.status,
             jsonb_build_object(
               'isbn', '978' || lpad(g::text, 7, '0'),
               'isMainProduct', NOT (g BETWEEN 4 AND 400 AND g % 4 <> 0),
               'series', jsonb_build_object('_type', 'reference', '_ref', 'series-' || (g % 50)),
               'seriesIds', jsonb_build_array('series-' || (g % 50)),
               'department', jsonb_build_object('_type', 'reference',
                 '_ref', CASE WHEN g <= 10200 THEN 'dept-big' ELSE 'dept-small' END),
               'onix', jsonb_build_object(
                 'publicationId', 'pub-' || (g / 4),
                 'contributors', jsonb_build_array(jsonb_build_object(
                   '_key', 'k',
                   'contributor', jsonb_build_object('_type', 'reference', '_ref', 'c-' || (g % 700)),
                   'role', jsonb_build_object('_ref', CASE WHEN g % 2 = 0 THEN 'A01' ELSE 'B06' END)))),
               'slugHistory', jsonb_build_array(
                 jsonb_build_object('_key', 's', 'match', 'url', 'value', '/bok/p' || g)))
             || CASE WHEN g BETWEEN 4 AND 400 AND g % 4 <> 0
                  THEN jsonb_build_object('mainProduct',
                         jsonb_build_object('_type', 'reference', '_ref', 'p' || (g - g % 4)))
                  ELSE '{}'::jsonb END
             || CASE WHEN g BETWEEN 4 AND 400 AND g % 4 = 1
                  THEN jsonb_build_object('bokbasen', jsonb_build_object('languageFormatVariants',
                         jsonb_build_array(jsonb_build_object('_type', 'reference', '_ref', 'p' || (g + 400)))))
                  ELSE '{}'::jsonb END,
             now() - interval '1 day', now() - interval '1 day', md5(g::text),
             t.workspace_id, t.project_id, t.dataset_id, t.scope_source
      FROM documents t, generate_series(1, $1::int) AS g
      WHERE t.doc_id = 'template' AND t.dataset = $2
      """,
      [n, dataset]
    )

    Repo.query!("ANALYZE documents")
    :ok
  end
end
