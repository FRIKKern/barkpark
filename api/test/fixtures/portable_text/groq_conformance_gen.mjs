// Rewrites the expected answers in groq_conformance_cases.json with groq-js on
// groq_conformance_docs.json. To add a case, add {"name", "query"} to the cases
// file and run this from a directory where groq-js is installed:
//
//   npm i groq-js@2.0.1
//   node <this file>
import {createRequire} from 'node:module'
import {readFileSync, writeFileSync} from 'node:fs'
import {pathToFileURL} from 'node:url'

const here = new URL('.', import.meta.url)
const docsPath = new URL('groq_conformance_docs.json', here)
const casesPath = new URL('groq_conformance_cases.json', here)
// groq-js resolves from the working directory, not from this file.
const require = createRequire(`${process.cwd()}/`)
const {evaluate, parse} = await import(pathToFileURL(require.resolve('groq-js')).href)
const {version} = require('groq-js/package.json')

const {documents} = JSON.parse(readFileSync(docsPath, 'utf8'))
const {cases} = JSON.parse(readFileSync(casesPath, 'utf8'))

for (const c of cases) {
  const value = await evaluate(parse(c.query), {dataset: documents})
  c.expected = await value.get()
}

const source = `Answers from groq-js ${version} on groq_conformance_docs.json, written by groq_conformance_gen.mjs.`
writeFileSync(casesPath, JSON.stringify({source, cases}, null, 1) + '\n')
