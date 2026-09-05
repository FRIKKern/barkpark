defmodule BarkparkWeb.ExportControllerTest do
  @moduledoc """
  Export field-visibility leak-guard (Phase 3, core-auth).

  `GET /v1/data/export/:dataset` streams NDJSON through the SAME
  `Envelope.render/3` chokepoint as every other read. A non-admin token must
  never receive a `private` / `visibility:"private"` field; an admin token does;
  a schema with no privacy metadata is byte-identical for both (additive /
  opt-in invariant). Per-type schema resolution must redact a multi-type export
  correctly.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Crypto.FieldCipher

  @dataset "exptest"

  setup do
    Auth.create_token("exp-admin-token", "admin", @dataset, ["read", "write", "admin"])
    Auth.create_token("exp-reader-token", "reader", @dataset, ["read"])

    Content.upsert_schema(
      %{
        "name" => "secret",
        "title" => "Secret",
        "visibility" => "public",
        "fields" => [
          %{"name" => "body", "type" => "string"},
          %{"name" => "ssn", "type" => "string", "private" => true}
        ]
      },
      @dataset
    )

    Content.upsert_schema(
      %{
        "name" => "post",
        "title" => "Post",
        "visibility" => "public",
        "fields" => [%{"name" => "secret_note", "type" => "string", "visibility" => "private"}]
      },
      @dataset
    )

    {:ok, _} =
      Content.create_document(
        "secret",
        %{
          "doc_id" => "drafts.s1",
          "title" => "S1",
          "content" => %{"body" => "ok", "ssn" => "123-45-6789"}
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "drafts.p1", "title" => "P1", "content" => %{"secret_note" => "hush"}},
        @dataset
      )

    :ok
  end

  defp raw_export(token) do
    resp =
      scoped_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/v1/data/export/#{@dataset}")

    assert resp.status == 200
    resp.resp_body
  end

  defp export_docs(token) do
    raw_export(token)
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  test "non-admin export drops private + visibility:private fields across types; reserved + public kept" do
    docs = export_docs("exp-reader-token")

    secret = Enum.find(docs, &(&1["_id"] == "drafts.s1"))
    assert secret, "expected the secret doc in the export"
    assert secret["body"] == "ok"
    assert secret["_id"] == "drafts.s1"
    refute Map.has_key?(secret, "ssn")

    # Multi-type export: the per-type schema must redact `post` independently.
    post = Enum.find(docs, &(&1["_id"] == "drafts.p1"))
    assert post["title"] == "P1"
    refute Map.has_key?(post, "secret_note")
  end

  test "admin export includes the private fields" do
    docs = export_docs("exp-admin-token")

    secret = Enum.find(docs, &(&1["_id"] == "drafts.s1"))
    assert secret["ssn"] == "123-45-6789"

    post = Enum.find(docs, &(&1["_id"] == "drafts.p1"))
    assert post["secret_note"] == "hush"
  end

  test "schema with NO privacy metadata exports byte-identical for non-admin vs admin" do
    Content.upsert_schema(
      %{
        "name" => "plain",
        "title" => "Plain",
        "visibility" => "public",
        "fields" => [%{"name" => "body", "type" => "string"}]
      },
      @dataset
    )

    {:ok, _} =
      Content.create_document(
        "plain",
        %{"doc_id" => "drafts.pl1", "title" => "PL", "content" => %{"body" => "x"}},
        @dataset
      )

    reader = Enum.find(export_docs("exp-reader-token"), &(&1["_id"] == "drafts.pl1"))
    admin = Enum.find(export_docs("exp-admin-token"), &(&1["_id"] == "drafts.pl1"))

    assert reader == admin
    assert reader["body"] == "x"
  end

  test "encrypted field never exports plaintext to a non-admin (ciphertext-at-rest)" do
    enc = FieldCipher.encrypt("ssn-secret", "dataset:#{@dataset}")

    {:ok, _} =
      Content.create_document(
        "secret",
        %{"doc_id" => "drafts.s2", "title" => "S2", "content" => %{"ssn" => enc, "body" => "ok"}},
        @dataset
      )

    raw = raw_export("exp-reader-token")
    refute raw =~ "ssn-secret"

    d = Enum.find(export_docs("exp-reader-token"), &(&1["_id"] == "drafts.s2"))
    refute Map.has_key?(d, "ssn")
    assert d["body"] == "ok"
  end
end
