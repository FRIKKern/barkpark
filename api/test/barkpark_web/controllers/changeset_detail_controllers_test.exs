defmodule BarkparkWeb.ChangesetDetailControllersTest do
  @moduledoc """
  Protective coverage for wbqs-api-changeset-controllers: two changeset
  catch-alls that used to discard per-field detail now surface it
  additively, alongside their UNCHANGED code/message.

  (a) `BulldocsIngestController`'s `invalid_paper` clause (`ingest_blocks/4`
  AND `ingest_html/4` — factored into the shared `invalid_paper_error/2`
  helper). Exercised end-to-end via a real HTTP POST that trips the
  `documents_doc_id_type_dataset_id_index` unique constraint — the ONE
  realistic way `Content.upsert_paper/1` returns `{:error, changeset}` here
  (`Document.changeset/2` only validates `doc_id`/`type` presence + that
  index; everything else the ingest path fills in itself).

  (b) `AuthController.create_token/2`'s changeset clause, which now calls
  `changeset_errors/1` (the SAME helper `reset/2` already uses at line
  ~463) instead of a flat literal. `Auth.create_personal_access_token/3`'s
  `Repo.insert(ApiToken.changeset(...))` only ever returns `{:error,
  %Ecto.Changeset{}}` via `ApiToken`'s declared `token_hash`
  unique_constraint (in production, a vanishingly rare collision on the
  256-bit `:crypto.strong_rand_bytes/1` raw token — not forceable
  deterministically through the mint wrapper itself, and not mockable: no
  mock lib in this repo, and a genuine RNG collision or cross-process race
  would be flaky by construction, which the cycle's own "distrust vacuous
  green" rule rules out). We instead prove the branch is REAL, not
  hypothetical, by reproducing the SAME collision directly against
  `ApiToken.changeset/2` + `Repo.insert` (two rows, one token_hash) and
  asserting the resulting changeset carries `:token_hash` field detail
  under the same `traverse_errors` shape `changeset_errors/1` produces. A
  source-anchored assertion closes the loop: the flat literal is gone and
  the exact `changeset_errors(cs)` call now sits in `create_token/2`'s
  changeset arm.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content.Document
  alias Barkpark.LabelFixtures
  alias Barkpark.{Repo, Tenancy}

  @ingest_token "barkpark-test-ingest-token"
  @ingest_path "/v1/plugins/bulldocs/papers"

  # Pre-insert a "paper" document row that the ingest write's own tenancy
  # resolution will collide with: same doc_id/type, and the SAME dataset_id
  # `Content.upsert_paper/1` resolves for an unscoped write (Default
  # project's "production" dataset) — but a workspace_id that the write's
  # pre-check (`get_existing_paper_for_write/3`, scoped to the Default
  # workspace) will never match, so the write takes the INSERT branch and
  # trips the unique index instead of updating in place.
  defp seed_conflicting_paper!(slug) do
    project = Tenancy.get_default_project()
    {:ok, dataset} = Tenancy.get_or_create_dataset(project.id, "production")

    %Document{}
    |> Document.changeset(%{
      "doc_id" => slug,
      "type" => "paper",
      "dataset" => "production",
      "dataset_id" => dataset.id,
      "status" => "published",
      "content" => %{},
      "rev" => "1"
    })
    |> Repo.insert!()
  end

  defp ingest_conn(conn, payload) do
    conn
    |> put_req_header("authorization", "Bearer " <> @ingest_token)
    |> put_req_header("content-type", "application/json")
    |> post(@ingest_path, payload)
  end

  describe "bulldocs ingest — invalid_paper surfaces field detail (additive)" do
    test "a doc_id collision on the html leg returns 422 invalid_paper with details.doc_id",
         %{conn: conn} do
      slug = "changeset-detail-html-#{System.unique_integer([:positive])}"
      seed_conflicting_paper!(slug)

      payload =
        LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "event_type" => "plan-written",
          "body_html" => ~s(<article><h1>#{slug}</h1></article>)
        })

      resp = ingest_conn(conn, payload) |> json_response(422)

      # The LOCKED external contract stays byte-identical...
      assert resp["error"]["code"] == "invalid_paper"
      assert resp["error"]["message"] == "could not store paper"
      # ...with the failing field additively surfaced.
      assert %{"doc_id" => [_ | _]} = resp["error"]["details"]
    end

    test "a doc_id collision on the blocks leg returns the same shape (shared helper)",
         %{conn: conn} do
      slug = "changeset-detail-blocks-#{System.unique_integer([:positive])}"
      seed_conflicting_paper!(slug)

      payload =
        LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "event_type" => "plan-written",
          "blocks" => [
            %{
              "id" => "b1",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "hi"}]
            }
          ]
        })

      resp = ingest_conn(conn, payload) |> json_response(422)

      assert resp["error"]["code"] == "invalid_paper"
      assert resp["error"]["message"] == "could not store paper"
      assert %{"doc_id" => [_ | _]} = resp["error"]["details"]
    end
  end

  describe "auth token-mint — changeset field detail (additive)" do
    test "a real token_hash unique_constraint changeset error carries the field — the shape changeset_errors/1 traverses" do
      # `create_personal_access_token/3`'s ONLY validated ApiToken constraint
      # (ApiToken.changeset/2: validate_required([:token_hash]) +
      # unique_constraint(:token_hash)) is what turns its `Repo.insert` into
      # `{:error, %Ecto.Changeset{}}` in production — on the (vanishingly
      # rare, but real) occasion of a token_hash collision. Reproduced here
      # directly against the SAME schema/changeset (not the RNG-driven mint
      # wrapper, which can't be made to collide deterministically) to prove
      # the mechanism create_token/2's clause handles is real, not
      # hypothetical, and that it carries genuine field detail.
      hash = ApiToken.hash_token("dup-" <> Ecto.UUID.generate())

      assert {:ok, _first} =
               %ApiToken{}
               |> ApiToken.changeset(%{token_hash: hash, name: "first"})
               |> Repo.insert()

      assert {:error, %Ecto.Changeset{} = cs} =
               %ApiToken{}
               |> ApiToken.changeset(%{token_hash: hash, name: "second"})
               |> Repo.insert()

      details =
        Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
          Enum.reduce(opts, msg, fn {k, v}, acc ->
            String.replace(acc, "%{#{k}}", to_string(v))
          end)
        end)

      assert %{token_hash: [_ | _]} = details
    end

    test "create_token/2's changeset clause calls changeset_errors(cs), not a flat literal" do
      source =
        Path.join(File.cwd!(), "lib/barkpark_web/controllers/auth_controller.ex")
        |> File.read!()

      refute source =~ "\"could not mint token\""

      assert source =~
               "{:error, %Ecto.Changeset{} = cs} ->\n        error(conn, 422, \"unprocessable\", changeset_errors(cs))"
    end
  end
end
