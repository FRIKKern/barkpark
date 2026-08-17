<!-- doc-tier: cold | canonical-for: felix-w25-dataset-slug-reachability-rederivation | budget: 1200tok -->

# Felix W25 — dataset-slug reachability re-derivation (2026-08-17)

Verifier row for the `dataset-slug-format` slice. Re-derives, against `origin/main`,
the non-admin route that carries a user-supplied slug into `Tenancy.Dataset.changeset`,
proves the changeset is the only format gate on that path, and confirms the
COPY-FROM-STDIN bypass.

## Verdict

STILL-LIVE. Dataset is the only tenancy slug schema without `validate_format`
(Workspace + Project both have it). A NON-admin write-token path reaches its
changeset. The COPY-FROM-STDIN bundle-import bypass is CONFIRMED. Escaper half
(catalog.ex) is under `workspace_bundle/` and inherits the D82 fence ruling; the
changeset half (dataset.ex) is NOT under the fence.

## Non-admin route → changeset (re-run)

    git show origin/main:api/lib/barkpark_web/router.ex | sed -n '1884,1888p'
    #   scope "/v1/data" pipe_through([:api, :require_token, :require_write, :idempotent])
    #   post("/mutate/:dataset", MutateController, :mutate)
    git show origin/main:api/lib/barkpark_web/router.ex | sed -n '781,783p'
    #   pipeline :require_write do plug(BarkparkWeb.Plugs.RequireWritePermission) end  -- write token, NOT admin

Chain (each hop re-derivable by git grep):

    :dataset URL segment
      -> MutateController.mutate  (mutate_controller.ex:12)  Content.apply_mutations(mutations, dataset, opts)
      -> Content.create_document  -> Writer.create_document (writer.ex:83)
           writer.ex:92  |> Map.put("dataset", dataset)
           writer.ex:104 |> WriteScope.put_scope_attrs(opts)
      -> write_scope.ex:80  resolve_dataset_id_for_write(attrs, project_id)
      -> Tenancy.get_or_create_dataset (tenancy.ex:1095) -> create_dataset (tenancy.ex:1067)
      -> Dataset.changeset (dataset.ex:27)

## Changeset is the only format gate — but it does NOT block the write

    git show origin/main:api/lib/barkpark/tenancy/dataset.ex | sed -n '27,40p'
    #   validate_length(:slug, min: 1, max: 63)  -- NO validate_format
    git show origin/main:api/lib/barkpark/content/write_scope.ex | sed -n '136,150p'
    #   {:error, changeset} -> nil   (degrades; content row's `dataset` STRING written regardless)

No upstream controller guard validates slug FORMAT; the route has no path constraint.
A slug of any bytes up to 63 chars (quotes/semicolons included) passes validate_length,
creating a real `datasets` row. On changeset error the dataset_id stamp degrades to nil
and the content write still lands the raw `dataset` string.

## COPY-FROM-STDIN bypass — CONFIRMED

    git show origin/main:api/lib/barkpark/tenancy/workspace_bundle.ex | sed -n '300,315p'
    #   each `COPY ... FROM STDIN` is fed from File.stream!/2  -- raw byte stream, no Ecto/changeset

The `datasets` table member re-imports via `COPY ... FROM STDIN`; arbitrary slug bytes
in the member file land directly in the table, bypassing the changeset entirely.

## Escaper (fenced half)

    git show origin/main:api/lib/barkpark/tenancy/workspace_bundle/catalog.ex | sed -n '681,684p'
    #   text_literal(v) -> "'#{escape_sql_string(v)}'"
    #   escape_sql_string -> String.replace(value, "'", "''")   -- single-quote doubling ONLY

Slugs read back by `dataset_slugs_for/1` are interpolated into COPY subquery WHERE
clauses via `text_literal`/`text_array_literal`. Safety hinges on
`standard_conforming_strings = on` (never asserted). This file sits under
`workspace_bundle/` -> inherits the D82 fence verdict; the changeset fix in
`dataset.ex` does not.
