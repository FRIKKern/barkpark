defmodule BarkparkWeb.MutateSearchableTextCapTest do
  @moduledoc """
  Postgres caps ONE tsvector at 1 048 575 bytes. `documents.search_vector` is a
  `GENERATED ALWAYS ... STORED` column over `title` + every string in `content`
  (migration 20260614220000_search_vector_fields), so a write whose searchable
  text exceeds the cap raises `Postgrex.Error` SQLSTATE 54000
  (`:program_limit_exceeded`) from inside the mutate transaction.

  Before task-655f368ae5c72120 nothing rescued it: the exception escaped
  `Content.apply_mutations/3` and the door answered a bare 500 `internal_error`,
  telling the caller to retry a request that fails identically forever.

  THE CAP IS ON THE DERIVED INDEX, NOT THE BODY. `low_entropy_body/0` below is
  LARGER in bytes than `high_entropy_body/0` and indexes fine — one repeated
  word is one lexeme no matter how often it appears. Any test that builds its
  oversize body from repetition proves nothing; the payload has to carry many
  DISTINCT lexemes.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content

  # Postgres' MAXSTRLEN for a single tsvector.
  @tsvector_limit_bytes 1_048_575

  setup do
    Barkpark.Auth.create_token("bp-tsvec-token", "tsvec", "test", ["read", "write", "admin"])

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "test"
    )

    :ok
  end

  describe "searchable text over Postgres' tsvector cap" do
    test "createOrReplace answers a typed 422 naming the limit and the field", %{conn: conn} do
      body = high_entropy_body()

      resp = mutate(conn, "tsvec-over-cap", body)

      # NOT 500. The classification is the whole point of the row.
      assert resp.status == 422

      %{"error" => error} = Jason.decode!(resp.resp_body)

      assert error["code"] == "searchable_text_too_large"

      # The limit is NAMED, in the message and machine-readably in details.
      assert error["details"]["limit_bytes"] == @tsvector_limit_bytes
      assert error["message"] =~ to_string(@tsvector_limit_bytes)

      # The FIELD that overflowed is named, with its document and byte size.
      assert error["details"]["field"] == "/body"
      assert error["details"]["document"] == "tsvec-over-cap"
      assert error["details"]["field_bytes"] == byte_size(body)
      assert error["message"] =~ "/body"

      # The envelope is the canonical one: hint + request_id ride along.
      assert is_binary(error["request_id"])
      assert error["hint"] =~ "searchable text"
    end

    test "nothing is written — the batch rolled back", %{conn: conn} do
      _resp = mutate(conn, "tsvec-rollback", high_entropy_body())

      assert Content.get_document("tsvec-rollback", "post", "test") == {:error, :not_found}
      assert Content.get_document("drafts.tsvec-rollback", "post", "test") == {:error, :not_found}
    end

    # THE CONTROL. A body that is BIGGER in bytes but poor in distinct lexemes
    # stays under the cap and is written normally. Without this arm the test
    # above would also pass on a naive byte-count guard on the request body —
    # a guard that would refuse this perfectly valid write.
    test "a LARGER low-entropy body is accepted (the cap is on lexemes, not bytes)", %{conn: conn} do
      low = low_entropy_body()
      assert byte_size(low) > byte_size(high_entropy_body())

      resp = mutate(conn, "tsvec-low-entropy", low)

      assert resp.status == 200
      assert {:ok, _doc} = Content.get_document("drafts.tsvec-low-entropy", "post", "test")
    end
  end

  # ── payloads ───────────────────────────────────────────────────────────────

  defp mutate(conn, id, body) do
    payload =
      Jason.encode!(%{
        "mutations" => [
          %{
            "createOrReplace" => %{
              "_id" => id,
              "_type" => "post",
              "title" => "searchable text cap",
              "body" => body
            }
          }
        ]
      })

    conn
    |> put_req_header("authorization", "Bearer bp-tsvec-token")
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/test", payload)
  end

  # 100 000 distinct 16-char base32 words — ~1.7 MB of text that lexes to
  # ~2.0 MB of tsvector, comfortably past the 1 048 575-byte cap. Base32 of
  # random bytes is alphanumeric, so the english parser keeps every token as
  # its own lexeme rather than folding them into stopwords or stems.
  defp high_entropy_body do
    Enum.map_join(1..100_000, " ", fn _ ->
      Base.encode32(:crypto.strong_rand_bytes(10), padding: false)
    end)
  end

  # 2 MB of ONE repeated word: a single lexeme, and (position counts saturating
  # at 256 per lexeme) a tsvector of a few dozen bytes.
  defp low_entropy_body do
    String.duplicate("barkpark ", 250_000)
  end
end
