defmodule BarkparkWeb.UserPrefIfMatchTest do
  @moduledoc """
  task-f88365602c49be57 — a whole-object `PUT /v1/prefs/:dataset/:key` with
  `If-Match` writes only over the value its tag names, so a PUT that lands
  late cannot undo a newer change. Every answer that carries a value carries
  its `ETag`, a hash of that value. A PUT without `If-Match` is unchanged.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Auth}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup do
    ws = create_workspace!("prefs-im-#{System.unique_integer([:positive])}")
    project = create_project!(ws)
    {raw, _user} = personal_token!(ws)
    %{raw: raw, path: "/w/#{ws.slug}/p/#{project.slug}/v1/prefs/#{@dataset}/bot"}
  end

  test "a PUT whose If-Match came from a read before a PATCH set is refused, and the set stays",
       %{raw: raw, path: path} do
    put_value(raw, path, %{"name" => "a", "host" => "h"})
    read = get_pref(raw, path)
    stale = etag(read)
    assert is_binary(stale)

    renamed = patch_set(raw, path, "name", "renamed")

    conn = put_value(raw, path, %{"name" => "late", "host" => "h"}, if_match: stale)
    assert conn.status == 412
    error = Jason.decode!(conn.resp_body)["error"]
    assert error["code"] == "precondition_failed"
    assert error["details"] == %{"expected" => stale, "actual" => etag(renamed)}

    after_conn = get_pref(raw, path)
    assert value(after_conn) == %{"name" => "renamed", "host" => "h"}
    assert etag(after_conn) == etag(renamed)
  end

  test "a PUT whose If-Match is the current tag writes, and answers the new value's tag",
       %{raw: raw, path: path} do
    put_value(raw, path, %{"name" => "a"})
    current = etag(get_pref(raw, path))

    conn = put_value(raw, path, %{"name" => "b"}, if_match: current)
    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "ok" => true,
             "key" => "bot",
             "dataset" => @dataset,
             "value" => %{"name" => "b"}
           }

    assert etag(conn) != current
    assert etag(conn) == etag(get_pref(raw, path))
  end

  test "the tag is the value's: GET, PUT and PATCH answer one tag for one value",
       %{raw: raw, path: path} do
    put = put_value(raw, path, %{"name" => "a", "n" => 1})
    assert etag(put) == etag(get_pref(raw, path))

    set = patch_set(raw, path, "name", "a")
    assert etag(set) == etag(put)

    other = patch_set(raw, path, "n", 2)
    refute etag(other) == etag(put)
    assert etag(other) == etag(get_pref(raw, path))
  end

  test "an unset key has no tag, and a PUT with If-Match on it is refused and writes nothing",
       %{raw: raw, path: path} do
    assert etag(get_pref(raw, path)) == nil

    conn = put_value(raw, path, %{"name" => "a"}, if_match: ~s("abc"))
    assert conn.status == 412

    assert Jason.decode!(conn.resp_body)["error"]["details"] == %{
             "expected" => ~s("abc"),
             "actual" => nil
           }

    assert value(get_pref(raw, path)) == nil
  end

  test "If-Match: * matches a stored value and never an unset key", %{raw: raw, path: path} do
    assert put_value(raw, path, %{"name" => "a"}, if_match: "*").status == 412
    assert value(get_pref(raw, path)) == nil

    put_value(raw, path, %{"name" => "a"})
    assert put_value(raw, path, %{"name" => "b"}, if_match: "*").status == 200
    assert value(get_pref(raw, path)) == %{"name" => "b"}
  end

  test "any one listed tag matches; a weak tag never does", %{raw: raw, path: path} do
    put_value(raw, path, %{"name" => "a"})
    current = etag(get_pref(raw, path))

    assert put_value(raw, path, %{"name" => "b"}, if_match: "W/#{current}").status == 412
    assert value(get_pref(raw, path)) == %{"name" => "a"}

    assert put_value(raw, path, %{"name" => "b"}, if_match: ~s("nope", #{current})).status ==
             200

    assert value(get_pref(raw, path)) == %{"name" => "b"}
  end

  # Review of #26861: a present If-Match that holds no tag is a precondition
  # no value meets, never "no header".
  test "an If-Match header with no tag in it is refused and writes nothing",
       %{raw: raw, path: path} do
    for blank <- ["", "  ", ",", " , , "] do
      assert put_value(raw, path, %{"name" => "a"}, if_match: blank).status == 412
      assert value(get_pref(raw, path)) == nil
    end

    put_value(raw, path, %{"name" => "kept"})

    for blank <- ["", "  ", ",", " , , "] do
      conn = put_value(raw, path, %{"name" => "b"}, if_match: blank)
      assert conn.status == 412
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "precondition_failed"
      assert value(get_pref(raw, path)) == %{"name" => "kept"}
    end
  end

  # Review of #26861: Postgres stores a JSON number as numeric and answers it
  # rewritten (1e20 comes back as 100000000000000000000, -0.0 as 0), so a tag
  # of the value as sent would not be the stored value's.
  test "a write's tag is the stored value's, so a number Postgres rewrites still matches",
       %{raw: raw, path: path} do
    for n <- [1.0e20, 1.0e300, -0.0] do
      put = put_value(raw, path, %{"n" => n})
      assert etag(put) == etag(get_pref(raw, path))
      matched = put_value(raw, path, %{"n" => n}, if_match: etag(put))
      assert matched.status == 200
      assert etag(matched) == etag(get_pref(raw, path))

      set = patch_set(raw, path, "m", n)
      assert etag(set) == etag(get_pref(raw, path))
      assert put_value(raw, path, %{"n" => 1}, if_match: etag(set)).status == 200
    end
  end

  test "a matching PUT that breaks the size cap is a 422 and writes nothing",
       %{raw: raw, path: path} do
    put_value(raw, path, %{"name" => "a"})
    current = etag(get_pref(raw, path))

    conn = put_value(raw, path, %{"blob" => String.duplicate("x", 20_000)}, if_match: current)
    assert conn.status == 422
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "invalid_pref"
    assert value(get_pref(raw, path)) == %{"name" => "a"}
  end

  test "a PUT without If-Match answers byte for byte as before", %{raw: raw, path: path} do
    first = put_value(raw, path, %{"name" => "a"})
    assert first.status == 200

    assert first.resp_body ==
             ~s({"ok":true,"value":{"name":"a"},"key":"bot","dataset":"production"})

    patch_set(raw, path, "name", "renamed")

    # Over a newer change, as today: the PUT replaces it.
    second = put_value(raw, path, %{"name" => "b"})
    assert second.status == 200

    assert second.resp_body ==
             ~s({"ok":true,"value":{"name":"b"},"key":"bot","dataset":"production"})

    assert value(get_pref(raw, path)) == %{"name" => "b"}

    # The body is the value as sent, even where Postgres stores it rewritten.
    big = put_value(raw, path, %{"n" => 1.0e20})

    assert big.resp_body ==
             ~s({"ok":true,"value":{"n":1.0e20},"key":"bot","dataset":"production"})
  end

  defp put_value(raw, path, value, opts \\ []) do
    conn = bearer(raw)

    conn =
      case opts[:if_match] do
        nil -> conn
        tag -> put_req_header(conn, "if-match", tag)
      end

    put(conn, path, Jason.encode!(%{value: value}))
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
    raw = "prefs-im-#{System.unique_integer([:positive])}"

    {:ok, user} =
      Accounts.register_user(%{
        email: "prefs-im-#{System.unique_integer([:positive])}@example.com",
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
