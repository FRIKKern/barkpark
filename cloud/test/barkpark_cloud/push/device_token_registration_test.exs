defmodule BarkparkCloud.Push.DeviceTokenRegistrationTest do
  @moduledoc """
  Push-relay spike (mobile charter D15a) — the user-authed device registration
  endpoint and the schema's row shape:

      POST /v1/push/device-tokens   user   {platform, token, metadata?}

  Proves:

    * unauthenticated → 401; the row binds to the CALLING user (never a
      client-supplied id);
    * per-user × per-device ROWS: two devices → two rows, mirroring
      user_tokens' discriminated-row shape (platform is the discriminator);
    * idempotent upsert on (user_id, platform, token): re-registering revives a
      revoked row (app reinstall) and refreshes metadata — never a duplicate;
    * bounded vocabulary: an unknown platform / too-short token → 422.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Push, Repo}
  alias BarkparkCloud.Push.DevicePushToken
  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  defp user_with_session do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })

    {:ok, token} = Accounts.create_user_session_token(user)
    {user, token}
  end

  defp register(token, body) do
    conn = conn(:post, "/v1/push/device-tokens", Jason.encode!(body))
    conn = put_req_header(conn, "content-type", "application/json")
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  test "unauthenticated → 401" do
    conn = register(nil, %{"platform" => "apns", "token" => "a-device-token"})
    assert conn.status == 401
  end

  test "registers a device row bound to the CALLING user → 201" do
    {user, session} = user_with_session()

    conn =
      register(session, %{
        "platform" => "apns",
        "token" => "apns-device-token-1",
        "metadata" => %{"model" => "iPhone 17"}
      })

    assert conn.status == 201
    body = json_body(conn)
    assert body["registered"] == true
    assert body["platform"] == "apns"

    device = Repo.get!(DevicePushToken, body["id"])
    assert device.user_id == user.id
    assert device.token == "apns-device-token-1"
    assert device.metadata == %{"model" => "iPhone 17"}
    assert is_nil(device.revoked_at)
  end

  test "per-device ROWS: a second device is a second row, never an overwrite" do
    {user, session} = user_with_session()

    phone = register(session, %{"platform" => "apns", "token" => "iphone-token-abc"})
    tablet = register(session, %{"platform" => "fcm", "token" => "tablet-token-def"})
    assert phone.status == 201
    assert tablet.status == 201

    rows = Repo.all(from(t in DevicePushToken, where: t.user_id == ^user.id))
    assert length(rows) == 2
    assert Enum.sort(Enum.map(rows, & &1.platform)) == ["apns", "fcm"]
  end

  test "idempotent upsert: re-registering the same (platform, token) revives a revoked row" do
    {user, session} = user_with_session()

    {:ok, device} =
      Push.register_device_token(user, %{"platform" => "apns", "token" => "same-device-token"})

    device |> Ecto.Changeset.change(revoked_at: DateTime.utc_now()) |> Repo.update!()

    conn =
      register(session, %{
        "platform" => "apns",
        "token" => "same-device-token",
        "metadata" => %{"app_version" => "2.0"}
      })

    assert conn.status == 201
    assert json_body(conn)["id"] == device.id

    revived = Repo.get!(DevicePushToken, device.id)
    assert is_nil(revived.revoked_at)
    assert revived.metadata == %{"app_version" => "2.0"}
    assert Repo.aggregate(from(t in DevicePushToken, where: t.user_id == ^user.id), :count) == 1
  end

  test "an unknown platform → 422 (bounded apns|fcm vocabulary)" do
    {_user, session} = user_with_session()
    conn = register(session, %{"platform" => "carrier-pigeon", "token" => "a-device-token"})
    assert conn.status == 422
    assert json_body(conn)["error"] == "invalid"
  end

  test "a missing/too-short token → 422" do
    {_user, session} = user_with_session()
    assert register(session, %{"platform" => "apns"}).status == 422
    assert register(session, %{"platform" => "apns", "token" => "x"}).status == 422
  end
end
