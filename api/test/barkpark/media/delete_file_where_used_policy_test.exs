defmodule Barkpark.Media.DeleteFileWhereUsedPolicyTest do
  @moduledoc """
  task-f7b4e355c8ceb074 — `Media.delete_file/2` must make the where-used
  DECISION unavoidable at every call site.

  THE RESIDUAL PR #15557 LEFT: the where-used guard sits on the TWO HTTP doors
  (`V1.MediaController.delete/2`, `MediaController.delete/2`) and NOT inside
  `Media.delete_file/2` — deliberately, because the cascade callers must keep
  deleting unconditionally. But `Media.delete_file/2` is the obvious API and the
  one 100% of callers actually call. The next engineer who adds a media-delete
  door (a Studio handler, a bulk-cleanup mix task, a plugin) reaches for it and
  ships exactly the silent-erasure door both HTTP doors had before #15557: a
  clean receipt over a blanked live page.

  The fix is not a second guard inside the function — that would break the
  cascade callers AND the doors' `?force=true` escape hatch. It is a REQUIRED
  `:where_used` option with NO DEFAULT IN EITHER DIRECTION, so a new caller
  cannot inherit a policy nobody chose for it.

  WHY EACH ARM IS LOAD-BEARING:

    * The omission arms assert the ROW SURVIVES, not merely that something was
      raised — a raise that still deleted first would satisfy a raise-only
      assertion while shipping the very hole this file exists to close.
    * The `:cascade` arm deletes a blob a PUBLISHED document references. If a
      later refactor moves the scan inside the function, this reds — which is
      the point: `Tenancy.delete_workspace/1` would start refusing to tear down
      a workspace whose own papers reference its own blobs.
    * The `:guard` arm ALSO deletes a referenced blob, and that is not a
      contradiction: `:guard` is a DECLARATION that the call site consults
      `Media.WhereUsed` itself. Both doors pass `:guard` on the `?force=true`
      path too, so a scan inside the function would brick the honest override.
    * The source pin covers the three cascade call sites without standing up
      three heavyweight teardown fixtures, and asserts the call-site COUNT so it
      cannot go vacuous when a site is added or removed.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content.Document
  alias Barkpark.Media
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  @dataset "production"

  # 1x1 transparent PNG, inline — no fixture file needed.
  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  describe "the :where_used policy is REQUIRED — no default, in either direction" do
    test "omitting it raises and the blob is still there" do
      file = media_file!()

      assert_raise ArgumentError, ~r/requires a :where_used policy and has NO default/, fn ->
        Media.delete_file(file.id, [])
      end

      assert Repo.get(MediaFile, file.id),
             "delete_file/2 raised on the missing policy but deleted the row first — " <>
               "the raise is decoration, not a refusal"
    end

    test "omitting it while passing OTHER opts still raises — scope is not a policy" do
      file = media_file!()

      assert_raise ArgumentError, ~r/:where_used/, fn ->
        Media.delete_file(file.id, workspace_id: Ecto.UUID.generate())
      end

      assert Repo.get(MediaFile, file.id)
    end

    test "an unknown policy value raises rather than reading as 'guarded'" do
      file = media_file!()

      for bogus <- [true, "guard", :guarded, nil] do
        assert_raise ArgumentError, ~r/it must be :guard .* or :cascade/s, fn ->
          Media.delete_file(file.id, where_used: bogus)
        end
      end

      assert Repo.get(MediaFile, file.id)
    end

    test "the policy is demanded BEFORE the row is even looked up" do
      # A caller that omits the option learns so on a nonexistent id too, so the
      # mistake surfaces in the first test that exercises the new call site —
      # not only in the one that happens to have a real blob.
      assert_raise ArgumentError, ~r/:where_used/, fn ->
        Media.delete_file(Ecto.UUID.generate(), [])
      end
    end

    test "there is no delete_file/1 left to fall through to" do
      refute function_exported?(Media, :delete_file, 1),
             "delete_file/1 is back, so `Media.delete_file(id)` compiles again and " <>
               "the policy is optional after all"
    end
  end

  describe "both policies still delete unconditionally — the function carries no second guard" do
    test ":cascade deletes a blob a PUBLISHED document references" do
      file = media_file!()
      doc = paper_referencing!(file)

      assert {:ok, deleted} = Media.delete_file(file.id, where_used: :cascade)
      assert deleted.id == file.id
      refute Repo.get(MediaFile, file.id)

      # The census the doors consult really would have refused this one — proof
      # the arm above is not passing because the fixture is unreferenced.
      assert Repo.get(Document, doc.id)
      assert Media.WhereUsed.referrers(%MediaFile{path: file.path}).count >= 1
    end

    test ":guard is a DECLARATION, not a scan — it deletes a referenced blob too" do
      file = media_file!()
      _doc = paper_referencing!(file)

      assert {:ok, _} = Media.delete_file(file.id, where_used: :guard)

      refute Repo.get(MediaFile, file.id),
             "delete_file/2 grew a where-used scan of its own. That breaks the " <>
               "doors' ?force=true override (both doors pass :guard on the forced " <>
               "path) — the guard belongs at the call site, the option only makes " <>
               "the decision unavoidable"
    end
  end

  describe "SOURCE PIN: every production call site names its policy" do
    # `git grep`-free so it runs from any checkout: walk api/lib for the call.
    test "all four lib call sites pass :where_used, and the split is 2 doors / 2 cascade" do
      sites = call_sites()

      assert length(sites) == 4,
             "the media-delete call-site roster moved (found #{length(sites)}): " <>
               "#{inspect(Enum.map(sites, &elem(&1, 0)))}. Re-derive the policy for the " <>
               "new site and update this pin — a call site nobody re-read is exactly " <>
               "the silent door this task closed."

      for {path, line} <- sites do
        assert line =~ "where_used",
               "#{path} calls Media.delete_file/2 without naming a :where_used policy"
      end

      by_policy =
        Enum.group_by(
          sites,
          fn {_p, line} -> if line =~ ":cascade", do: :cascade, else: :guard end,
          fn {p, _l} -> p end
        )

      assert Enum.sort(by_policy[:guard]) == [
               "api/lib/barkpark_web/controllers/media_controller.ex",
               "api/lib/barkpark_web/controllers/v1/media_controller.ex"
             ]

      assert Enum.sort(by_policy[:cascade]) == [
               "api/lib/barkpark/plugins/tickets/attachments.ex",
               "api/lib/barkpark/tenancy.ex"
             ]
    end
  end

  # ── fixtures ────────────────────────────────────────────────────────────────

  defp api_root, do: Path.expand(Path.join(__DIR__, "../../.."))

  defp call_sites do
    api_root()
    |> Path.join("lib/**/*.ex")
    |> Path.wildcard()
    |> Enum.flat_map(fn abs ->
      rel = "api/" <> Path.relative_to(abs, api_root())

      abs
      |> File.read!()
      |> String.split("\n")
      |> Enum.filter(fn line ->
        String.contains?(line, "Media.delete_file(") and
          not String.starts_with?(String.trim_leading(line), "#")
      end)
      |> Enum.map(&{rel, &1})
    end)
    # `def delete_file(...)` in media.ex is the definition, not a call site.
    |> Enum.reject(fn {_p, line} -> String.contains?(line, "def delete_file(") end)
  end

  defp media_file! do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "where-used-policy-#{System.unique_integer([:positive])}.png"
      )

    File.write!(tmp, Base.decode64!(@png_b64))

    {:ok, file} =
      Media.upload(
        %Plug.Upload{path: tmp, filename: "cast.png", content_type: "image/png"},
        @dataset
      )

    # The sandbox rolls the row back; the BYTES on disk outlive the test.
    on_exit(fn -> File.rm(Path.join(Media.upload_dir(), file.path)) end)

    file
  end

  # A published paper carrying the blob as a RAW URL STRING — the shape every
  # reference graph is blind to and the whole reason `WhereUsed` is textual.
  defp paper_referencing!(%MediaFile{} = file) do
    Repo.insert!(%Document{
      doc_id: "where-used-policy-#{System.unique_integer([:positive])}",
      type: "paper",
      dataset: @dataset,
      title: "Where-used policy fixture",
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
