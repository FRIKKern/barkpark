// Copies of a part, for the selftest's plants and the job split's proof copies (check/jobs.mjs). Node only: the
// plan job and the aggregate run without installing anything.
import { cpSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

export const edit = (file, fn) => writeFileSync(file, fn(readFileSync(file, 'utf8')))

// A copy of the part beside it, under another name, its ids renamed to match.
export const copyAs = (d, name) => {
  const to = join(d, '..', name)
  cpSync(d, to, { recursive: true })
  for (const f of ['part.json', 'example.html', 'press.mjs', 'demo.mjs'])
    edit(join(to, f), (t) => t.replace(/(["'#,])button-/g, `$1${name}-`).replace('"name": "button"', `"name": "${name}"`))
  return to
}
