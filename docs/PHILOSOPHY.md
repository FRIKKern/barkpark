<!-- doc-tier: human | canonical-for: barkpark-philosophy | budget: 1200tok -->
# Barkpark is yours

Barkpark exists so you can build connected applications on infrastructure you
own. You control the data, define its structure, and run software you can inspect
and change. A laptop, a server at work, or a rented machine can be home to the
same system.

## Vendors should be a choice

Vendors do useful work. Paying someone to host a server, deliver mail, or maintain
a service can be a good use of money. But every separate service brings its own
rules, data model, costs, and limits. Connecting them becomes work of its own.

Barkpark aims to reduce how many of those decisions stand between an idea and a
working application. Use a vendor where it helps. Keep the ability to run the
system yourself, move your data, and change how it works, including when the
vendor is us.

## Build the common parts once

Schemas, storage, permissions, APIs, and interfaces are the shared foundation.
Papers, Sheets, tasks, and applications you add can use it. A spreadsheet can
appear inside a Paper; an agent and a person can edit the same records through
different interfaces. Each tool should make the next application easier to build.

That is what a strong core is for: less time rebuilding the common parts or
moving data between products, and more time making something that fits your work.
The goal is to replace some of the separate services you need with tools you can
connect and change yourself.

## Choose how you work

The goal is full control through whichever interface suits you: CLI, TUI, GUI,
or AI. Choosing one should not determine which parts of your product you can
control. Content should remain readable wherever you use it.

AI should be able to operate the whole system, including setup, settings, and
access management, without requiring a person to finish steps in a browser.
That is the design goal, not a claim that every interface covers every operation
today. Agents act through credentials whose permissions people can limit and
revoke.

People remain first-class users. You should be able to inspect the data an agent
worked on, understand what changed and why, and take over yourself. Seeing a
finished page is only part of that: the underlying records, settings, and work
history need to be understandable too. AI automation should keep the product
within your control.

## Built from everyday work

I build Barkpark around problems I encounter at work. I got tired of copying AI
status updates into messages for coworkers, so I made Papers to share documents
quickly over the local network. Repeated XLSX exports led to Sheets: keep the data
in Barkpark, update it there, and share a document that reflects those changes.

Those are starting points. The core should support applications I have never
thought of, built by people who know their own work better than I do.

## Keep working locally

You can run Barkpark locally and work with the data on that instance without an
internet connection. You can export datasets and explicitly transfer content
between servers.

The longer-term goal is to keep local and remote instances synchronized so a
remote outage does not stop your work. That requires handling changes on both
sides and reconciling them when the connection returns. Automatic synchronization
and failover are goals, not guarantees of the current transfer tools. A local
instance needs its own data; it is not automatically a copy of your remote one.

## The open core comes first

Every content feature, schema type, API capability, and plugin belongs in the
open-source core first. Self-hosting must not lose features to make the hosted
service necessary. There should be no artificial document limits, forced
telemetry, or forced hosted authentication.

[Decision 0004](decisions/0004-cloud-boundary.md) makes this a project rule:
Barkpark Cloud sells the work of operating a system. It must not make the
self-hosted version worse.

## Paying for convenience

[Barkpark Cloud](https://barkpark.cloud) can operate instances for you and provide
one login across them. It helps fund development. The
[control plane](../cloud/README.md) is also open source and can be self-hosted.
You can run an instance without Cloud and sign in to it directly.

Barkpark is MIT licensed. You can read the code, modify it, and operate your own
system. Ownership also means choosing who maintains it, protects access, and
keeps backups. You can do that work yourself or pay someone you trust. The choice
should stay yours.
