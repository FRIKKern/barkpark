defmodule Barkpark.Media.Delivery.AssetResponseRedactionTest do
  @moduledoc """
  WS-B HIGH-2: the embedded `mediaAsset` document in a media asset response
  formerly rendered with a NIL caller (full content). It must now ride the
  Envelope redaction boundary so a private field never leaks to a non-authorized
  caller — and, with the fail-closed nil/anonymous default, a conn-less
  (anonymous) media read REDACTS rather than dumps.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Crypto.FieldCipher
  alias Barkpark.Media.Delivery.AssetResponse
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  @dataset "production"

  setup do
    enc = FieldCipher.encrypt("secret-caption", "dataset:#{@dataset}")

    {:ok, doc} =
      Content.create_document(
        "mediaAsset",
        %{
          "doc_id" => "wsb-asset-#{System.unique_integer([:positive])}",
          "title" => "Asset",
          "content" => %{"caption" => "public caption", "secret" => enc}
        },
        @dataset
      )

    name = "wsb-#{System.unique_integer([:positive])}.png"

    file =
      %MediaFile{}
      |> MediaFile.changeset(%{
        filename: name,
        original_name: name,
        path: "uploads/wsb/#{name}",
        mime_type: "image/png",
        size: 3,
        dataset: @dataset
      })
      |> Repo.insert!()

    %{media_file: file, doc: doc, enc: enc}
  end

  # A conn carrying an admin token — CallerContext.from_conn reads assigns.api_token.
  defp admin_conn do
    %Plug.Conn{assigns: %{api_token: %{id: "tok-admin", permissions: ["admin"]}}}
  end

  test "anonymous (conn-less) media read redacts a private mediaAsset field", %{
    media_file: file,
    doc: doc
  } do
    payload = AssetResponse.render(file, doc, dataset: @dataset)
    asset = payload.asset

    assert is_map(asset)
    # The encrypted/private field is DROPPED for the anonymous caller.
    refute Map.has_key?(asset, "secret")
    # Public content survives.
    assert asset["caption"] == "public caption"
  end

  test "admin conn sees the (undecrypted) private mediaAsset field", %{
    media_file: file,
    doc: doc,
    enc: enc
  } do
    payload = AssetResponse.render(file, doc, dataset: @dataset, conn: admin_conn())
    assert payload.asset["secret"] == enc
    assert payload.asset["caption"] == "public caption"
  end
end
