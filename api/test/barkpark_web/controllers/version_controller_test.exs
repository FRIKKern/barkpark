defmodule BarkparkWeb.VersionControllerTest do
  @moduledoc """
  Pins `GET /v1/version` — the canonical public deployed-build readout — and,
  in the same file, the contract it must NOT have relaxed to get there
  (task-bl-v1-version-route-gap).

  Two halves, deliberately together:

    * THE ROUTE. Anonymous, 200, body EXACTLY `version` + `commit`, both equal
      to what `Barkpark.BuildInfo` resolved at compile time. Delete the route
      and every test in the first describe block reds (404 on a `json_response`
      is a raised `Phoenix.ActionClauseError`/404 assertion, not a skip).

    * THE CONTROL. `/v1/capabilities` still withholds `build` from tier
      `"none"` even with `?build=1`, and still HANDS it to a bearer. Those two
      assertions are about code this change does not touch, and they must stay
      green through it — that is the point. A future "make /v1/version richer"
      edit that reached for `Capabilities.maybe_put_build/3` or dropped the
      tier check would red here, on the contract, rather than pass quietly on
      the route.

  The exact-key-set assertion is the load-bearing one. `version` and `commit`
  are already public on `/status.json`; `release` (derivable) and `built_at`
  (deploy-cadence intelligence) are not approved for this door, and an
  `assert body["version"]`-style test would happily let either in.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.BuildInfo

  @token "barkpark-dev-token"

  setup do
    # Same tolerant insert the sibling contract tests use: CI boots a cold test
    # DB with no api_tokens row, locally a committed dev-token row may already
    # exist and this insert fails on the unique constraint. Either way a bearer
    # resolves, which the privileged control arm below needs.
    Barkpark.Auth.create_token(@token, "dev", "test", ["read", "write", "admin"])
    :ok
  end

  describe "GET /v1/version — the canonical public readout" do
    test "answers 200 to an ANONYMOUS caller with no token at all", %{conn: conn} do
      body = conn |> get("/v1/version") |> json_response(200)

      assert is_map(body)
    end

    test "carries EXACTLY version and commit — no other field", %{conn: conn} do
      body = conn |> get("/v1/version") |> json_response(200)

      assert Enum.sort(Map.keys(body)) == ["commit", "version"],
             """
             /v1/version must publish EXACTLY version + commit.

             Got: #{inspect(Enum.sort(Map.keys(body)))}

             `release` is the first three segments of `version` (the caller can
             split it) and `built_at` is deploy-cadence intelligence that stays
             inside the AUTHENTICATED capabilities `build` block. Widening this
             body is a disclosure decision — make it here, in this test's
             moduledoc, not by adding a key to the controller.
             """
    end

    test "the two fields are the deployed BuildInfo values, not placeholders", %{conn: conn} do
      body = conn |> get("/v1/version") |> json_response(200)

      assert body["version"] == BuildInfo.version()
      assert body["commit"] == BuildInfo.commit()

      # Anti-vacuity: BuildInfo fails CLOSED to the string "unknown", never to
      # nil or "", so a build with no git still gives a comparison with teeth.
      assert is_binary(body["version"]) and body["version"] != ""
      assert is_binary(body["commit"]) and body["commit"] != ""

      # A.B.C.D (D = commits since the vA.B.C tag) or the fail-closed "unknown"
      # — the same shape the capabilities `build` section is pinned to.
      assert body["version"] =~ ~r/^(\d+\.\d+\.\d+\.\d+|unknown)$/
    end

    test "agrees with /status.json, the surface it supersedes", %{conn: conn} do
      version = conn |> get("/v1/version") |> json_response(200)
      status = conn |> get("/status.json") |> json_response(200)

      assert version["version"] == status["version"]
      assert version["commit"] == status["commit"]
    end
  end

  describe "CONTROL — the privileged capabilities contract is unchanged" do
    test "anonymous /v1/capabilities?build=1 still has NO build section", %{conn: conn} do
      manifest = conn |> get("/v1/capabilities?build=1") |> json_response(200)

      refute Map.has_key?(manifest, "build"),
             "adding a public /v1/version must not open the anonymous manifest's build key"

      # Anti-vacuity for the refute: this really is a manifest, not an error
      # body that happens to lack a "build" key.
      assert is_list(manifest["commands"]) and manifest["commands"] != []
    end

    test "a bearer still GETS the build section from ?build=1", %{conn: conn} do
      manifest =
        conn
        |> put_req_header("authorization", "Bearer #{@token}")
        |> get("/v1/capabilities?build=1")
        |> json_response(200)

      build = manifest["build"]

      assert build != nil
      assert build["version"] == BuildInfo.version()
      assert build["commit"] == BuildInfo.commit()
      # The two fields /v1/version deliberately does NOT publish are still here.
      assert is_binary(build["release"]) and build["release"] != ""
      assert is_binary(build["built_at"]) and build["built_at"] != ""
    end
  end
end
