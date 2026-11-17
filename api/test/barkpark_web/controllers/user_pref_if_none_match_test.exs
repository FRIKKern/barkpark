defmodule BarkparkWeb.UserPrefIfNoneMatchTest do
  @moduledoc """
  task-c1f9452e1b8216ee — `PUT /v1/prefs/:dataset/:key` with
  `If-None-Match: *` writes only when the key is unset, so a PUT that creates a
  key cannot overwrite one another writer made in between. `If-Match` cannot
  say "unset": no tag names it.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Auth}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup do
    ws = create_workspace!("prefs-inm-#{System.unique_integer([:positive])}")
    project = create_project!(ws)
    {raw, _user} = personal_token!(ws)
    %{raw: raw, path: "/w/#{ws.slug}/p/#{project.slug}/v1/prefs/#{@dataset}/bot"}
  end

  test "two PUTs with If-None-Match: * to one unset key: the first writes, the second is refused",
       %{raw: raw, path: path} do
    first = put_value(raw, path, %{"name" => "first"}, [{"if-none-match", "*"}])
    assert first.status == 200

    assert Jason.decode!(first.resp_body) == %{
             "ok" => true,
             "key" => "bot",
             "dataset" => @dataset,
             "value" => %{"name" => "first"}
           }

    assert etag(first) == etag(get_pref(raw, path))

    second = put_value(raw, path, %{"name" => "second"}, [{"if-none-match", "*"}])
    assert second.status == 412
    error = Jason.decode!(second.resp_body)["error"]
    assert error["code"] == "precondition_failed"
    assert error["details"] == %{"expected" => nil, "actual" => etag(first)}

    assert value(get_pref(raw, path)) == %{"name" => "first"}
  end

  test "If-None-Match: * on a key another writer set is refused and writes nothing",
       %{raw: raw, path: path} do
    put_value(raw, path, %{"name" => "theirs"})
    patch_set(raw, path, "name", "renamed")

    conn = put_value(raw, path, %{"name" => "mine"}, [{"if-none-match", "*"}])
    assert conn.status == 412
    assert value(get_pref(raw, path)) == %{"name" => "renamed"}
  end

  test "an If-None-Match that is not * is refused and writes nothing", %{raw: raw, path: path} do
    for other <- [~s("abc"), "", " ", "*, \"abc\"", "W/*"] do
      conn = put_value(raw, path, %{"name" => "a"}, [{"if-none-match", other}])
      assert conn.status == 422, "If-None-Match #{inspect(other)}"
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "bad_request"
      assert value(get_pref(raw, path)) == nil
    end
  end

  test "If-Match and If-None-Match together are refused and write nothing",
       %{raw: raw, path: path} do
    put_value(raw, path, %{"name" => "a"})
    tag = etag(get_pref(raw, path))

    conn =
      put_value(raw, path, %{"name" => "b"}, [{"if-match", tag}, {"if-none-match", "*"}])

    assert conn.status == 422
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "bad_request"
    assert value(get_pref(raw, path)) == %{"name" => "a"}
  end

  test "If-None-Match: * with a value over the size cap is a 422 and leaves the key unset",
       %{raw: raw, path: path} do
    big = %{"blob" => String.duplicate("x", 20_000)}
    conn = put_value(raw, path, big, [{"if-none-match", "*"}])
    assert conn.status == 422
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "invalid_pref"
    assert value(get_pref(raw, path)) == nil
  end

  test "the tag a create answers is the stored value's", %{raw: raw, path: path} do
    created = put_value(raw, path, %{"n" => 1.0e20}, [{"if-none-match", "*"}])
    assert created.status == 200
    assert etag(created) == etag(get_pref(raw, path))
  end

  defp put_value(raw, path, value, headers \\ []) do
    headers
    |> Enum.reduce(bearer(raw), fn {name, tag}, conn -> put_req_header(conn, name, tag) end)
    |> put(path, Jason.encode!(%{value: value}))
  end

  defp patch_set(raw, path, field, item) do
    conn = bearer(raw) |> patch(path, Jason.encode!(%{op: "set", field: field, item: item}))
    assert conn.status == 200
    conn
  end

  defp get_pref(raw, path) do
    conn = bearer(raw) |> get(path)
    assert conn.status == 200
    conn
  end

  defp value(conn), do: Jason.decode!(conn.resp_body)["value"]

  defp etag(conn) do
    case get_resp_header(conn, "etag") do
      [tag] -> tag
      [] -> nil
    end
  end

  defp personal_token!(ws) do
    raw = "prefs-inm-#{System.unique_integer([:positive])}"

    {:ok, user} =
      Accounts.register_user(%{
        email: "prefs-inm-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })

    {:ok, token} =
      Auth.create_token(raw, "personal", @dataset, ["read", "write"], nil, owner_user_id: user.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id)
    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "member", "user")
    {raw, user}
  end

  defp bearer(raw),
    do:
      scoped_conn()
      |> put_req_header("authorization", "Bearer #{raw}")
      |> put_req_header("content-type", "application/json")
end
