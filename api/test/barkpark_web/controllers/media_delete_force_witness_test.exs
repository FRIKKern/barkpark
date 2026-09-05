defmodule BarkparkWeb.MediaDeleteForceWitnessTest do
  @moduledoc """
  A FORCED media delete must leave a witness (task-ef676cfc88e71fae).

  The where-used guard (pe-w2-bl-media-delete-where-used) refuses a delete that
  would blank a published page, and `?force=true` is its deliberate escape hatch
  — an operator with a genuinely dead reference has to be able to proceed. That
  hatch is not the defect. The defect was that it left NO RECORD: the controllers
  logged nothing, and the 200 receipt was BYTE-IDENTICAL to an unforced delete of
  an unreferenced blob. The guard computed the census that names every referring
  document and then threw it away.

  WHO IS MISLED: whoever investigates the broken image later. WHAT THEY WRONGLY
  CONCLUDE: "this blob was unreferenced when it was deleted."

  Two doors, and a fix that lands on one is exactly the failure this file exists
  to catch:

    * `DELETE /v1/media/:dataset/:id`  V1.MediaController.delete/2
    * `DELETE /media/:id`              MediaController.delete/2

  THE ABSENCE ARMS ARE LOAD-BEARING. A warning that fires on EVERY delete is
  worth nothing to the operator grepping for it, so each door also proves that an
  UNFORCED delete of an UNREFERENCED blob emits no such line and grows no
  `forced` field. Without them a `Logger.warning` at the top of `delete/2` would
  pass the presence arms.

  Every assertion is keyed to THIS test's own blob path (`media_file!/0` mints a
  unique integer into it), so a concurrent async test emitting its own override
  line in the shared capture cannot satisfy — or falsify — an arm here.
  """

  use BarkparkWeb.ConnCase, async: true

  import ExUnit.CaptureLog

  alias Barkpark.Auth
  alias Barkpark.Content.Document
  alias Barkpark.Media
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  @admin "media-force-witness-admin"
  @dataset "production"
  @marker "media force-delete override"

  # 1x1 transparent PNG, inline — no fixture file needed (mirrors media_test.exs).
  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  setup do
    {:ok, _} = Auth.create_token(@admin, "force-witness", "test", ["read", "write", "admin"])
    :ok
  end

  describe "DELETE /v1/media/:dataset/:id?force=true" do
    test "warns with the path, the referrer count, the referring doc_ids and the actor" do
      file = media_file!()
      doc = paper_referencing!(file, @dataset)

      {body, log} =
        with_log(fn ->
          admin(scoped_conn())
          |> delete("/v1/media/#{@dataset}/#{file.id}?force=true")
          |> json_response(200)
        end)

      line = override_line!(log, file)

      assert line =~ "path=/media/files/#{file.path}"
      assert line =~ "referrers=1"

      assert line =~ doc.doc_id,
             "the warning did not NAME the referring document, so the census the " <>
               "guard already computed is still being thrown away: #{line}"

      assert line =~ "actor=force-witness",
             "the warning did not name the ACTOR who overrode the guard: #{line}"

      # The receipt must carry the choice too, so a CLIENT's own log records it
      # without the operator needing server log access.
      assert body["result"]["forced"] == true
      assert body["result"]["referencedByCount"] == 1

      refute Repo.get(MediaFile, file.id), "the escape hatch stopped working"
    end

    test "an UNFORCED delete of an UNREFERENCED blob emits no override warning" do
      file = media_file!()

      {body, log} =
        with_log(fn ->
          admin(scoped_conn())
          |> delete("/v1/media/#{@dataset}/#{file.id}")
          |> json_response(200)
        end)

      assert body["result"]["deleted"] == file.id

      refute override_line(log, file),
             "the override warning fired on an ORDINARY delete, so it is noise " <>
               "an operator will learn to ignore: #{log}"

      refute Map.has_key?(body["result"], "forced"),
             "an unforced receipt grew the override field, so a client cannot " <>
               "tell the two apart either: #{inspect(body["result"])}"
    end
  end

  describe "DELETE /media/:id?force=true (legacy twin)" do
    test "warns with the path, the referrer count, the referring doc_ids and the actor" do
      file = media_file!()
      doc = paper_referencing!(file, @dataset)

      {body, log} =
        with_log(fn ->
          admin(scoped_conn())
          |> delete("/media/#{file.id}?force=true")
          |> json_response(200)
        end)

      line = override_line!(log, file)

      assert line =~ "path=/media/files/#{file.path}"
      assert line =~ "referrers=1"
      assert line =~ doc.doc_id
      assert line =~ "actor=force-witness"

      assert body["forced"] == true
      assert body["referencedByCount"] == 1

      refute Repo.get(MediaFile, file.id)
    end

    test "an UNFORCED delete of an UNREFERENCED blob emits no override warning" do
      file = media_file!()

      {body, log} =
        with_log(fn ->
          admin(scoped_conn()) |> delete("/media/#{file.id}") |> json_response(200)
        end)

      assert body["deleted"] == file.id

      refute override_line(log, file),
             "the override warning fired on an ORDINARY delete, so it is noise " <>
               "an operator will learn to ignore: #{log}"

      refute Map.has_key?(body, "forced"),
             "an unforced receipt grew the override field: #{inspect(body)}"
    end
  end

  # ── the log reader ──────────────────────────────────────────────────────────

  # Keyed to THIS blob's unique path, not merely to the marker: the capture is
  # process-global, so a concurrent async test forcing its OWN delete would
  # otherwise satisfy the presence arms and falsify the absence ones.
  defp override_line(log, %MediaFile{path: path}) do
    log
    |> String.split("\n")
    |> Enum.find(&(String.contains?(&1, @marker) and String.contains?(&1, path)))
  end

  defp override_line!(log, file) do
    override_line(log, file) ||
      flunk("no #{inspect(@marker)} line naming /media/files/#{file.path}. Full log:\n#{log}")
  end

  # ── fixtures (mirrors media_delete_where_used_test.exs) ─────────────────────

  defp admin(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @admin)
    |> put_req_header("content-type", "application/json")
  end

  # Created through the REAL upload door so the row carries whatever tenant scope
  # `scope_opts/1` will later demand of it. The generated path carries a unique
  # integer, so nothing here can be satisfied by another agent's rows in the
  # SHARED test database.
  defp media_file! do
    tmp = Path.join(System.tmp_dir!(), "force-witness-#{System.unique_integer([:positive])}.png")
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

  defp paper_referencing!(%MediaFile{} = file, dataset) do
    Repo.insert!(%Document{
      doc_id: "force-witness-paper-#{System.unique_integer([:positive])}",
      type: "paper",
      dataset: dataset,
      title: "Force witness fixture",
      status: "published",
      rev: "rev-#{System.unique_integer([:positive])}",
      content: %{
        "blocks" => [
          %{"type" => "paragraph", "text" => "before"},
          %{"type" => "image", "src" => "/media/files/#{file.path}", "alt" => "the cast"},
          %{"type" => "paragraph", "text" => "after"}
        ]
      }
    })
  end
end
