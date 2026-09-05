defmodule BarkparkWeb.InstanceSiteDeployController do
  @moduledoc """
  Answers "can this instance deploy sites?" WITHOUT spending a deploy, over one
  authed GET, so the on-box agent (and the control plane behind it) can fold the
  capability into its beat instead of learning it from a 503 on a real request.

  Before this route the only producers of that fact were both wrong for the job:
  `POST /v1/admin/site-deploy` answers it only by ATTEMPTING a deploy, and
  `GET /v1/admin/site-deploy` has no `enabled?` guard at all — it answered
  `200 {"state":"idle"}` on the fleet for a slug that had never existed, on a box
  that could not have deployed it.

  ## Auth — `[:api, :require_admin]`, matching its `/v1/admin/site-deploy` twin

  Until task-d7ac954aa57aa522 this route rode `[:api, :require_token]`, the
  same Bearer seam as `/v1/instance/request-stats`, on the rule "never
  unauthenticated: door census and runner health are instance-operational
  data". NOT-ANONYMOUS is what that pipeline implements — `RequireToken` +
  `PublicRead` (which denies only the `public-read` tier) +
  `RequireWriteForMutation` (method-gated, so a GET passes untouched) — so any
  read/write/admin token from ANY workspace reached it, a disposable 48h
  playground visitor token included.

  No CITED SAFE argument exists for this payload, and the one recorded for
  `request-stats` (no path, no identifier, no tenant row) does not transfer:
  `door.in_flight_slugs` is `DeployRunner.door_census/0`'s LIST of every site
  slug building on the box right now. Those are other tenants' site
  identifiers, by name — strictly more disclosive than the count beside them
  (`door.observed_in_flight`), and the reason the narrower per-slug read this
  route was written to replace, `GET /v1/admin/site-deploy`, has always been
  `[:api, :require_admin]`. The tier now matches the twin. Nothing real breaks:
  the only caller is the on-box agent's health gate, which already curls the
  instance API with the instance admin token, and the route has no non-test
  reader in-tree.

  Wire contract — FOUR keys: `200 {"configured": bool, "runner_alive": bool,
  "door": {…}, "serving": {…}}`.

  It used to be six. `build_slots` and `runner_queue_len` were emitted here from
  2026-08-07 (dr-w15-s1) until they were DELETED (dr-w26-s7) because neither ever
  acquired a reader: zero occurrences across `internal/`, `cloud/`, `web/` and
  `js/`, and this route has zero non-test callers repo-wide. `build_slots` cost
  nothing to lose — it was `DeployRunner.build_slot_capacity/0`, a compile-time
  constant, and `door.capacity` already carries the same number from the census
  the door actually admits on. `runner_queue_len` cost the only mailbox
  observable this route had; that is stated plainly under "Honest limit" below
  rather than hidden.

  ## Why these four producers, and no others

  NONE of them makes a `GenServer.call`. A probe that calls the Runner would
  re-import the very bug it exists to report: the wedged-Runner case (D113) is
  exactly when this answer matters, and exactly when a call cannot come back.

    * `configured` — `DeployRunner.enabled?/0`, a pure `Application.get_env`
      read, and LITERALLY the expression `SiteDeployController.trigger/2`
      branches on to emit `feature_not_configured`. So this field cannot
      contradict the refusal an operator would get by trying. That
      anti-false-statement property is the whole reason to prefer it over
      grepping `.slots/<slot>.env` — the file and the BEAM demonstrably
      disagree (`runtime.exs` fixes the value at BOOT, and on the fleet
      `/opt/barkpark/.env` overrides the slot file because `start.sh` sources it
      with `set -a` AFTER systemd's EnvironmentFile), and a file cannot see a
      wedged runner at all.
    * `runner_alive` — `Process.whereis/1`. The Runner is put in the tree
      UNCONDITIONALLY (`application.ex`), so `false` here means CRASHED, never
      "feature off". Those two are separate fields for that reason.
    * `door` — `DeployRunner.door_census/0`, an ETS read (no `GenServer.call`,
      same rule as everything else here). Carries `observed_in_flight` —
      `length(building_slugs(state))`, the SAME census the door admits or
      refuses on, which until now was interpolated into a log line and
      discarded — and `in_flight_slugs`, that same census UNAGGREGATED (the
      field this route is admin-gated for; see Auth above) — plus
      `door_open_admissions_total` / `door_open_admissions` beside them (the
      builds the door ADMITTED without a second opinion, by reason),
      `refusals_total` ALWAYS beside `refusals_since`, and
      `measured_at` so the staleness is stated rather than implied. Any of them
      may be `null`: that means nothing was read, never zero.
    * `serving` — `ServingMemory.read/1`: the sha this box is serving and when
      it FIRST saw that sha, off a durable record in the run-state dir. Not a
      process uptime — a restart with an unchanged sha does not move it, which
      is the whole reason it exists (charter D404).

  ## Honest limit (do not read more into this than it says)

  Nothing here sees a WEDGE. `runner_alive` is a `whereis`, and a process parked
  forever in `receive` is as alive as a healthy one; the mailbox depth that told
  those two apart was `runner_queue_len`, and it is gone — deleted, not
  degraded, because for its whole life nothing read it. `door` narrows the gap
  (`observed_in_flight` and `refusals_total` DO move) but it is an ETS snapshot
  of admissions, not of the runner's responsiveness: a box parked mid-`systemctl`
  with an empty mailbox presents `configured: true, runner_alive: true,
  door.observed_in_flight: 1` and can still 503 the next trigger. This route
  reports CAPABILITY and process presence, not a guarantee about the next
  deploy, and not wedge-detection.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Sites.DeployRunner
  alias Barkpark.Sites.ServingMemory

  def show(conn, _params) do
    pid = Process.whereis(DeployRunner)

    json(conn, %{
      configured: DeployRunner.enabled?(),
      runner_alive: is_pid(pid),
      door: DeployRunner.door_census(),
      serving: ServingMemory.read()
    })
  end
end
