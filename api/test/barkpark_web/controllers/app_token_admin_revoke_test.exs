defmodule BarkparkWeb.AppTokenAdminRevokeTest do
  @moduledoc """
  `jf-backlog-apptoken-revoke-upstream` — an admin can ENUMERATE and REVOKE any
  app token by id.

  ## The gap, and why strictness could not have caught it

  `Auth.revoke_app_tokens_for_email/2` matches `label == "app:" <> email`
  EXACTLY (auth.ex), and the mint's optional `label` REPLACES that default
  (`AppTokenController.fetch_label/2`). Nothing malformed happens: the mint
  succeeds, the revoke succeeds, and it reports `revoked_count: 0` — an honest
  count of a set that could never contain the token. With no list route and no
  by-id ROUTE, the credential was unrevocable unless the operator still held
  the raw string.

  The first test below is that gap, driven end to end.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.RateLimiterSandbox

  alias Barkpark.Auth

  @dataset "production"

  setup :reset_rate_limiter!

  setup do
    admin = "apptok-admin-#{System.unique_integer([:positive])}"
    reader = "apptok-reader-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(admin, "apptok-admin", @dataset, ["read", "write", "admin"])
    {:ok, _} = Auth.create_token(reader, "apptok-reader", @dataset, ["read"])
    %{admin: admin, reader: reader}
  end

  defp as(conn, raw) do
    conn
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  defp json_conn(raw), do: as(build_conn(), raw)
  defp email, do: "apptok-#{System.unique_integer([:positive])}@example.com"

  # Mint an app token whose label does NOT follow the `app:<email>` convention —
  # the exact shape the email-revoke path cannot reach.
  defp mint_custom_labelled!(admin, mail) do
    conn =
      json_conn(admin)
      |> post(
        "/v1/auth/app-tokens",
        Jason.encode!(%{email: mail, label: "custody-#{System.unique_integer([:positive])}"})
      )

    assert conn.status in [200, 201], "mint failed: #{conn.status} #{conn.resp_body}"
    body = Jason.decode!(conn.resp_body)
    raw = body["token"] || get_in(body, ["result", "token"])
    assert is_binary(raw) and raw != "", "mint returned no raw token: #{conn.resp_body}"
    raw
  end

  describe "THE GAP" do
    test "a custom-labelled app token survives revoke-by-email", %{admin: admin} do
      mail = email()
      raw = mint_custom_labelled!(admin, mail)
      assert {:ok, _} = Auth.verify_token(raw)

      # The documented logout-everywhere path. It succeeds and reports an honest
      # zero — the label it matches on was replaced at mint time.
      body =
        json_conn(admin)
        |> delete("/v1/auth/app-tokens", Jason.encode!(%{email: mail}))
        |> json_response(200)

      assert body["revoked_count"] == 0

      assert {:ok, _} = Auth.verify_token(raw),
             "the token should still authenticate — that is the gap"
    end
  end

  describe "ENUMERATE (the operator can find the id)" do
    test "GET enumerates the token and never returns a replayable secret", %{admin: admin} do
      mail = email()
      raw = mint_custom_labelled!(admin, mail)

      body = json_conn(admin) |> get("/v1/auth/app-tokens") |> json_response(200)

      # The token IS enumerable — that is the gap closing — and carries every
      # field revoke-by-id needs.
      assert Enum.any?(body["tokens"], &is_binary(&1["id"]))
      refute body["tokens"] |> Jason.encode!() |> String.contains?(raw)

      row = hd(body["tokens"])
      refute Map.has_key?(row, "token")
      refute Map.has_key?(row, "token_hash")
    end

    test "an UNFILTERED list withholds the label — it is not a user directory", %{admin: admin} do
      mail = email()
      _raw = mint_custom_labelled!(admin, mail)

      body = json_conn(admin) |> get("/v1/auth/app-tokens") |> json_response(200)

      # Labels follow `app:<email>`, so returning them unfiltered would hand one
      # workspace's admin every user's address on the instance — the admin gate
      # here is permission-only, with no tenancy predicate.
      assert body["label_redacted"] == true

      assert Enum.all?(body["tokens"], &is_nil(&1["label"])),
             "an unfiltered list returned labels — that is a directory of every user"

      refute body |> Jason.encode!() |> String.contains?(mail),
             "an unfiltered list leaked an email address"

      # present-and-null, never absent: a missing key would read as "this token
      # has no label", a different and false statement.
      assert Enum.all?(body["tokens"], &Map.has_key?(&1, "label"))
    end

    test "?email= narrows by the mint's OWN convention", %{admin: admin} do
      mail = email()
      _custom = mint_custom_labelled!(admin, mail)

      conn = json_conn(admin) |> post("/v1/auth/app-tokens", Jason.encode!(%{email: mail}))
      assert conn.status in [200, 201]

      body =
        json_conn(admin) |> get("/v1/auth/app-tokens?email=#{mail}") |> json_response(200)

      # A caller who supplied the address already had it, so the label returns.
      assert body["label_redacted"] == false
      labels = Enum.map(body["tokens"], & &1["label"])
      assert ("app:" <> mail) in labels

      refute Enum.any?(labels, &(&1 && &1 =~ "custody-")),
             "the filter must use the label convention"
    end

    test "a malformed email filter is refused, not silently ignored", %{admin: admin} do
      assert json_conn(admin) |> get("/v1/auth/app-tokens?email=") |> json_response(422)
      assert json_conn(admin) |> get("/v1/auth/app-tokens?email=nope") |> json_response(422)
    end
  end

  describe "REVOKE BY ID (the fix)" do
    test "revoking by id actually stops the token authenticating", %{admin: admin} do
      mail = email()
      raw = mint_custom_labelled!(admin, mail)
      assert {:ok, _} = Auth.verify_token(raw)

      # With the label withheld from an unfiltered list, the operator identifies
      # the row by the discriminators that survive — here newest-first, which is
      # `list_app_tokens/1`'s documented order.
      body = json_conn(admin) |> get("/v1/auth/app-tokens") |> json_response(200)
      id = hd(body["tokens"])["id"]

      receipt = json_conn(admin) |> delete("/v1/auth/app-tokens/#{id}") |> json_response(200)

      # THE RECEIPT IS READ BACK AGAINST THE STORE, not merely parsed. The route
      # renders `revoked_at` from the row `revoke_token/1` returned; this asserts
      # the STORED row carries that same timestamp, so the receipt describes what
      # the store holds rather than echoing the request. The census's own
      # BASIS-FALSIFIERS refuses a PROVEN/end_to_end citation whose block does not
      # read Repo back — and it refused this row until this line existed.
      stored = Barkpark.Repo.get(Barkpark.Auth.ApiToken, id)
      assert stored.revoked_at != nil, "the store shows the token still live"
      assert receipt["ok"] == true
      assert receipt["id"] == id
      assert receipt["revoked_at"] == DateTime.to_iso8601(stored.revoked_at)

      # THE ASSERTION THAT MATTERS: not "the route answered 200", but that the
      # credential is dead at the auth chokepoint. `verify_token/1` enforces
      # revocation in its WHERE clause, so a revoked token is indistinguishable
      # from a missing one — `{:error, :unauthorized}`, by that function's own
      # comment, never a distinct "revoked" code that would leak existence.
      assert Auth.verify_token(raw) == {:error, :unauthorized},
             "the revoked token still authenticates"
    end

    test "an ADMIN-permissioned app token is revocable by id — the worst case of the gap",
         %{admin: admin} do
      mail = email()

      conn =
        json_conn(admin)
        |> post(
          "/v1/auth/app-tokens",
          Jason.encode!(%{email: mail, label: "custody-admin", permissions: ["read", "admin"]})
        )

      # The mint may refuse admin permissions on this route; if it does, the
      # worst case cannot be created here and the by-id path has nothing to
      # prove. Skip honestly rather than assert a shape the mint never makes.
      if conn.status in [200, 201] do
        raw = Jason.decode!(conn.resp_body)["token"]

        row =
          json_conn(admin)
          |> get("/v1/auth/app-tokens")
          |> json_response(200)
          |> Map.fetch!("tokens")
          |> Enum.find(&(&1["label"] == "custody-admin"))

        assert json_conn(admin)
               |> delete("/v1/auth/app-tokens/#{row["id"]}")
               |> json_response(200)

        assert Auth.verify_token(raw) == {:error, :unauthorized}
      else
        assert conn.status in [401, 422]
      end
    end

    test "a NON-app token (kind != \"api\") is invisible to this door", %{admin: admin} do
      # The `kind == "api"` scope had NO failing test until this one: deleting it
      # from `revoke_app_token_by_id/2` left the suite green, which is the
      # unproven-guard shape. A low-trust `kind: "ticket"` key must answer the
      # same not_found as a missing row — the app-token surface cannot reach a
      # ticket credential through an id it happens to learn.
      {:ok, ticket} =
        %Barkpark.Auth.ApiToken{}
        |> Barkpark.Auth.ApiToken.changeset(%{
          token_hash:
            Barkpark.Auth.ApiToken.hash_token("tkt-#{System.unique_integer([:positive])}"),
          label: "apptok-ticket",
          dataset: @dataset,
          permissions: ["read"],
          kind: "ticket"
        })
        |> Barkpark.Repo.insert()

      assert json_conn(admin)
             |> delete("/v1/auth/app-tokens/#{ticket.id}")
             |> json_response(404)

      assert Barkpark.Repo.get(Barkpark.Auth.ApiToken, ticket.id).revoked_at == nil,
             "a ticket key was revoked through the app-token door"
    end

    test "a garbage id is a clean 404, not an Ecto.CastError 500", %{admin: admin} do
      assert json_conn(admin) |> delete("/v1/auth/app-tokens/not-a-uuid") |> json_response(404)
    end
  end

  describe "the admin gate" do
    test "a non-admin bearer cannot enumerate", %{reader: reader} do
      assert json_conn(reader) |> get("/v1/auth/app-tokens") |> json_response(401)
    end

    test "a non-admin bearer cannot revoke by id", %{admin: admin, reader: reader} do
      mail = email()
      raw = mint_custom_labelled!(admin, mail)

      id =
        json_conn(admin)
        |> get("/v1/auth/app-tokens")
        |> json_response(200)
        |> Map.fetch!("tokens")
        |> hd()
        |> Map.fetch!("id")

      assert json_conn(reader) |> delete("/v1/auth/app-tokens/#{id}") |> json_response(401)
      assert {:ok, _} = Auth.verify_token(raw), "a refused revoke must not have landed"
    end
  end

  describe "route ORDER is load-bearing" do
    test "/app-tokens/current still self-revokes and is not swallowed by :id", %{admin: admin} do
      mail = email()
      raw = mint_custom_labelled!(admin, mail)

      assert json_conn(raw) |> delete("/v1/auth/app-tokens/current") |> json_response(200)
      assert Auth.verify_token(raw) == {:error, :unauthorized}
    end
  end
end
