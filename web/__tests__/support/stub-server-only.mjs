// Registers the loader that stubs the "server-only" marker package for the
// plain-node test runner. Wired in via `--import` in package.json's test
// script; `node --test` propagates it to every spawned test process.
import { register } from "node:module";
register(new URL("./server-only-loader.mjs", import.meta.url));
