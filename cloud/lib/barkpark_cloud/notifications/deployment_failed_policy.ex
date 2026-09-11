defmodule BarkparkCloud.Notifications.DeploymentFailedPolicy do
  @moduledoc """
  dr-w11-bl-deployment-failed-alarm-fatigue — WHICH failed attempts are worth an
  email. One predicate, read by every `:deployment_failed` producer, so the
  fleet has exactly one answer to "did this failure cost a customer anything".

  ## The fault this closes

  `notification_deliveries` on cloud-db-1 holds 2,291 `deployment_failed` emails
  SENT, most recent 2026-08-07 05:43Z, on a rising daily curve:

      Aug 3   340
      Aug 4   446
      Aug 5   625
      Aug 6   870

  Nothing about any individual email was wrong. The alert is edge-guarded (it
  fires only on the transition INTO `failed`, never on the re-writes
  `Sites.Deploy.record_stage/2` drives), it is default-ON for all 22 teams, and
  every row it named really had failed. It was pointed at the wrong QUANTITY:
  the same night's ledger says NOTHING WAS STRANDED. A failed attempt on a site
  that is serving content did not take that content down — the reader still sees
  the page — so ~870 times a day the fleet interrupted a human about an attempt
  that destroyed nothing, and a real incident arrived in the same inbox as 869
  non-events.

  ## The ruling this implements

  RULED by team-lead 2026-09-02 on `dr-w11-bl-deployment-failed-alarm-fatigue`:
  narrow the alarm to attempts that DESTROYED CONTENT, not every transition into
  `failed`. This module is that narrowing and nothing else — it changes no
  toggle, no default, and no copy. The 22 teams that have `deployment_failed` ON
  still have it ON; what changes is how often it has anything to say.

  ## What "destroyed content" can actually mean (and what it cannot)

  The filing describes the target as "stranded a revision / took something live
  down". HALF OF THAT IS UNREACHABLE, and it matters that the code says so
  rather than pretending to guard it. `Deployment`'s `@transitions`
  (`registry/deployment.ex:101-109`) make `"live" => []` — `live` is TERMINAL.
  There is no `live -> failed` edge, so a deploy failure can never move a
  serving deployment out of `live`. Nothing this producer sees ever "takes
  something live down" by transition.

  What remains is the reachable half, and it is the whole of the signal: a
  failure destroys content when THE SITE HAS NOTHING ON THE WEB. Then the
  revision this attempt carried is the only one there was, and a reader gets
  nothing. When the site IS serving, the failure delayed a revision — and a
  DELAY already has its own instrument, `SitePublishWaitingAlert`, which fires
  once per episode after an hour and is keyed on exactly that wait. Sending both
  would be two emails about one event, with the noisier one arriving first.

  ## Where the predicate comes from — the ledger, not a second query

  `DeployLedger.content_on_web?/1` is `delivery/3`'s own `live_marks` clause
  asked as an existence question (see its `@doc` for the two deliberate
  differences: no window, and unmetered rows count). This module writes NO
  query, for the reason `SitePublishWaitingAlert`'s moduledoc gives: a second,
  independently-written "is this site up" query is two definitions of one
  cohort, and the one a human is shown then depends on which producer fired.

  ## Which way the doubt falls

  TWO DIRECTIONS, AND THEY ARE NOT THE SAME DIRECTION.

    * A `preview` attempt is `false` — NOT an alarm. A branch preview answers on
      its own host and `NEVER touches sites.current_deployment_id / sites.port`
      (`registry/deployment.ex:38-41`), so it cannot destroy production content
      whatever the site's state is.
    * An attempt this module cannot KEY — no site id at all — is `true`, an
      alarm. That is charter D3: a thing nobody could measure must not resolve
      to good news. A suppression is only ever earned by a reading, never by an
      absence.
  """
  alias BarkparkCloud.DeployLedger
  alias BarkparkCloud.Registry.Deployment

  @doc """
  Whether this failed attempt destroyed content, and therefore whether it earns
  a `:deployment_failed` email.

  Accepts a `Deployment` struct (the two synchronous producers hold one) or a
  plain map (the reaper holds only the `{id, site_id}` its `select:` named, so
  `:environment` is absent there and the site question is asked unqualified —
  `content_on_web?/1` is production-scoped, so an unqualified read is still a
  read about production content).
  """
  @spec destroyed_content?(Deployment.t() | map()) :: boolean()
  def destroyed_content?(%Deployment{site_id: site_id, environment: env}),
    do: decide(site_id, env)

  def destroyed_content?(%{} = attempt) do
    decide(Map.get(attempt, :site_id), Map.get(attempt, :environment))
  end

  def destroyed_content?(_attempt), do: true

  # A preview cannot destroy production content — see the moduledoc.
  defp decide(_site_id, "preview"), do: false

  defp decide(site_id, _environment) when is_binary(site_id),
    do: not DeployLedger.content_on_web?(site_id)

  # UNKEYABLE IS NOT QUIET (charter D3).
  defp decide(_site_id, _environment), do: true
end
