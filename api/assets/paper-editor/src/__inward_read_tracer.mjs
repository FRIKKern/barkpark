// Loaded with --import by __inward_read.test.mjs. Records the fs calls, imports, requires
// and child processes that leave the package in this run, however the path was built. The
// text guard in __build_ownership can only see a path spelled out. esbuild reads natively,
// so its reads stay with the input census in scripts/build-local.mjs. The test's header
// lists what this does not see.
//
// It does nothing unless INWARD_READ_LOG is set, so it also passes when run alone.
import cp from "node:child_process";
import fs from "node:fs";
import Module, { register, syncBuiltinESMExports } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { isMainThread } from "node:worker_threads";

const { INWARD_READ_LOG: LOG, INWARD_READ_ROOT: ROOT, INWARD_READ_ALLOW: ALLOW } = process.env;
const append = fs.appendFileSync;
const inside = (at) => [ROOT, ALLOW].some((dir) => at === dir || at.startsWith(dir + path.sep));
const note = (op, target) => append(LOG, `${JSON.stringify({ op, target })}\n`);

const toPath = (value) => {
  if (Buffer.isBuffer(value)) return path.resolve(value.toString());
  if (value instanceof URL) return value.protocol === "file:" ? fileURLToPath(value) : null;
  if (typeof value !== "string") return null;
  return path.resolve(value.startsWith("file:") ? fileURLToPath(value) : value);
};
const see = (op, value) => {
  const at = toPath(value);
  if (at && !inside(at)) note(op, at);
};

const TWO_PATHS = new Set(["copyFile", "cp", "link", "rename", "symlink"]);
const NAMES = ["access", "appendFile", "chmod", "chown", "copyFile", "cp", "exists", "link", "lstat", "mkdir", "mkdtemp", "open", "opendir", "readdir", "readFile", "readlink", "realpath", "rename", "rm", "rmdir", "stat", "statfs", "symlink", "truncate", "unlink", "utimes", "writeFile"];
const wrap = (owner, name, label, base = name) => {
  const original = owner[name];
  if (typeof original !== "function") return;
  const wrapped = function (...args) {
    see(label, args[0]);
    if (TWO_PATHS.has(base)) see(label, args[1]);
    return Reflect.apply(original, this, args);
  };
  Object.defineProperties(wrapped, Object.getOwnPropertyDescriptors(original));
  owner[name] = wrapped;
};

function patch() {
  const self = process.execPath;
  for (const name of NAMES) {
    wrap(fs, name, name);
    wrap(fs, `${name}Sync`, `${name}Sync`, name);
    wrap(fs.promises, name, `promises.${name}`);
  }
  wrap(fs, "createReadStream", "createReadStream");
  wrap(fs, "createWriteStream", "createWriteStream");
  for (const name of ["spawn", "spawnSync", "exec", "execSync", "execFile", "execFileSync", "fork"]) {
    const original = cp[name];
    cp[name] = function (command, ...rest) {
      const args = rest.find(Array.isArray) ?? [];
      const options = rest.find((item) => item && typeof item === "object" && !Array.isArray(item)) ?? {};
      const line = [command, ...args].join(" ");
      const known = command === self || (path.isAbsolute(command) && inside(command));
      if (!known || /(^|[\s/"'])\.\.([\s/"']|$)/.test(line)) note("spawn", line);
      if (options.cwd) see("spawn cwd", options.cwd);
      return Reflect.apply(original, this, [command, ...rest]);
    };
  }
  const load = Module._load;
  Module._load = function (request, parent, ...rest) {
    if (/^(\.{1,2}(\/|$)|\/|file:)/.test(request)) see("require", request.startsWith(".") && parent?.filename ? path.resolve(path.dirname(parent.filename), request) : request);
    return Reflect.apply(load, this, [request, parent, ...rest]);
  };
  syncBuiltinESMExports();
  register(import.meta.url);
}

// The module hook, run on the loader's own thread. A file that fails to load still counts.
export async function resolve(specifier, context, next) {
  if (LOG && /^(\.{1,2}\/|\/|file:)/.test(specifier)) see("import", specifier.startsWith(".") ? new URL(specifier, context.parentURL) : specifier);
  return next(specifier, context);
}

if (LOG && isMainThread) patch();
