defmodule BarkparkWeb.VersionController do
  @moduledoc """
  `GET /v1/version` — THE canonical public readout of the deployed build.

  ## Why this route exists

  A deployment verifier has to answer one question before it can trust any
  other measurement: *which code is this box actually running?* Before this
  route the answer was reachable from exactly two places, and neither was a
  canonical one:

    * `GET /v1/capabilities` carries `build` (`Barkpark.BuildInfo.info/0`) —
      but STRICTLY OPT-IN (`?build=1`) and WITHHELD from tier `"none"`
      (`Barkpark.Plugins.Capabilities.maybe_put_build/3`). An anonymous prober
      gets nothing, BY DESIGN, and that decision is not relaxed here.
    * `GET /status.json` publishes `version` + `commit` publicly
      (`BarkparkWeb.StatusController.show_json/2`) — but it is the uptime
      monitor's payload: health probes of the database, migrations, the plugin
      registry, the SLA, and the last 20 incidents. A verifier that only wants
      the sha pays for all of it, and `/v1/version` returning 404 sent every
      new harness rediscovering the fallback by hand (task-bl-v1-version-route-gap).

  So this is the `/v1`-namespaced, unauthenticated, two-field readout: the
  same two values `/status.json` already publishes, under the path a verifier
  guesses first.

  ## The disclosure decision, stated

  The body carries EXACTLY `version` and `commit` — no more. That is not a
  starting point to grow from:

    * `version` and `commit` are ALREADY public and unauthenticated on
      `/status.json`, and deliberately so ("The sha is the identity … Public +
      unauthenticated on purpose"). This route discloses nothing new;
    * `release` is the first three segments of `version` — derivable by the
      caller, so publishing it would add a key without adding information;
    * `built_at` is NOT public today. A wall-clock build time is deploy-cadence
      intelligence that no verifier needs to identify code, so it stays inside
      the authenticated `build` block.

  `VersionControllerTest` pins the key set EXACTLY, so a future edit that
  widens this body has to argue with a failing test rather than slip through.
  And it pins the other half of the contract too: anonymous
  `/v1/capabilities?build=1` still has NO `build` key. This route is a second,
  narrower door — it does not open the first one wider.

  Mounted on `:api_unlimited` (no auth, not rate-limit-charged) for the same
  reason `/v1/meta` and `/v1/openapi.json` are: a deploy gate polls it while
  the box is still coming up, and a throttled identity probe is a probe that
  reports the wrong answer under exactly the load it exists for.
  """

  use BarkparkWeb, :controller

  alias Barkpark.BuildInfo

  @doc """
  The deployed build identity: `%{"version" => …, "commit" => …}`.

  Both fields degrade to `"unknown"` rather than failing — see `BuildInfo` —
  so this route answers 200 on every build shape (git checkout, docker image,
  release tarball) and a verifier never has to distinguish "no answer" from
  "the box is down".
  """
  def index(conn, _params) do
    json(conn, %{version: BuildInfo.version(), commit: BuildInfo.commit()})
  end
end
