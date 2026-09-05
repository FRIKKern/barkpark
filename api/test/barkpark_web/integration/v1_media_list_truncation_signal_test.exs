defmodule BarkparkWeb.Integration.V1MediaListTruncationSignalTest do
  @moduledoc """
  `count` means the GRAND TOTAL on `/v1/media/:ds` and the PAGE ROWS on its
  `/v1/media/:ds/collections` sibling — one noun, two opposite meanings, both
  plausible integers, so a client that guesses wrong mis-pages in silence
  (task-27d5fdba100d2bc6 finding 1, task-3d7a770cf4ea11cd).

  Neither `count` is re-pointed: that would break whichever consumer is right
  today. The ambiguity is closed ADDITIVELY — every /v1/media/* list envelope
  now carries `total` (grand total) and `hasMore` (exact), so no consumer ever
  has to know which `count` convention it just met.

  These assert the SEMANTICS, not the presence. The load-bearing case is the
  last page that happens to be exactly `limit` rows long: `count == limit` there
  too, so anything inferring truncation from it is wrong, and `hasMore` must
  still answer false.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Media
  alias Barkpark.Plugins.Media.Assets

  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  @v1_media_controllers [
    "lib/barkpark_web/controllers/v1/media_controller.ex",
    "lib/barkpark_web/controllers/v1/media_collections_controller.ex"
  ]

  # The keys that make a /v1/media/* envelope a LIST envelope.
  @list_keys ~w(assets hits collections)

  setup do
    Auth.create_token(
      "barkpark-dev-token",
      "dev",
      "v1-media-truncation-signal",
      ["read", "write", "admin"]
    )

    :ok
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer barkpark-dev-token")

  defp png_upload do
    tmp_path = Path.join(System.tmp_dir!(), "trunc-#{System.unique_integer([:positive])}.png")
    File.write!(tmp_path, Base.decode64!(@png_b64))
    %Plug.Upload{path: tmp_path, filename: "pixel.png", content_type: "image/png"}
  end

  defp upload_asset(conn) do
    conn
    |> authed()
    |> post(~p"/v1/media/production/upload", %{"file" => png_upload()})
    |> json_response(201)
  end

  defp cleanup_upload(%{"result" => %{"id" => id, "path" => path}}) do
    File.rm(Path.join(Media.upload_dir(), path))
    Media.Renditions.delete_for_file(id)
    Assets.delete_for_blob(id, "production")
  end

  defp create_collection!(title) do
    id = "trunc-col-#{System.unique_integer([:positive])}"

    {:ok, doc} =
      Content.upsert_document(
        "mediaCollection",
        %{
          "doc_id" => id,
          "title" => title,
          "content" => %{"kind" => "folder", "slug" => id}
        },
        "production",
        source: :api
      )

    doc
  end

  defp cleanup_collection(%Document{doc_id: id}),
    do: Content.delete_document(id, "mediaCollection", "production")

  defp ls(conn, query) do
    conn |> authed() |> get(~p"/v1/media/production?#{query}") |> json_response(200)
  end

  defp collections(conn, query) do
    conn
    |> authed()
    |> get(~p"/v1/media/production/collections?#{query}")
    |> json_response(200)
  end

  describe "GET /v1/media/:dataset (media.ls) — count is the GRAND TOTAL" do
    test "a truncated page reports hasMore true and a total strictly greater than its rows",
         %{conn: conn} do
      uploads = for _ <- 1..3, do: upload_asset(conn)

      try do
        r = ls(conn, %{"limit" => 2, "offset" => 0})["result"]

        # The shipped meaning of `count` on this route, pinned so a later
        # "consistency" change cannot silently re-point it.
        assert r["count"] == r["total"]
        assert r["total"] >= 3
        assert length(r["assets"]) == 2
        assert r["total"] > length(r["assets"])

        assert r["hasMore"] == true
        assert r["nextOffset"] == 2
      after
        Enum.each(uploads, &cleanup_upload/1)
      end
    end

    test "a LAST page that is exactly `limit` rows long still reports hasMore false",
         %{conn: conn} do
      uploads = for _ <- 1..3, do: upload_asset(conn)

      try do
        total = ls(conn, %{"limit" => 1, "offset" => 0})["result"]["total"]
        assert total >= 3

        r = ls(conn, %{"limit" => 2, "offset" => total - 2})["result"]

        # `count == limit` here — the exact shape that makes truncation
        # un-inferable from `count` alone. `hasMore` must still say false.
        assert length(r["assets"]) == 2
        assert r["offset"] + length(r["assets"]) == r["total"]
        assert r["hasMore"] == false
        refute Map.has_key?(r, "nextOffset")
      after
        Enum.each(uploads, &cleanup_upload/1)
      end
    end
  end

  describe "GET /v1/media/:dataset/collections (media.collections) — count is the PAGE ROWS" do
    test "a truncated page reports hasMore true, page-rows count, and a larger total",
         %{conn: conn} do
      cols = for i <- 1..3, do: create_collection!("Trunc #{i}")

      try do
        r = collections(conn, %{"limit" => 2, "offset" => 0})["result"]

        # The shipped meaning of `count` on THIS route — the opposite of its
        # /v1/media/:ds sibling, and equally pinned.
        assert r["count"] == length(r["collections"])
        assert r["count"] == 2
        assert r["total"] >= 3
        assert r["total"] > r["count"]

        assert r["hasMore"] == true
        assert r["nextOffset"] == 2
      after
        Enum.each(cols, &cleanup_collection/1)
      end
    end

    test "a LAST page that is exactly `limit` rows long still reports hasMore false",
         %{conn: conn} do
      cols = for i <- 1..3, do: create_collection!("Trunc last #{i}")

      try do
        total = collections(conn, %{"limit" => 1, "offset" => 0})["result"]["total"]
        assert total >= 3

        r = collections(conn, %{"limit" => 2, "offset" => total - 2})["result"]

        assert r["count"] == 2
        assert r["offset"] + r["count"] == r["total"]
        assert r["hasMore"] == false
        refute Map.has_key?(r, "nextOffset")
      after
        Enum.each(cols, &cleanup_collection/1)
      end
    end

    test "total counts the whole match set, not the page — it is stable across pages",
         %{conn: conn} do
      cols = for i <- 1..3, do: create_collection!("Trunc stable #{i}")

      try do
        page_a = collections(conn, %{"limit" => 1, "offset" => 0})["result"]
        page_b = collections(conn, %{"limit" => 1, "offset" => 1})["result"]

        assert page_a["total"] == page_b["total"]
        # A `total` accidentally derived from the page would equal `count` here.
        assert page_a["count"] == 1
        assert page_a["total"] > page_a["count"]
      after
        Enum.each(cols, &cleanup_collection/1)
      end
    end
  end

  describe "the two count conventions are now reconcilable" do
    test "both routes answer the same question with the same keys", %{conn: conn} do
      uploads = for _ <- 1..3, do: upload_asset(conn)
      cols = for i <- 1..3, do: create_collection!("Trunc recon #{i}")

      try do
        a = ls(conn, %{"limit" => 2, "offset" => 0})["result"]
        b = collections(conn, %{"limit" => 2, "offset" => 0})["result"]

        # `count` still disagrees — deliberately, because re-pointing it is the
        # breaking change this row refused to make.
        assert a["count"] != length(a["assets"])
        assert b["count"] == length(b["collections"])

        # `total` and `hasMore` agree, on both, with no convention to guess.
        for r <- [a, b] do
          assert is_integer(r["total"])
          assert is_boolean(r["hasMore"])
          assert r["hasMore"] == true
        end
      after
        Enum.each(uploads, &cleanup_upload/1)
        Enum.each(cols, &cleanup_collection/1)
      end
    end
  end

  describe "guard: no /v1/media/* list envelope may ship without a truncation signal" do
    test "every list-shaped result map in the v1 media controllers carries total and hasMore" do
      offenders = Enum.flat_map(@v1_media_controllers, &offenders_in/1)

      assert offenders == [],
             """
             A /v1/media/* list envelope shipped without an explicit truncation
             signal. Every result map carrying #{Enum.join(@list_keys, "/")} must
             also carry `total` and `hasMore` — inferring truncation from
             `count == limit` is wrong on an exactly-full last page.

             Offenders:
             #{Enum.join(offenders, "\n")}
             """
    end

    test "the guard is not vacuous: it reads real source and finds the list keys" do
      found =
        Enum.flat_map(@v1_media_controllers, fn rel ->
          rel
          |> resolve_source()
          |> File.read!()
          |> String.split("\n")
          |> Enum.map(&list_key/1)
          |> Enum.reject(&is_nil/1)
        end)

      # If this ever drops to zero the guard above passes while checking nothing.
      assert length(found) >= 5, "guard found only #{length(found)} list envelopes to check"
      assert "assets" in found
      assert "hits" in found
      assert "collections" in found
    end
  end

  defp offenders_in(rel) do
    path = resolve_source(rel)
    lines = path |> File.read!() |> String.split("\n")

    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, idx} ->
      case list_key(line) do
        nil ->
          []

        key ->
          window = lines |> Enum.slice(max(idx - 12, 0), 24) |> Enum.join("\n")

          if String.contains?(window, "total:") and String.contains?(window, "hasMore:") do
            []
          else
            ["#{rel}:#{idx} — `#{key}:` with no total/hasMore in its envelope"]
          end
      end
    end)
  end

  # The suite runs from api/, but be tolerant of the cwd so the guard cannot go
  # vacuously green by reading nothing.
  defp resolve_source(rel) do
    Enum.find([rel, Path.join("api", rel), Path.join(File.cwd!(), rel)], &File.exists?/1) ||
      flunk("guard cannot find #{rel} — it would have passed vacuously")
  end

  defp list_key(line) do
    trimmed = String.trim(line)
    Enum.find(@list_keys, fn k -> String.starts_with?(trimmed, k <> ":") end)
  end
end
