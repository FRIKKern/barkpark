defmodule BarkparkWeb.Plugs.ResolveWorkspaceRefusalArmTest do
  @moduledoc """
  BOTH ARMS OF THE MEMBERSHIP GATE, IN ONE RUN (task-d63f91a7f817b4a3).

  `ResolveWorkspace` answers a TWO-arm predicate — membership AND capability —
  and the two arms have OPPOSITE remedies:

    * no seat in the workspace  → invite the principal (`reason "not_a_member"`)
    * a seat, but the credential does not carry `:read`
                                → re-mint / raise the role
                                  (`reason "missing_capability"`)

  It used to call `TenancyAuth.authorize/3`, which IS
  `authorize_with_reason/3` collapsed to `{:error, :forbidden}`, so BOTH arms
  rendered as `not_a_member` — telling an insider it was a stranger, and
  pointing an operator at WIDENING workspace membership, the more dangerous of
  the two fixes.

  WHY BOTH ARMS IN ONE TEST RUN. Fixing the insider arm by making EVERY refusal
  say "missing_capability" would move the inaccuracy rather than remove it, and
  a single-arm test cannot see that. The `describe` below asserts the two
  reasons are DIFFERENT and asserts each one's value, so collapsing them in
  either direction reds.

  WHY THE ADMISSION SET IS PINNED HERE TOO. This is an ACCURACY change to an
  authorization plug: the one failure mode worse than the defect is a refusal
  that becomes an admission. The last test re-computes the OLD predicate
  (`TenancyAuth.authorize(principal, ws, :read) == :ok`, still exported and
  still the collapse of the same function) and asserts it agrees with what the
  live route did, principal by principal, in the same run.

  SCOPE NOTE (shared test database): every workspace slug and token carries a
  `System.unique_integer/1` suffix and every assertion is keyed on rows this
  test created. Nothing counts a shared table.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup do
    n = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "rw-arm-#{n}", name: "RW Arm #{n}"})
    {:ok, _proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})

    # THE INSIDER. A membership row (role `member`) AND permissions that do not
    # satisfy `:read`. This is exactly the shape `Auth.create_token/5` mints for
    # a `chat` token, which is where the defect was observed.
    insider_raw = "rw-insider-#{n}"
    {:ok, insider_tok} = Auth.create_token(insider_raw, "insider", @dataset, ["chat"])
    {:ok, _} = TenancyAuth.create_membership(ws.id, insider_tok.id, "member")

    # THE OUTSIDER. The mirror image: every permission that WOULD satisfy
    # `:read`, and no seat in this workspace at all.
    outsider_raw = "rw-outsider-#{n}"

    {:ok, outsider_tok} =
      Auth.create_token(outsider_raw, "outsider", @dataset, ["read", "write", "admin"])

    # THE MEMBER. Seat AND capability — the caller that must still be ADMITTED.
    member_raw = "rw-member-#{n}"
    {:ok, member_tok} = Auth.create_token(member_raw, "member", @dataset, ["read"])
    {:ok, _} = TenancyAuth.create_membership(ws.id, member_tok.id, "member")

    %{
      ws: ws,
      insider_raw: insider_raw,
      insider_tok: insider_tok,
      outsider_raw: outsider_raw,
      outsider_tok: outsider_tok,
      member_raw: member_raw,
      member_tok: member_tok
    }
  end

  # A scoped READ route: `:scoped_api` runs `ResolveWorkspace`, so the gate under
  # test is the first thing this request meets.
  defp read_path(ws), do: "/w/#{ws.slug}/p/default/v1/data/query/#{@dataset}/post"

  defp read(conn, ws, nil), do: get(conn, read_path(ws))

  defp read(conn, ws, raw),
    do: conn |> put_req_header("authorization", "Bearer " <> raw) |> get(read_path(ws))

  defp error_body(resp), do: Jason.decode!(resp.resp_body)["error"]

  # The refusal reason THIS gate emitted, or `nil` when the gate did not refuse.
  # A refusal from a LATER gate carries no `reason` (plain `{:error, :forbidden}`),
  # so this never confuses one gate for another.
  defp gate_reason(resp) do
    case resp.status do
      403 -> error_body(resp)["reason"]
      _ -> nil
    end
  end

  describe "the refusal names WHICH arm refused" do
    test "an INSIDER lacking the capability gets reason missing_capability — and it really is a member",
         %{conn: conn, ws: ws, insider_raw: raw, insider_tok: tok} do
      resp = read(conn, ws, raw)

      assert resp.status == 403
      err = error_body(resp)
      assert err["code"] == "forbidden"
      assert err["reason"] == "missing_capability"

      # The half that makes the reason TRUE rather than merely different: the
      # seat exists, and the credential is the thing that is wrong.
      assert TenancyAuth.membership_role(tok, ws.id) == "member"
      assert tok.permissions == ["chat"]

      assert TenancyAuth.authorize_with_reason(tok, ws.id, :read) ==
               {:error, :missing_capability}
    end

    test "a GENUINE NON-MEMBER gets reason not_a_member — and it really has no seat", %{
      conn: conn,
      ws: ws,
      outsider_raw: raw,
      outsider_tok: tok
    } do
      resp = read(conn, ws, raw)

      assert resp.status == 403
      err = error_body(resp)
      assert err["code"] == "forbidden"
      assert err["reason"] == "not_a_member"

      assert TenancyAuth.membership_role(tok, ws.id) == nil
      assert TenancyAuth.authorize_with_reason(tok, ws.id, :read) == {:error, :not_a_member}
    end

    test "the two arms are DIFFERENT reasons in the SAME run — neither collapses into the other",
         %{conn: conn, ws: ws, insider_raw: insider, outsider_raw: outsider} do
      insider_reason = gate_reason(read(conn, ws, insider))
      outsider_reason = gate_reason(read(conn, ws, outsider))

      # The pair is the point. A one-arm fix that renamed EVERY refusal to
      # "missing_capability" passes the insider test above and fails here.
      assert insider_reason == "missing_capability"
      assert outsider_reason == "not_a_member"
      refute insider_reason == outsider_reason
    end

    test "ANONYMOUS is unchanged: still reason not_a_member", %{conn: conn, ws: ws} do
      # No token and no user reaches `authorize_with_reason/3`'s catch-all,
      # which is `{:error, :forbidden}` — NOT `:not_a_member`. The plug maps it
      # to the membership envelope on purpose so the anonymous 403 body is
      # byte-identical to before this change.
      resp = read(conn, ws, nil)

      assert resp.status == 403
      err = error_body(resp)
      assert err["code"] == "forbidden"
      assert err["reason"] == "not_a_member"
    end
  end

  describe "no refusal became an admission" do
    test "the admitted set is byte-identical to the OLD predicate, principal by principal", %{
      conn: conn,
      ws: ws,
      insider_raw: insider_raw,
      insider_tok: insider_tok,
      outsider_raw: outsider_raw,
      outsider_tok: outsider_tok,
      member_raw: member_raw,
      member_tok: member_tok
    } do
      principals = [
        {"insider", insider_raw, insider_tok},
        {"outsider", outsider_raw, outsider_tok},
        {"member", member_raw, member_tok}
      ]

      for {label, raw, tok} <- principals do
        # The OLD decision, recomputed from the still-exported collapsing
        # variant the plug used to call.
        old_admits? = TenancyAuth.authorize(tok, ws.id, :read) == :ok

        resp = read(conn, ws, raw)
        gate_refused? = gate_reason(resp) != nil

        assert old_admits? == not gate_refused?,
               "#{label}: the workspace gate changed WHO it admits — " <>
                 "authorize/3 == :ok was #{inspect(old_admits?)} but the gate " <>
                 "#{if gate_refused?, do: "refused", else: "admitted"} it"
      end

      # Stated positively as well, so this test cannot pass by refusing
      # everyone: the seat-AND-capability member is still let through the gate.
      assert TenancyAuth.authorize(member_tok, ws.id, :read) == :ok
      assert gate_reason(read(conn, ws, member_raw)) == nil

      # ...and both refused principals really were refused BY THIS GATE.
      assert gate_reason(read(conn, ws, insider_raw)) != nil
      assert gate_reason(read(conn, ws, outsider_raw)) != nil
    end
  end
end
