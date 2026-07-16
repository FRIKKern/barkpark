// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// Ambient module for the asciinema-player stylesheet `client.ts` side-effect
// imports. `mermaid` and `asciinema-player` themselves ship their own `.d.ts`
// (resolved from devDependencies), but a CSS asset has no type — this keeps the
// DTS build from redding TS2307 on the cosmetic `import('…asciinema-player.css')`.
declare module '*.css'
