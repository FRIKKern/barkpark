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
    * `onix.publicationId` is `pub-<g div 4>`, and `onix.isbn` is `isbn`
    * `onix.publishingDate` is 2000-01-01 plus `(g * 37) mod 9000` days
    * `onix.publicationStatus.value` is `07` when g mod 11 is 0, else `04`;
      `onix.availability.value` is `40` when g mod 7 is 0, else `21`;
      `access.buyStatus` is `sold_out` when g mod 13 is 0, else `available`
    * `slugHistory[0].value` is `/bok/p<g>`
    * for 4 <= g <= 400 the products form families of four: `p<4k>` is the
      main product, the other three carry `mainProduct._ref == "p<4k>"`, all
      four are titled `Book <k>`, and `p<4k+1>` lists `p<4k+401>` as a
      language variant; every other product is titled `Product <g>`
    * `isMainProduct` is true except for the three children in each family
    * `hidden` is true when g mod 17 is 0, false when g mod 17 is 1, and
      missing otherwise
    * `description` is `""` when g mod 19 is 0, else `Book <g>`
    * `publishedAt` is `onix.publishingDate` as milliseconds since 1970
    * `themaCodes` is `["T<g mod 2000>", "T<g * 7 mod 2000>", "U<g mod 23>"]`
  """

  alias Barkpark.{Auth, Content, Repo, Tenancy}

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
               'access', jsonb_build_object('buyStatus',
                 CASE WHEN g % 13 = 0 THEN 'sold_out' ELSE 'available' END),
               'onix', jsonb_build_object(
                 'publicationId', 'pub-' || (g / 4),
                 'isbn', '978' || lpad(g::text, 7, '0'),
                 'publishingDate', to_char(date '2000-01-01' + (g * 37) % 9000, 'YYYY-MM-DD'),
                 'publicationStatus', jsonb_build_object('value',
                   CASE WHEN g % 11 = 0 THEN '07' ELSE '04' END),
                 'availability', jsonb_build_object('value',
                   CASE WHEN g % 7 = 0 THEN '40' ELSE '21' END),
                 'contributors', jsonb_build_array(jsonb_build_object(
                   '_key', 'k',
                   'contributor', jsonb_build_object('_type', 'reference', '_ref', 'c-' || (g % 700)),
                   'role', jsonb_build_object('_ref', CASE WHEN g % 2 = 0 THEN 'A01' ELSE 'B06' END)))),
               'slugHistory', jsonb_build_array(
                 jsonb_build_object('_key', 's', 'match', 'url', 'value', '/bok/p' || g)),
               'description', CASE WHEN g % 19 = 0 THEN '' ELSE 'Book ' || g END,
               'publishedAt', (946684800 + ((g * 37) % 9000) * 86400)::bigint * 1000,
               'themaCodes', jsonb_build_array('T' || (g % 2000), 'T' || ((g * 7) % 2000),
                 'U' || (g % 23)))
             || CASE WHEN g % 17 = 0 THEN '{"hidden": true}'::jsonb
                     WHEN g % 17 = 1 THEN '{"hidden": false}'::jsonb
                     ELSE '{}'::jsonb END
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

  @doc """
  The site the large-dataset GROQ tests query: workspace `groq-big`, project
  `site`, public `product`, `article` and `department` schemas in `dataset`,
  `n` products from `seed!/2`, the article `a1` (a hidden redirect to
  `/bok/p123`), the departments `dept-big` and `dept-small`, and a read+write
  token. Returns `[token: token, scope: scope]` for a test context.
  """
  @spec seed_site!(String.t(), pos_integer()) :: keyword()
  def seed_site!(dataset, n) do
    {:ok, ws} = Tenancy.create_workspace(%{slug: "groq-big", name: "GROQ big"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "site", name: "Site"})
    scope = [workspace_id: ws.id, project_id: proj.id]

    for type <- ["product", "article", "department"] do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => type, "title" => type, "visibility" => "public", "fields" => []},
          dataset,
          scope
        )
    end

    {:ok, _} = Content.create_document("product", %{"_id" => "template"}, dataset, scope)
    {:ok, _} = Content.publish_document("template", "product", dataset, scope)
    seed!(dataset, n)

    {:ok, _} =
      Content.create_document(
        "article",
        %{
          "_id" => "a1",
          "isHidden" => true,
          "slugHistory" => [%{"_key" => "s", "match" => "url", "value" => "/bok/p123"}]
        },
        dataset,
        scope
      )

    {:ok, _} = Content.publish_document("a1", "article", dataset, scope)

    for id <- ["dept-big", "dept-small"] do
      {:ok, _} = Content.create_document("department", %{"_id" => id}, dataset, scope)
      {:ok, _} = Content.publish_document(id, "department", dataset, scope)
    end

    token = "groq-big-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(token, "groq big", dataset, ["read", "write"], ws.id)

    [token: token, scope: scope]
  end
end
