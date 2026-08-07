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

  The route rides `[:api, :require_token]` — the SAME Bearer seam as
  `/v1/instance/request-stats`, which the agent's health gate already probes.
  Never unauthenticated: build capacity and runner health are
  instance-operational data.

  Wire contract — FOUR keys: `200 {"configured": bool, "runner_alive": bool,
  "runner_queue_len": int|null, "build_slots": int}`.

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
    * `runner_queue_len` — `Process.info(pid, :message_queue_len)`, non-blocking
      (same prior art as `ListenController`). `null` when there is no pid.
    * `build_slots` — `DeployRunner.build_slot_capacity/0`, a module attribute.

  ## Honest limit (do not read more into this than it says)

  `runner_queue_len` distinguishes a BACKED-UP runner — callers piling up behind
  a door that is not answering — from an idle one. It does NOT see a runner
  whose single in-flight `systemctl` is merely slow with an empty mailbox: such
  a box presents `configured: true, runner_alive: true, runner_queue_len: 0` and
  can still 503 the next trigger. This route reports CAPABILITY and runner
  health, not a guarantee about the next deploy.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Sites.DeployRunner

  def show(conn, _params) do
    pid = Process.whereis(DeployRunner)

    json(conn, %{
      configured: DeployRunner.enabled?(),
      runner_alive: is_pid(pid),
      runner_queue_len: message_queue_len(pid),
      build_slots: DeployRunner.build_slot_capacity()
    })
  end

  # `null`, never a reassuring 0, when there is no process to measure: an absent
  # runner has no empty mailbox, it has no mailbox.
  defp message_queue_len(pid) when is_pid(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, n} -> n
      # the pid died between whereis and info
      nil -> nil
    end
  end

  defp message_queue_len(_), do: nil
end
