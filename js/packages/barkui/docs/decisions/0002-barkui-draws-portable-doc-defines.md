<!-- doc-tier: human | canonical-for: barkui-decision-draws-defines | budget: 600tok -->
# 0002 BarkUI draws, PortableDoc defines

Date: 2026-11-18 · Status: accepted

```
PortableDoc                                  BarkUI
what a document is (the format)              the colours
the checker                                  how every block is drawn, on every format
the edit commands                            the editor's menus
the agent server                             the app parts
```

## Context

PortableDoc's renderers already draw every block on the web with and without script, in email, in a terminal and on the phone, each from Barkpark's colour source under names of its own. Apps draw the chrome around a document with their own colours. A document and the app around it can disagree.

## Decision

PortableDoc keeps what a document is: the format, the checker, the edit commands and the agent server. BarkUI owns how it looks: the colours, how each block is drawn on every format, the editor's menus and the app parts. The renderers stay where they are and read BarkUI's names through a bridge, with today's values as the fallback, so nothing draws differently on the day it switches.

## What would change it

A format that needs a look PortableDoc must carry inside the document itself, so that drawing it cannot be separated from defining it.

## Considered

- **BarkUI inside PortableDoc.** Rejected: apps that never show a document would depend on the document format.
- **PortableDoc keeps its own look.** Rejected: a document and the app around it would keep two sets of colours.
