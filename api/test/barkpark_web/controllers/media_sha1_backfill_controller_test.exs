defmodule BarkparkWeb.MediaSha1BackfillControllerTest do
  @moduledoc """
  `POST /v1/admin/media/sha1-backfill`: the door Barkpark Cloud uses to run the
  media SHA-1 backfill on a box with no shell. Operator tier, dry run by
  default, one page per apply.

  async: false — the operator allowlist is Application env.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query
  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Media, Repo}
  alias Barkpark.Media.Storage.MediaFile

  @admin ["read", "write", "admin"]

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  setup do
    put_allowlist([], [])
    home = create_workspace!(uniq("msb-home"))
    raw = uniq("admin")
    {:ok, token} = Auth.create_token(raw, "barkpark cloud admin", "production", @admin, home.id)
    %{home: home, raw: raw, token: token}
  end

  defp put_allowlist(emails, ids) do
    prev_emails = Application.get_env(:barkpark, :operator_emails, [])
    prev_ids = Application.get_env(:barkpark, :operator_token_ids, [])
    Application.put_env(:barkpark, :operator_emails, emails)
    Application.put_env(:barkpark, :operator_token_ids, ids)

    on_exit(fn ->
      Application.put_env(:barkpark, :operator_emails, prev_emails)
      Application.put_env(:barkpark, :operator_token_ids, prev_ids)
    end)
  end

  defp backfill(bearer, body) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{bearer}")
    |> put_req_header("content-type", "application/json")
    |> post("/v1/admin/media/sha1-backfill", Jason.encode!(body))
  end

  defp unhashed_file! do
    bytes = "sha1 backfill route #{System.unique_integer([:positive])} #{:rand.uniform()}"
    path = Path.join(System.tmp_dir!(), "msb-#{System.unique_integer([:positive])}.txt")
    File.write!(path, bytes)
    {:ok, file} = Media.upload(%Plug.Upload{path: path, filename: "msb.txt"}, "production")
    Repo.update_all(where(MediaFile, [m], m.id == ^file.id), set: [sha1: nil])
    {file, Base.encode16(:crypto.hash(:sha, bytes), case: :lower)}
  end

  defp sha1_of(id), do: Repo.one(from(m in MediaFile, where: m.id == ^id, select: m.sha1))

  test "a dry run is the default, counts per dataset and writes nothing", ctx do
    {file, _} = unhashed_file!()

    body = ctx.raw |> backfill(%{}) |> json_response(200)

    assert body["applied"] == false
    assert body["unhashed"] >= 1
    assert Enum.any?(body["datasets"], &(&1["dataset"] == "production" and &1["unhashed"] >= 1))
    assert sha1_of(file.id) == nil
  end

  test "apply hashes page by page until next_after is null", ctx do
    files = for _ <- 1..3, do: unhashed_file!()

    first = ctx.raw |> backfill(%{apply: true, limit: 2}) |> json_response(200)
    assert first["applied"] == true
    assert first["hashed"] == 2
    assert first["failed"] == []
    assert is_binary(first["next_after"])

    second =
      ctx.raw
      |> backfill(%{apply: true, limit: 2, after: first["next_after"]})
      |> json_response(200)

    assert second["next_after"] == nil
    assert second["unhashed"] == 0

    for {file, want} <- files, do: assert(sha1_of(file.id) == want)
  end

  test "with the operator allowlist armed, only a listed token gets in", ctx do
    {file, _} = unhashed_file!()
    other = uniq("other")
    {:ok, _} = Auth.create_token(other, "tenant admin", "production", @admin, ctx.home.id)
    put_allowlist([], [ctx.token.id])

    assert json_response(backfill(other, %{apply: true}), 403)["error"]["required"] ==
             "platform_operator"

    assert sha1_of(file.id) == nil
    assert ctx.raw |> backfill(%{}) |> json_response(200)
  end

  test "a token without the admin bit is refused", ctx do
    raw = uniq("reader")
    {:ok, _} = Auth.create_token(raw, "reader", "production", ["read"], ctx.home.id)
    assert backfill(raw, %{}).status == 403
  end

  test "bad input is 422", ctx do
    assert json_response(backfill(ctx.raw, %{apply: "yes"}), 422)
    assert json_response(backfill(ctx.raw, %{apply: true, after: "nope"}), 422)
    assert json_response(backfill(ctx.raw, %{apply: true, limit: 0}), 422)
    assert json_response(backfill(ctx.raw, %{apply: true, limit: 501}), 422)
  end
end
