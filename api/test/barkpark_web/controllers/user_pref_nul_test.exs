defmodule BarkparkWeb.UserPrefNulTest do
  @moduledoc """
  A pref holding U+0000 (task-001a70d85eaa9b3c, F1 of the review of PR #26681).

  The named failure mode: Postgres refuses U+0000 in jsonb (22P05) and in text
  (22021). `UserPref.changeset/2` checked the key and dataset for length and the
  value for size only, so U+0000 in a PUT value, in a PATCH `field` or `item`,
  or in the key or dataset raised in the store: an unhandled 500 on PUT, `set`
  and every list op. Nothing was written, but the caller could not tell why.

  The changeset now refuses it, so each answers `422 invalid_pref` and writes
  nothing. Values a client sends today are pinned beside it.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Auth}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"
  @nul <<0>>

  setup do
    ws = create_workspace!("prefs-nul-#{System.unique_integer([:positive])}")
    project = create_project!(ws)

    raw = "prefs-nul-#{System.unique_integer([:positive])}"

    {:ok, user} =
      Accounts.register_user(%{
        email: "prefs-nul-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })

    {:ok, token} =
      Auth.create_token(raw, "personal", @dataset, ["read", "write"], nil, owner_user_id: user.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id)
    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "member", "user")

    path = fn dataset, key ->
      "/w/#{ws.slug}/p/#{project.slug}/v1/prefs/#{URI.encode(dataset, &URI.char_unreserved?/1)}/" <>
        URI.encode(key, &URI.char_unreserved?/1)
    end

    %{raw: raw, path: path}
  end

  defp bearer(raw),
    do:
      scoped_conn()
      |> put_req_header("authorization", "Bearer #{raw}")
      |> put_req_header("content-type", "application/json")

  defp call(raw, method, path, body \\ nil) do
    conn = bearer(raw)

    case body do
      nil -> dispatch(conn, @endpoint, method, path)
      body -> dispatch(conn, @endpoint, method, path, Jason.encode!(body))
    end
  end

  defp value(raw, path), do: json_response(call(raw, :get, path), 200)["value"]

  defp assert_invalid_pref(conn, label) do
    assert conn.status == 422, "#{label}: answered #{conn.status} #{conn.resp_body}"
    assert json_response(conn, 422)["error"]["code"] == "invalid_pref", label
  end

  @stored %{"ids" => ["a"], "t" => "kept"}

  test "PUT with a value holding U+0000 answers 422 invalid_pref and writes nothing", %{
    raw: raw,
    path: path
  } do
    p = path.(@dataset, "recents")
    assert json_response(call(raw, :put, p, %{value: @stored}), 200)

    for value <- [
          %{"t" => "a" <> @nul <> "b"},
          %{"ids" => ["a" <> @nul]},
          %{"nested" => %{"k" => @nul}},
          %{("k" <> @nul) => 1}
        ] do
      assert_invalid_pref(call(raw, :put, p, %{value: value}), inspect(value))
    end

    assert value(raw, p) == @stored
  end

  test "set, push_front and add with U+0000 in field or item answer 422 invalid_pref and write nothing",
       %{raw: raw, path: path} do
    p = path.(@dataset, "recents")
    assert json_response(call(raw, :put, p, %{value: @stored}), 200)

    for op <- ~w(set push_front add),
        {field, item} <- [{"ids", "b" <> @nul}, {"ids" <> @nul, "b"}, {"ids", %{"k" => @nul}}] do
      body = %{op: op, field: field, item: item}
      assert_invalid_pref(call(raw, :patch, p, body), inspect(body))
    end

    assert value(raw, p) == @stored
  end

  test "a key or dataset holding U+0000 answers 422 invalid_pref on PUT and every op", %{
    raw: raw,
    path: path
  } do
    for p <- [path.(@dataset, "rec" <> @nul <> "ents"), path.("prod" <> @nul, "recents")] do
      assert_invalid_pref(call(raw, :put, p, %{value: @stored}), "PUT #{inspect(p)}")

      for op <- ~w(set push_front add remove) do
        body = %{op: op, field: "ids", item: "a"}
        assert_invalid_pref(call(raw, :patch, p, body), "#{op} #{inspect(p)}")
      end
    end

    assert value(raw, path.(@dataset, "recents")) == nil
  end

  # No row can be stored under such a name, so GET and DELETE answer as they do
  # for an absent key; both raised 22021 before.
  test "GET and DELETE on a key or dataset holding U+0000 answer as for an absent key", %{
    raw: raw,
    path: path
  } do
    for p <- [path.(@dataset, "rec" <> @nul), path.("prod" <> @nul, "recents")] do
      assert json_response(call(raw, :get, p), 200)["value"] == nil
      assert json_response(call(raw, :delete, p), 200) == %{"ok" => true}
    end
  end

  test "values a client sends today are stored exactly as sent", %{raw: raw, path: path} do
    texts = [
      "plain",
      "emoji 🐕‍🦺 שלום",
      "tab\there\nline",
      <<1>>,
      <<0x7F>>,
      "�",
      "the literal \\u0000"
    ]

    for {text, i} <- Enum.with_index(texts) do
      p = path.(@dataset, "pin-#{i}-" <> text)
      assert json_response(call(raw, :put, p, %{value: %{text => [text]}}), 200)
      assert value(raw, p) == %{text => [text]}

      assert json_response(call(raw, :patch, p, %{op: "set", field: text, item: text}), 200)
      assert json_response(call(raw, :patch, p, %{op: "push_front", field: "l", item: text}), 200)
      assert value(raw, p) == %{text => text, "l" => [text]}
    end
  end
end
