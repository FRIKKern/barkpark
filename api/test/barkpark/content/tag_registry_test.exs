defmodule Barkpark.Content.TagRegistryTest do
  @moduledoc """
  The tag registry (authoring-excellence D3/D12) and its E3 publish gate:

    * core `tag` schema registration — fail-loud, idempotent, structurally
      OUTSIDE SchemaBootstrap's defensive rescue;
    * publish wall E3 — weighted `tags[].tag` must resolve to PUBLISHED
      `type:tag` docs; unknown names are a 422 `unknown_tag` with trgm-nearest
      suggestions, proven over real HTTP end-to-end (reject → register via the
      API → re-publish succeeds);
    * `unknown_tag` as a DELIBERATE member of `Errors.known_codes/0`
      (D5 amended — the OpenAPI drift guard alone is a tautology);
    * the legacy flat-tag seed: DRAFT tag docs only, never auto-published.
  """

  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Content.{Document, Errors, SchemaDefinition, TagRegistry}
  alias Barkpark.Repo

  @dataset "test"

  setup do
    Barkpark.Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset
      )

    TagRegistry.register!(@dataset)
    :ok
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> put_req_header("content-type", "application/json")
  end

  defp mutate(conn, mutations) do
    conn
    |> authed()
    |> post("/v1/data/mutate/#{@dataset}", Jason.encode!(%{"mutations" => mutations}))
  end

  # Register a tag the canonical way: publish a type:tag doc whose _id is the
  # tag name.
  defp register_tag!(name) do
    {:ok, _} = Content.create_document("tag", %{"doc_id" => name, "title" => name}, @dataset, [])
    {:ok, _} = Content.publish_document(name, "tag", @dataset, [])
    name
  end

  defp create_post_draft!(doc_id, content) do
    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        []
      )

    doc_id
  end

  defp weighted(tag, strength) do
    %{"tag" => tag, "strength" => strength, "rationale" => "why #{tag} matters here"}
  end

  # ── core schema registration (charter D12) ────────────────────────────────

  describe "core tag schema registration" do
    test "register!/1 registers the tag schema and is idempotent across a double run" do
      dataset = "tagreg-idem"

      first = TagRegistry.register!(dataset)
      second = TagRegistry.register!(dataset)

      # Same row updated, never a duplicate — upsert_schema is idempotent on
      # (name, dataset), so running the registration every boot is safe.
      assert first.name == "tag"
      assert second.id == first.id

      count =
        Repo.aggregate(
          from(s in SchemaDefinition, where: s.name == "tag" and s.dataset == ^dataset),
          :count
        )

      assert count == 1
      assert {:ok, %SchemaDefinition{name: "tag"}} = Content.get_schema("tag", dataset)
    end

    test "register_attrs!/2 RAISES on a failed upsert — boot fails closed, never log-and-swallow" do
      assert_raise RuntimeError, ~r/fails CLOSED/, fn ->
        TagRegistry.register_attrs!(%{"name" => "tag", "fields" => "not-a-list"}, @dataset)
      end
    end

    # Structural pin for the D12 placement: SchemaBootstrap.init/1 wraps its
    # whole body in a rescue that logs and returns :ignore — registration
    # placed INSIDE it would have every failure silently swallowed (the
    # epic-promise failure mode). Pinning source order keeps a future refactor
    # from drifting the call back under the swallow without tripping a test.
    test "SchemaBootstrap registers the core tag schema BEFORE its defensive try/rescue" do
      src = File.read!("lib/barkpark/schema_bootstrap.ex")

      {reg_pos, _} = :binary.match(src, "TagRegistry.register!")
      {try_pos, _} = :binary.match(src, "try do")

      assert reg_pos < try_pos,
             "core tag registration must sit OUTSIDE (before) init/1's rescue — " <>
               "a rescue-swallowed failure boots a publish wall that can never resolve a tag"
    end

    test "SchemaBootstrap has no five-second init deadline" do
      src = File.read!("lib/barkpark/schema_bootstrap.ex")

      assert src =~ "GenServer.start_link(__MODULE__, :ok, timeout: :infinity)",
             "synchronous production schema registration may exceed GenServer's default " <>
               "five-second init timeout; timing it out kills the whole application boot"
    end

    test "registration never routes via Plugins.Bootstrap.register_all_schemas (empty plugins-off)" do
      src = File.read!("lib/barkpark/content/tag_registry.ex")

      refute src =~ "Bootstrap.register_all_schemas()",
             "TagRegistry must upsert directly — Plugins.Bootstrap walks Registry.all(), " <>
               "which is EMPTY under :plugins []"
    end
  end

  # ── E3 publish gate ────────────────────────────────────────────────────────

  describe "E3 gate: weighted tags must resolve to PUBLISHED tag docs" do
    test "unknown-tag publish is 422 unknown_tag with trgm-nearest suggestions for a misspelling",
         %{conn: conn} do
      register_tag!("machine-learning")
      register_tag!("postgres-tuning")
      register_tag!("elixir")

      doc_id = create_post_draft!("post-misspelt", %{"tags" => [weighted("machine-lerning", 60)]})

      resp = mutate(conn, [%{"publish" => %{"id" => doc_id, "type" => "post"}}])
      body = json_response(resp, 422)

      assert body["error"]["code"] == "unknown_tag"
      assert body["error"]["details"]["unknown"] == ["machine-lerning"]

      # Suggestion QUALITY: the misspelling's nearest registered tag is the
      # correction, ranked first.
      assert ["machine-learning" | _] = body["error"]["details"]["suggestions"]["machine-lerning"]

      # The envelope teaches the retry — hint present, names in the message.
      assert is_binary(body["error"]["hint"])
      assert body["error"]["message"] =~ "machine-lerning"
    end

    test "an unrelated unknown tag yields an EMPTY suggestion list, never a misleading one",
         %{conn: conn} do
      register_tag!("elixir")

      doc_id = create_post_draft!("post-unrelated", %{"tags" => [weighted("zzqx-9-vvv", 40)]})

      resp = mutate(conn, [%{"publish" => %{"id" => doc_id, "type" => "post"}}])
      body = json_response(resp, 422)

      assert body["error"]["code"] == "unknown_tag"
      assert body["error"]["details"]["suggestions"]["zzqx-9-vvv"] == []
    end

    test "a DRAFT tag doc does not register — the registry is published-only" do
      # A drafted-but-unpublished tag (exactly what the legacy seed produces)
      # must NOT open the wall: registration is the deliberate publish.
      {:ok, _} =
        Content.create_document(
          "tag",
          %{"doc_id" => "draft-only", "title" => "draft-only"},
          @dataset,
          []
        )

      doc_id = create_post_draft!("post-drafttag", %{"tags" => [weighted("draft-only", 55)]})

      assert {:error, {:unknown_tag, payload}} =
               Content.publish_document(doc_id, "post", @dataset, [])

      assert payload.unknown == ["draft-only"]
    end

    test "register over the API, then re-publish succeeds — the one-retry loop end-to-end over HTTP",
         %{conn: conn} do
      doc_id = create_post_draft!("post-retry", %{"tags" => [weighted("growth", 70)]})

      # 1. Publish rejected: `growth` is not registered.
      resp = mutate(conn, [%{"publish" => %{"id" => doc_id, "type" => "post"}}])
      assert json_response(resp, 422)["error"]["code"] == "unknown_tag"

      # 2. Register the tag THROUGH the public API: create + publish a
      #    type:tag doc — the canonical, audited registration act.
      resp =
        mutate(conn, [
          %{"create" => %{"_id" => "growth", "_type" => "tag", "title" => "growth"}},
          %{"publish" => %{"id" => "growth", "type" => "tag"}}
        ])

      assert json_response(resp, 200)

      # 3. Same publish again — now it clears the wall.
      resp = mutate(conn, [%{"publish" => %{"id" => doc_id, "type" => "post"}}])
      assert %{"results" => _} = json_response(resp, 200)
    end

    test "docs without weighted tags pass E3 untouched (unlabeled + legacy flat strings)" do
      # E3 gates REGISTRATION of the weighted shape only. Unlabeled documents
      # and legacy flat-string tags are the label-spine/exemption gates'
      # business (S1/S2 of this wave) — E3 must not double-claim them.
      unlabeled = create_post_draft!("post-unlabeled", %{})
      assert {:ok, _} = Content.publish_document(unlabeled, "post", @dataset, [])

      legacy =
        create_post_draft!("post-legacy-flat", %{"tags" => ["old-style", "never-registered"]})

      assert {:ok, _} = Content.publish_document(legacy, "post", @dataset, [])
    end
  end

  # ── error contract (charter D5, amended) ──────────────────────────────────

  describe "unknown_tag error contract" do
    # D5 amended: the OpenAPI drift guard derives from @hints, so it is a
    # tautology — a build clause without a @hints entry is invisible to the
    # spec AND to the guard (live proof: duplicate_task). Every new code
    # therefore ships THIS deliberate membership test.
    test "unknown_tag is a deliberate member of Errors.known_codes/0" do
      assert MapSet.member?(Errors.known_codes(), "unknown_tag")
    end

    test "envelope: 422, unknown names in message, unknown+suggestions in details, hint present" do
      env =
        Errors.to_envelope(
          {:error,
           {:unknown_tag, %{unknown: ["mispelt"], suggestions: %{"mispelt" => ["misspelt"]}}}}
        )

      assert env.status == 422
      assert env.code == "unknown_tag"
      assert env.message =~ "mispelt"
      assert env.details == %{unknown: ["mispelt"], suggestions: %{"mispelt" => ["misspelt"]}}
      assert is_binary(env.hint)
    end
  end

  # ── legacy vocabulary seed ─────────────────────────────────────────────────

  describe "seed_legacy_drafts/2 (mix barkpark.tags.seed)" do
    test "imports distinct tag names from BOTH shapes as DRAFTS, never publishes, idempotent" do
      create_post_draft!("legacy-a", %{"tags" => ["alpha", "beta"]})
      create_post_draft!("legacy-b", %{"tags" => ["beta", "gamma"]})
      # Dual-shape read (D19): a weighted doc's tag NAME is drafted for
      # curation too — the seeder is the third consumer of
      # search_tags_for_type and benefits transitively.
      create_post_draft!("modern-doc", %{"tags" => [weighted("modern", 80)]})

      %{created: created} = TagRegistry.seed_legacy_drafts(@dataset)

      assert Enum.sort(created) == ["alpha", "beta", "gamma", "modern"]

      for name <- ["alpha", "beta", "gamma", "modern"] do
        # Draft variant exists…
        assert %Document{status: "draft"} =
                 Repo.one(
                   from(d in Document,
                     where:
                       d.type == "tag" and d.dataset == ^@dataset and
                         d.doc_id == ^("drafts." <> name)
                   )
                 )

        # …and NO published variant does: nothing is auto-registered.
        refute Repo.exists?(
                 from(d in Document,
                   where: d.type == "tag" and d.dataset == ^@dataset and d.doc_id == ^name
                 )
               )
      end

      # The weighted entry became a DRAFT by NAME only — its JSON-object
      # text never leaks in as a doc id (dual-shape names, not blobs).
      refute Repo.exists?(
               from(d in Document,
                 where:
                   d.type == "tag" and d.dataset == ^@dataset and
                     ilike(d.doc_id, "%{%")
               )
             )

      # Idempotent: a second sweep creates nothing and skips the vocabulary.
      assert %{created: [], skipped: skipped} = TagRegistry.seed_legacy_drafts(@dataset)
      assert Enum.sort(skipped) == ["alpha", "beta", "gamma", "modern"]
    end
  end
end
