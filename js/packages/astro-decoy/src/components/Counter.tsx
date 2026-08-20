// A trivial interactive React island. It exists ONLY to be hydrated via
// `client:load`, so the Astro build ships an `_astro/*.js` bundle and emits an
// `<astro-island>` marker — the two things the decoy test asserts are present.
import { useState } from 'react'

export default function Counter() {
  const [n, setN] = useState(0)
  return (
    <button type="button" onClick={() => setN((v) => v + 1)}>
      clicked {n} times
    </button>
  )
}
