defmodule BarkparkWeb.MediaDeletedWebhookWitnessTest do
  @moduledoc """
  The `media.deleted` WEBHOOK must carry the forced-delete witness
  (task-303e3b171435d767).

  PR #16203 gave a forced delete two witnesses and stopped one short. The
  WARNING log serves an operator reading `make logs` on the box; the 200 receipt
  serves the caller who made the request. The webhook serves a THIRD audience
  that has neither — a link-graph rebuilder, a search reindexer, a downstream
  cache. That consumer was not present for the request, cannot read the box's
  logs, sees a delete it must apply, and had no way to learn the delete was
  contested. A link-graph rebuilder in particular is exactly the system that
  would want to flag the now-broken references rather than silently drop them.

  Two doors, because the census is computed at the DOOR and threaded down — a
  fix that lands on one is exactly the failure this file exists to catch:

    * `DELETE /v1/media/:dataset/:id`  V1.MediaController.delete/2
    * `DELETE /media/:id`              MediaController.delete/2

  THE ABSENCE ARMS ARE LOAD-BEARING. A `forced` field present on every payload
  is indistinguishable from noise, so each door also proves an UNFORCED delete
  of an UNREFERENCED blob dispatches a payload with NO override fields at all.
  Without them, `Map.put(payload, :forced, true)` unconditionally would pass
  every presence arm.

  The fixture plants TWO referring documents on purpose: `referencedByCount`
  must carry the CENSUS, and a hard-coded `1` (or a boolean widened into an
  integer) would satisfy a single-referrer arm.

  `async: false` + a per-test Bypass: dispatch fans out through
  `Task.Supervisor` onto a real HTTP endpoint, and `:media_webhooks` is
  application-global. Every arm is keyed to THIS test's own `media_file_id`, so
  another test's delivery into the shared capture cannot satisfy — or falsify —
  an arm here.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content.Document
  alias Barkpark.Media
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  @admin "media-deleted-webhook-admin"
  @dataset "production"

  # Every key `media.deleted` carried BEFORE this change. Consumers branch on
  # these, so the new fields must be purely ADDITIVE — nothing renamed, nothing
  # dropped, nothing re-typed.
  @baseline_keys ~w(
    event dataset media_file_id asset_doc_id mime_type filename original_name
    paths cdn_urls sync_tags timestamp
  )

  # 1x1 transparent PNG, inline (mirrors media_delete_force_witness_test.exs).
  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  setup do
    {:ok, _} = Auth.create_token(@admin, "deleted-webhook", "test", ["read", "write", "admin"])

    prev = Application.get_env(:barkpark, :media_webhooks)
    bypass = Bypass.open()
    test = self()

    Bypass.expect(bypass, "POST", "/hook", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:media_webhook, Jason.decode!(body)})
      Plug.Conn.resp(conn, 200, "")
    end)

    Application.put_env(:barkpark, :media_webhooks,
      endpoints: [
        %{
          url: "http://127.0.0.1:#{bypass.port}/hook",
          secret: "hook-secret",
          events: ["media.deleted"]
        }
      ]
    )

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :media_webhooks, prev),
        else: Application.delete_env(:barkpark, :media_webhooks)
    end)

    :ok
  end

  describe "DELETE /v1/media/:dataset/:id" do
    test "a FORCED delete of a referenced blob dispatches forced + the census count" do
      file = media_file!()
      _docs = papers_referencing!(file, 2)

      receipt =
        admin(scoped_conn())
        |> delete("/v1/media/#{@dataset}/#{file.id}?force=true")
        |> json_response(200)

      payload = webhook_for!(file)

      assert payload["event"] == "media.deleted"

      assert payload["forced"] == true,
             "the media.deleted payload still cannot tell a contested delete from " <>
               "an uncontested one: #{inspect(payload)}"

      assert payload["referencedByCount"] == 2,
             "the payload carried no census, or a count that is not the census " <>
               "(2 documents reference this blob): #{inspect(payload)}"

      # ONE census, one number. The receipt and the webhook describe the same
      # forced delete, so a consumer reconciling the two must not see a drift.
      assert payload["referencedByCount"] == receipt["result"]["referencedByCount"]

      # ADDITIVE: everything the payload carried before is still there.
      for key <- @baseline_keys do
        assert Map.has_key?(payload, key),
               "the forced payload DROPPED the pre-existing key #{key}, and " <>
                 "consumers branch on it: #{inspect(Map.keys(payload))}"
      end
    end

    test "an UNFORCED delete of an UNREFERENCED blob dispatches NO override fields" do
      file = media_file!()

      admin(scoped_conn())
      |> delete("/v1/media/#{@dataset}/#{file.id}")
      |> json_response(200)

      payload = webhook_for!(file)

      refute Map.has_key?(payload, "forced"),
             "every delete now looks contested, so `forced` carries no signal: " <>
               inspect(payload)

      refute Map.has_key?(payload, "referencedByCount"),
             "an ordinary delete grew the census field: #{inspect(payload)}"
    end
  end

  describe "DELETE /media/:id (legacy twin)" do
    test "a FORCED delete of a referenced blob dispatches forced + the census count" do
      file = media_file!()
      _docs = papers_referencing!(file, 2)

      receipt =
        admin(scoped_conn())
        |> delete("/media/#{file.id}?force=true")
        |> json_response(200)

      payload = webhook_for!(file)

      assert payload["forced"] == true,
             "the legacy door threads no witness into the webhook: #{inspect(payload)}"

      assert payload["referencedByCount"] == 2
      assert payload["referencedByCount"] == receipt["referencedByCount"]
    end

    test "an UNFORCED delete of an UNREFERENCED blob dispatches NO override fields" do
      file = media_file!()

      admin(scoped_conn()) |> delete("/media/#{file.id}") |> json_response(200)

      payload = webhook_for!(file)

      refute Map.has_key?(payload, "forced"),
             "the legacy door marks ordinary deletes contested: #{inspect(payload)}"

      refute Map.has_key?(payload, "referencedByCount")
    end
  end

  describe "the shape is ADDITIVE" do
    # The two payloads are compared to EACH OTHER rather than to a hand-written
    # list, so a field renamed or dropped on the forced path — the one shape no
    # single-payload arm above would notice — reds here.
    test "a forced payload is an unforced payload plus exactly the two new keys" do
      plain = media_file!()
      admin(scoped_conn()) |> delete("/media/#{plain.id}") |> json_response(200)
      unforced = webhook_for!(plain)

      contested = media_file!()
      papers_referencing!(contested, 2)
      admin(scoped_conn()) |> delete("/media/#{contested.id}?force=true") |> json_response(200)
      forced = webhook_for!(contested)

      assert Enum.sort(Map.keys(forced) -- Map.keys(unforced)) ==
               ["forced", "referencedByCount"]

      assert Map.keys(unforced) -- Map.keys(forced) == [],
             "the forced path LOST a key the ordinary payload carries"
    end
  end

  # ── the webhook reader ──────────────────────────────────────────────────────

  # Keyed to THIS blob's id: the mailbox is per-test, but the endpoint is
  # application-global, so a delivery for another file must not be mistaken for
  # this one's — nor allowed to satisfy an absence arm.
  defp webhook_for!(%MediaFile{id: id}) do
    receive do
      {:media_webhook, %{"media_file_id" => ^id} = payload} -> payload
    after
      5_000 -> flunk("no media.deleted webhook delivered for media_file_id=#{id}")
    end
  end

  # ── fixtures (mirrors media_delete_force_witness_test.exs) ──────────────────

  defp admin(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @admin)
    |> put_req_header("content-type", "application/json")
  end

  defp media_file! do
    tmp = Path.join(System.tmp_dir!(), "deleted-hook-#{System.unique_integer([:positive])}.png")
    File.write!(tmp, Base.decode64!(@png_b64))
    upload = %Plug.Upload{path: tmp, filename: "cast.png", content_type: "image/png"}

    created =
      admin(scoped_conn())
      |> post("/media/upload", %{"file" => upload})
      |> json_response(201)

    # The sandbox rolls the row back; the BYTES on disk outlive the test.
    on_exit(fn -> File.rm(Path.join(Media.upload_dir(), created["path"])) end)

    Repo.get!(MediaFile, created["id"])
  end

  # TWO referrers by default: `referencedByCount` must be the census, and 1 is
  # the one number a boolean-shaped bug could produce by accident.
  defp papers_referencing!(%MediaFile{} = file, n) do
    for _ <- 1..n do
      Repo.insert!(%Document{
        doc_id: "deleted-hook-paper-#{System.unique_integer([:positive])}",
        type: "paper",
        dataset: @dataset,
        title: "Deleted-webhook witness fixture",
        status: "published",
        rev: "rev-#{System.unique_integer([:positive])}",
        content: %{
          "blocks" => [
            %{"type" => "image", "src" => "/media/files/#{file.path}", "alt" => "the cast"}
          ]
        }
      })
    end
  end
end
