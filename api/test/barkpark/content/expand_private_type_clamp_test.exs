defmodule Barkpark.Content.ExpandPrivateTypeClampTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.{CallerContext, Envelope, Expand}

  @ds "expvis"

  # The gap this file pins: `?expand=` crosses from a PUBLIC requested type into
  # a PRIVATE referenced type. The route gate (`query_controller.ex:23-24` /
  # `:407-408`) only ever tests the REQUESTED type, and `Envelope.render/3`
  # redacts on PER-FIELD attributes (`envelope.ex:325-334`) — it never reads the
  # schema's TOP-LEVEL visibility. So a private schema whose fields carry no
  # `private` flag rendered IN FULL through the expansion.
  #
  # `expand_test.exs:256` pins the ADJACENT case (a private FIELD on an expanded
  # ref) but declares its referenced schema `"visibility" => "public"` (:264) —
  # every schema in that file is public, so the private-TYPE case was unpinned
  # and the suite stayed green over the gap.
  #
  # The shipped pairing is real: `seeds/demo.ex:30-33` makes `post` public and
  # `:53-56` gives it `featuredAsset` -> refType `mediaAsset`, which is private.

  setup do
    # PUBLIC requested type, carrying one reference to a PRIVATE type and one to
    # a PUBLIC type. The second reference is the over-clamp control: if the fix
    # simply broke expansion, `author` would stop resolving too.
    Content.upsert_schema(
      %{
        "name" => "article",
        "title" => "Article",
        "visibility" => "public",
        "fields" => [
          %{"name" => "title", "type" => "string"},
          %{"name" => "asset", "type" => "reference", "refType" => "vault"},
          %{"name" => "author", "type" => "reference", "refType" => "byline"}
        ]
      },
      @ds
    )

    # PRIVATE type. NOTE: not one field is individually flagged `private` — that
    # is the whole point. Envelope.render has nothing to redact, so before the
    # clamp the entire body rendered.
    Content.upsert_schema(
      %{
        "name" => "vault",
        "title" => "Vault",
        "visibility" => "private",
        "fields" => [
          %{"name" => "title", "type" => "string"},
          %{"name" => "url", "type" => "string"}
        ]
      },
      @ds
    )

    Content.upsert_schema(
      %{
        "name" => "byline",
        "title" => "Byline",
        "visibility" => "public",
        "fields" => [%{"name" => "title", "type" => "string"}]
      },
      @ds
    )

    {:ok, _} =
      Content.create_document(
        "vault",
        %{"_id" => "v1", "title" => "Private Asset", "url" => "https://cdn.example/secret.png"},
        @ds
      )

    {:ok, _} = Content.publish_document("v1", "vault", @ds)

    {:ok, _} = Content.create_document("byline", %{"_id" => "b1", "title" => "Jane"}, @ds)
    {:ok, _} = Content.publish_document("b1", "byline", @ds)

    {:ok, _} =
      Content.create_document(
        "article",
        %{"_id" => "art1", "title" => "Public Post", "asset" => "v1", "author" => "b1"},
        @ds
      )

    {:ok, _} = Content.publish_document("art1", "article", @ds)

    :ok
  end

  # An anonymous caller reaching the query route: `AnonPerspective.anon_pinned?`
  # is true there, so `published_only: true` — the exact opts the controller
  # builds at query_controller.ex:112 / :466.
  defp expand_as(ctx) do
    [doc] =
      Content.list_documents("article", @ds, perspective: :published)
      |> Enum.map(&Envelope.render/1)
      |> Expand.expand(:all, @ds, published_only: true, caller_context: ctx)

    doc
  end

  defp public_read_ctx,
    do: CallerContext.from_token(%{id: "tok-pr", permissions: ["public-read", "read"]})

  defp read_token_ctx, do: CallerContext.from_token(%{id: "tok-rw", permissions: ["read"]})

  describe "the private-TYPE expansion door" do
    test "anonymous ?expand= does NOT hydrate a reference into a private-visibility type" do
      doc = expand_as(CallerContext.anonymous())

      # The reference is left as its raw id — the same shape `published_only`
      # already produces for an unresolvable ref, so no new response shape.
      assert doc["asset"] == "v1",
             "anonymous expand hydrated a PRIVATE-visibility type: #{inspect(doc["asset"])}"

      refute is_map(doc["asset"])
    end

    test "a public-read token is clamped exactly like an anonymous caller" do
      doc = expand_as(public_read_ctx())

      assert doc["asset"] == "v1",
             "public-read expand hydrated a PRIVATE-visibility type: #{inspect(doc["asset"])}"
    end

    test "OVER-CLAMP CONTROL: the same expansion still resolves a PUBLIC ref anonymously" do
      doc = expand_as(CallerContext.anonymous())

      assert is_map(doc["author"]), "the clamp broke expansion outright"
      assert doc["author"]["_id"] == "b1"
      assert doc["author"]["title"] == "Jane"
    end

    test "OVER-CLAMP CONTROL: an authenticated read token still gets the private ref" do
      doc = expand_as(read_token_ctx())

      assert is_map(doc["asset"]), "the clamp over-reached onto an authenticated caller"
      assert doc["asset"]["_id"] == "v1"
      assert doc["asset"]["title"] == "Private Asset"
      assert doc["asset"]["url"] == "https://cdn.example/secret.png"
      assert is_map(doc["author"])
    end
  end

  # The seat itself, not just the door: `Expand`, the Indx retriever
  # (task-2b6aa2ae3fc3962f) and the task-expectation hydration all route through
  # these two functions. Pinning them here is what makes the fix a seat fix.
  describe "the shared seat: get_documents_by_ids/3 + count_documents_by_ids/3" do
    test "get_documents_by_ids/3 withholds a private-type row from an unauthenticated caller" do
      anon = [caller_context: CallerContext.anonymous()]

      assert Content.get_documents_by_ids(["v1"], @ds, anon) == %{}
      assert %{"b1" => %{doc_id: "b1"}} = Content.get_documents_by_ids(["b1"], @ds, anon)

      authed = [caller_context: read_token_ctx()]
      assert %{"v1" => %{doc_id: "v1"}} = Content.get_documents_by_ids(["v1"], @ds, authed)
    end

    # A count that includes private rows leaks their EXISTENCE even when the
    # bodies are withheld — the same shape a sibling lane proved live in search,
    # where documents were withheld while the type facet still named the private
    # type. Bodies and counts have to be clamped in the SAME seat.
    test "count_documents_by_ids/3 does not count a private-type row for an anonymous caller" do
      anon = [caller_context: CallerContext.anonymous()]

      assert Content.count_documents_by_ids(["v1"], @ds, anon) == 0
      assert Content.count_documents_by_ids(["v1", "b1"], @ds, anon) == 1

      authed = [caller_context: read_token_ctx()]
      assert Content.count_documents_by_ids(["v1", "b1"], @ds, authed) == 2
    end

    # Totality: a malformed id must be a DENIAL, never a crash oracle. A raise
    # is a 500, and a 500 that only fires for some inputs is itself a probe.
    test "a malformed doc_id is a denial, not a raise" do
      anon = [caller_context: CallerContext.anonymous()]

      assert Content.get_documents_by_ids(["../../etc/passwd", ""], @ds, anon) == %{}
      assert Content.count_documents_by_ids(["../../etc/passwd", ""], @ds, anon) == 0
      assert Content.get_documents_by_ids([], @ds, anon) == %{}
      assert Content.count_documents_by_ids([], @ds, anon) == 0
    end
  end
end
