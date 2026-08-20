// Minimal ambient declarations for the Node APIs the geometry ledger needs.
//
// tsconfig pins `types: ["jest"]` and the package has no @types/node — adding
// it would mean a lockfile change and a whole ambient Node surface (timers,
// Buffer, process) leaking into APP code that must never touch it. The ledger
// needs three functions, two path helpers and __dirname, so those are declared
// here and nothing else: the smallest true statement about the environment
// jest-expo actually runs these tests in.
//
// If a test ever legitimately needs more of Node, that is the moment to take
// the dependency properly rather than growing this file.

declare module 'node:fs' {
  export function readFileSync(path: string, encoding: 'utf8'): string
  export function readdirSync(path: string): string[]
  export function statSync(path: string): { isDirectory(): boolean }
}

declare module 'node:path' {
  export function join(...parts: string[]): string
  export function relative(from: string, to: string): string
}

declare const __dirname: string
