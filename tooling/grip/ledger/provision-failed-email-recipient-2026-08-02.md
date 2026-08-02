# Re-derivation: is the `provision_failed` alert email a customer body?

Tree: `origin/main` @ `cfc2f2b77ebcdaec766bbf3b2d159301b71f8dc8` (2026-08-02).
NOTE: the primary checkout is `a31faa52d`, **356 commits behind**, and its `_build`
is pre-wave-25 — running `mix run` there measures OLD `FailureCopy`. Every drive
below compiles the `origin/main` bytes standalone.

## 1. Recipient chain (read)

```sh
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '6955,6960p'      # dispatch_barkpark_event(job.barkpark_id, :provision_failed, %{detail: job.error})
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n "defp dispatch_barkpark_event" -A 8   # -> Notifications.dispatch_event(barkpark.team_id, …)
git show origin/main:cloud/lib/barkpark_cloud/notifications.ex | sed -n '416,430p'     # for recipient <- team_member_emails(settings.team_id)
git show origin/main:cloud/lib/barkpark_cloud/accounts.ex | grep -n "def list_team_member_emails" -A 12   # NO role filter
git show origin/main:cloud/lib/barkpark_cloud/notifications/email_settings.ex | grep -n "field :provision_failed"  # default: true
```

## 2. humanize is absent from the whole notifications tree

```sh
git grep -n "FailureCopy.humanize\|humanize(" origin/main -- cloud/lib
# 3 call sites, all router.ex (8464, 10183, 11886); ZERO in cloud/lib/barkpark_cloud/notifications/
```

## 3. Drive the rendered body (standalone, origin/main bytes)

```sh
cd "$(mktemp -d)"
git -C /Volumes/SATECHI/github/barkpark show origin/main:cloud/lib/barkpark_cloud/failure_copy.ex > fc.ex
cat > drive.exs <<'EOF'
Code.compile_file("fc.ex")
raw = ~s(create "acme-site-ac4e1f2a" failed on all 5 candidate type/locations:) <>
  "\n  - cx22/fsn1: server type cx22 unavailable in fsn1 (resource_unavailable)" <>
  "\n  - cx23/fsn1: resource_unavailable\n  - cx32/nbg1: resource_unavailable" <>
  "\n  - cpx31/hel1: resource_unavailable\n  - cax21/fsn1: resource_unavailable"
IO.puts("DASHBOARD: " <> BarkparkCloud.FailureCopy.humanize(raw))
IO.puts("EMAIL BODY:\nacme-site failed to provision.\n\n" <> BarkparkCloud.FailureCopy.scrub(raw))
EOF
elixir drive.exs
```

Body template is `event_email.ex` `render(:provision_failed, …)` +
`detail/1` = `"\n\n" <> FailureCopy.scrub(d)`.

## 4. Targeted suite

```sh
cd /Volumes/SATECHI/github/barkpark/cloud && CC=clang mix test test/barkpark_cloud/notifications_test.exs
# 26 tests, 0 failures — and ZERO of them assert the email BODY:
grep -rn "failed to provision" test/   # one hit, subject-only
```
