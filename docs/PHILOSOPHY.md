<!-- doc-tier: human | canonical-for: barkpark-philosophy | budget: 1200tok -->
# Barkpark is yours

Barkpark is open source software you run wherever you want: a laptop, a Mac mini, a Windows
machine, a VPS, a box at home. You own your content, your schema, your server, and your source
code.

Most of all, Barkpark is about having the infrastructure **ready**: safety, performance,
privacy, collaboration, and freedom are defaults you inherit the moment it boots — not projects
you undertake.

## The open core comes first

Every content feature, schema type, API
capability, and plugin lands in the open-source core — for everyone, first. A self-hosted
Barkpark is the *same* Barkpark: no held-back features, no document limits, no forced telemetry,
no forced hosted auth. The binding rule that keeps it that way is
[decision 0004](decisions/0004-cloud-boundary.md): nothing may ever make Barkpark work worse
self-hosted.

## Conditioned for greatness

We know the temptation from the inside: the moment greed enters a design, dark patterns
follow, and every one is a worse product — friction wearing a business case. So we took the
choice away from our future selves: open source dismantles the machinery that makes a "no"
profitable. We are not locked behind greed. We are locked behind a purpose — greatness, and
making software yours. We will not hold back on user experience, and we will not hold back
on freedom.

## Barkpark Cloud — the official home

We run **[Barkpark Cloud](https://barkpark.cloud)**, and we're not shy about it. It is the
**auth tunnel** — one login that fans out to every Barkpark you own, wherever it lives — plus
managed servers, TLS, backups, and monitoring, from the people who build Barkpark. Use it for
convenience and ease of mind; use it because a vendor you can leave at any moment is a vendor
you can actually trust; and use it to cheer us on — Barkpark Cloud is what lets us keep doing
this work for humanity.

And still, the test we hold ourselves to: **you should never have to rely on us.**

- Third-party hosts are first-class — run Barkpark anywhere; the tunnel reaches it there too.
- The control plane behind Barkpark Cloud is **open source, in this repo**
  ([`cloud/`](../cloud/README.md)). Run it yourself and be your own cloud, tunnel and all.
- Every Barkpark works fully without Cloud. If it vanished tomorrow, nothing you own stops
  working — you'd simply sign in to each server directly again.

Trust that must be re-earned every day, because you are always free to go, is the only trust
worth offering.

## True security is ownership

Default-deny API, existence-hiding, tiered tokens, public reads only where you say so. But the
deepest security is structural: your data sits in your Postgres, on your machine, behind your
firewall, exportable at any moment, running code you can read and fork. There is no third party
to breach, subpoena, or sunset you.
