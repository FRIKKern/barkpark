// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// Vite's `?raw` suffix imports a file's bytes as a string. The committed
// `.cast` fixture is served to the stubbed `fetch` verbatim, so the proof
// exercises real on-disk asciicast-v2 bytes (not an inline literal).
declare module '*?raw' {
  const contents: string
  export default contents
}
