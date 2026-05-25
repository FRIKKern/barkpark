'use strict';

// src/errors.ts
var BarkparkError = class extends Error {
  code;
  requestId;
  url;
  status;
  constructor(message, opts) {
    super(message, opts?.cause !== void 0 ? { cause: opts.cause } : void 0);
    this.name = new.target.name;
    this.code = opts?.code ?? new.target.name;
    if (opts?.requestId !== void 0) this.requestId = opts.requestId;
    if (opts?.url !== void 0) this.url = opts.url;
    if (opts?.status !== void 0) this.status = opts.status;
  }
};
var BarkparkAPIError = class extends BarkparkError {
  body;
  constructor(message, opts) {
    super(message, opts);
    if (opts?.body !== void 0) this.body = opts.body;
  }
};
var BarkparkAuthError = class extends BarkparkError {
};
var BarkparkNetworkError = class extends BarkparkError {
};
var BarkparkTimeoutError = class extends BarkparkError {
  timeoutMs;
  constructor(message, opts) {
    super(message, opts);
    if (opts?.timeoutMs !== void 0) this.timeoutMs = opts.timeoutMs;
  }
};
var BarkparkRateLimitError = class extends BarkparkAPIError {
  retryAfterMs;
  constructor(message, opts) {
    super(message, opts);
    if (opts?.retryAfterMs !== void 0) this.retryAfterMs = opts.retryAfterMs;
  }
};
var BarkparkNotFoundError = class extends BarkparkAPIError {
};
var BarkparkValidationError = class extends BarkparkError {
  issues;
  field;
  reason;
  constructor(message, opts) {
    super(message, opts);
    if (opts?.issues !== void 0) this.issues = opts.issues;
    if (opts?.field !== void 0) this.field = opts.field;
    if (opts?.reason !== void 0) this.reason = opts.reason;
  }
};
var BarkparkHmacError = class extends BarkparkError {
};
var BarkparkSchemaMismatchError = class extends BarkparkError {
  clientApiVersion;
  serverMinApiVersion;
  serverMaxApiVersion;
  localSchemaHash;
  remoteSchemaHash;
  constructor(message, opts) {
    super(message, opts);
    if (opts?.clientApiVersion !== void 0) this.clientApiVersion = opts.clientApiVersion;
    if (opts?.serverMinApiVersion !== void 0) this.serverMinApiVersion = opts.serverMinApiVersion;
    if (opts?.serverMaxApiVersion !== void 0) this.serverMaxApiVersion = opts.serverMaxApiVersion;
    if (opts?.localSchemaHash !== void 0) this.localSchemaHash = opts.localSchemaHash;
    if (opts?.remoteSchemaHash !== void 0) this.remoteSchemaHash = opts.remoteSchemaHash;
  }
};
var BarkparkEdgeRuntimeError = class extends BarkparkError {
};
var BarkparkConflictError = class extends BarkparkAPIError {
  serverEtag;
  serverDoc;
  constructor(message, opts) {
    super(message, opts);
    if (opts?.serverEtag !== void 0) this.serverEtag = opts.serverEtag;
    if (opts?.serverDoc !== void 0) this.serverDoc = opts.serverDoc;
  }
};

// src/scope.ts
function scopePrefix(config) {
  if (typeof config.workspace === "string" && config.workspace.length > 0 && typeof config.project === "string" && config.project.length > 0) {
    return `/w/${config.workspace}/p/${config.project}`;
  }
  return "";
}

// src/retry.ts
var DEFAULT_READ_POLICY = {
  maxAttempts: 3,
  baseMs: 300,
  maxBackoffMs: 5e3,
  jitter: true
};
var DEFAULT_WRITE_POLICY = {
  maxAttempts: 1,
  baseMs: 0,
  maxBackoffMs: 0,
  jitter: false
};
var IDEMPOTENT_WRITE_POLICY = {
  maxAttempts: 3,
  baseMs: 400,
  maxBackoffMs: 8e3,
  jitter: true
};
function defaultShouldRetry(err) {
  if (err instanceof BarkparkNetworkError) return true;
  if (err instanceof BarkparkTimeoutError) return true;
  if (err instanceof BarkparkRateLimitError) return true;
  if (err instanceof BarkparkAPIError && err.status !== void 0 && err.status >= 500) return true;
  return false;
}
function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
function computeDelay(policy, attempt, err) {
  if (err instanceof BarkparkRateLimitError && err.retryAfterMs !== void 0) {
    return Math.max(0, err.retryAfterMs);
  }
  const backoff = policy.baseMs * Math.pow(2, attempt - 1);
  let delay = Math.min(backoff, policy.maxBackoffMs);
  if (policy.jitter === true && delay > 0) {
    delay = delay * (1 + (Math.random() * 0.5 - 0.25));
  }
  return delay;
}
async function retry(fn, policy) {
  const decide = policy.shouldRetry ?? defaultShouldRetry;
  let attempt = 1;
  for (; ; ) {
    try {
      return await fn(attempt);
    } catch (err) {
      if (attempt >= policy.maxAttempts || !decide(err, attempt)) throw err;
      const delay = computeDelay(policy, attempt, err);
      if (delay > 0) await sleep(delay);
      attempt += 1;
      if (policy.onBeforeAttempt) await policy.onBeforeAttempt(attempt, err);
    }
  }
}

// src/util/headers.ts
var BARKPARK_VENDOR_ACCEPT = "application/vnd.barkpark+json";
function buildBaseHeaders(extra) {
  return {
    Accept: BARKPARK_VENDOR_ACCEPT,
    "Content-Type": "application/json",
    ...{}
  };
}
function uuidv7() {
  const now = BigInt(Date.now());
  const bytes = new Uint8Array(16);
  bytes[0] = Number(now >> 40n & 0xffn);
  bytes[1] = Number(now >> 32n & 0xffn);
  bytes[2] = Number(now >> 24n & 0xffn);
  bytes[3] = Number(now >> 16n & 0xffn);
  bytes[4] = Number(now >> 8n & 0xffn);
  bytes[5] = Number(now & 0xffn);
  const rand = new Uint8Array(10);
  const g = globalThis;
  if (g?.crypto?.getRandomValues) {
    g.crypto.getRandomValues(rand);
  } else {
    for (let i = 0; i < 10; i++) rand[i] = Math.floor(Math.random() * 256);
  }
  bytes.set(rand, 6);
  bytes[6] = bytes[6] & 15 | 112;
  bytes[8] = bytes[8] & 63 | 128;
  const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20, 32)}`;
}
function pickRequestId(body) {
  if (!body || typeof body !== "object") return void 0;
  const b = body;
  const snake = b["request_id"];
  if (typeof snake === "string" && snake.length > 0) return snake;
  const camel = b["requestId"];
  if (typeof camel === "string" && camel.length > 0) return camel;
  return void 0;
}

// src/transport.ts
function hasHeader(h, name) {
  const lower = name.toLowerCase();
  for (const k of Object.keys(h)) {
    if (k.toLowerCase() === lower) return true;
  }
  return false;
}
function headersToRecord(h) {
  const out = {};
  h.forEach((v, k) => {
    out[k] = v;
  });
  return out;
}
function parseRetryAfter(raw) {
  if (raw === null || raw.length === 0) return void 0;
  const n = Number(raw);
  if (Number.isFinite(n)) return Math.max(0, n * 1e3);
  const date = Date.parse(raw);
  if (Number.isFinite(date)) return Math.max(0, date - Date.now());
  return void 0;
}
function strOrUndefined(v) {
  return typeof v === "string" && v.length > 0 ? v : void 0;
}
async function decodeErrorAndThrow(response, url) {
  const status = response.status;
  const requestIdHeader = response.headers.get("x-request-id") ?? void 0;
  const raw = await response.text();
  let parsed = void 0;
  if (raw.length > 0) {
    try {
      parsed = JSON.parse(raw);
    } catch {
      const apiOpts = {
        status,
        body: raw,
        url
      };
      if (requestIdHeader !== void 0) apiOpts.requestId = requestIdHeader;
      throw new BarkparkAPIError("unexpected non-JSON response", apiOpts);
    }
  }
  const envelope = parsed !== null && typeof parsed === "object" && "error" in parsed ? parsed.error : void 0;
  const code = envelope ? strOrUndefined(envelope["code"]) : void 0;
  const message = (envelope ? strOrUndefined(envelope["message"]) : void 0) ?? `HTTP ${String(status)}`;
  const requestId = pickRequestId(envelope) ?? requestIdHeader;
  const details = envelope && envelope["details"] !== void 0 && typeof envelope["details"] === "object" ? envelope["details"] : void 0;
  const base = { url, status };
  if (requestId !== void 0) base.requestId = requestId;
  if (status === 401 || code === "unauthorized" || code === "unauthenticated" || code === "invalid_token") {
    throw new BarkparkAuthError(message, base);
  }
  if (code === "hmac_failed") {
    throw new BarkparkHmacError(message, base);
  }
  if (status === 429 || code === "rate_limited") {
    const headerMs = parseRetryAfter(response.headers.get("retry-after"));
    const bodySec = details?.["retry_after"];
    const retryAfterMs = typeof bodySec === "number" ? Math.max(0, bodySec * 1e3) : headerMs;
    const opts = { ...base };
    if (retryAfterMs !== void 0) opts.retryAfterMs = retryAfterMs;
    throw new BarkparkRateLimitError(message, opts);
  }
  if (status === 412 || code === "precondition_failed") {
    const expected = strOrUndefined(details?.["expected"]);
    const actualRev = strOrUndefined(details?.["actual"]);
    const opts = { ...base };
    if (expected !== void 0) opts.serverEtag = expected;
    if (actualRev !== void 0) opts.serverDoc = { rev: actualRev };
    throw new BarkparkConflictError(message, opts);
  }
  if (code === "schema_mismatch" || code === "apiversion_mismatch") {
    const opts = { ...base };
    const cv = strOrUndefined(details?.["client_api_version"]);
    const minV = strOrUndefined(details?.["server_min_api_version"]);
    const maxV = strOrUndefined(details?.["server_max_api_version"]);
    const lh = strOrUndefined(details?.["local_schema_hash"]);
    const rh = strOrUndefined(details?.["remote_schema_hash"]);
    if (cv !== void 0) opts.clientApiVersion = cv;
    if (minV !== void 0) opts.serverMinApiVersion = minV;
    if (maxV !== void 0) opts.serverMaxApiVersion = maxV;
    if (lh !== void 0) opts.localSchemaHash = lh;
    if (rh !== void 0) opts.remoteSchemaHash = rh;
    throw new BarkparkSchemaMismatchError(message, opts);
  }
  if (status === 422 || code === "validation_failed") {
    const opts = { ...base };
    if (details !== void 0) {
      const issues = [];
      for (const [field, msgs] of Object.entries(details)) {
        if (Array.isArray(msgs)) {
          for (const m of msgs) issues.push({ field, message: m });
        } else {
          issues.push({ field, message: msgs });
        }
      }
      if (issues.length > 0) opts.issues = issues;
    }
    throw new BarkparkValidationError(message, opts);
  }
  if (status === 409 || code === "conflict") {
    throw new BarkparkConflictError(message, base);
  }
  if (status === 404 || code === "not_found" || code === "schema_unknown") {
    throw new BarkparkNotFoundError(message, base);
  }
  const genericOpts = { ...base };
  genericOpts.body = parsed ?? raw;
  throw new BarkparkAPIError(message, genericOpts);
}
function pickPolicy(opts) {
  const kind = opts.kind ?? "read";
  if (kind === "write") {
    return opts.retryPolicy === "on-idempotency-key" ? { ...IDEMPOTENT_WRITE_POLICY } : { ...DEFAULT_WRITE_POLICY };
  }
  return { ...DEFAULT_READ_POLICY };
}
async function request(config, path, opts = {}) {
  const fetchFn = config.fetch ?? globalThis.fetch;
  if (typeof fetchFn !== "function") {
    throw new BarkparkNetworkError("fetch unavailable in this runtime");
  }
  if (!path.startsWith("/")) {
    throw new BarkparkValidationError("transport path must start with /", {
      reason: "path-not-absolute"
    });
  }
  const url = `${config.projectUrl.replace(/\/$/, "")}${path}`;
  const method = opts.method ?? "GET";
  const headers = buildBaseHeaders();
  if (config.token !== void 0 && config.token.length > 0) {
    headers["Authorization"] = `Bearer ${config.token}`;
  }
  const tagPrefix = config.requestTagPrefix ?? "";
  if (tagPrefix.length > 0) {
    headers["X-Barkpark-Request-Tag"] = `${tagPrefix}-${uuidv7()}`;
  }
  if (opts.headers !== void 0) {
    for (const [k, v] of Object.entries(opts.headers)) headers[k] = v;
  }
  const policy = pickPolicy(opts);
  if (opts.retryPolicy === "on-idempotency-key" && !hasHeader(headers, "idempotency-key")) {
    policy.onBeforeAttempt = () => {
      headers["Idempotency-Key"] = uuidv7();
    };
  }
  const timeoutMs = config.timeoutMs;
  return retry(async (attempt) => {
    let timeoutTimer;
    let timedOut = false;
    let attemptSignal = opts.signal;
    if (timeoutMs !== void 0 && timeoutMs > 0) {
      const ctrl = new AbortController();
      timeoutTimer = setTimeout(() => {
        timedOut = true;
        ctrl.abort();
      }, timeoutMs);
      if (opts.signal !== void 0) {
        if (opts.signal.aborted) ctrl.abort();
        else opts.signal.addEventListener("abort", () => ctrl.abort(), { once: true });
      }
      attemptSignal = ctrl.signal;
    }
    const startedAt = typeof performance !== "undefined" ? performance.now() : Date.now();
    const reqCtx = {
      method,
      url,
      headers,
      attempt,
      startedAt
    };
    if (opts.body !== void 0) reqCtx.body = opts.body;
    if (config.onBeforeRequest) await config.onBeforeRequest(reqCtx);
    const init = {
      method: reqCtx.method,
      headers: reqCtx.headers
    };
    if (reqCtx.body !== void 0) {
      init.body = typeof reqCtx.body === "string" ? reqCtx.body : JSON.stringify(reqCtx.body);
    }
    if (attemptSignal !== void 0) init.signal = attemptSignal;
    let response;
    try {
      response = await fetchFn(reqCtx.url, init);
    } catch (err) {
      if (timeoutTimer !== void 0) clearTimeout(timeoutTimer);
      if (timedOut) {
        const opts2 = {
          url: reqCtx.url,
          cause: err
        };
        if (timeoutMs !== void 0) opts2.timeoutMs = timeoutMs;
        throw new BarkparkTimeoutError("request timed out", opts2);
      }
      throw new BarkparkNetworkError(
        err instanceof Error ? err.message : "network error",
        { url: reqCtx.url, cause: err }
      );
    }
    if (timeoutTimer !== void 0) clearTimeout(timeoutTimer);
    if (config.onResponse) {
      const endedAt = typeof performance !== "undefined" ? performance.now() : Date.now();
      const respHeaders = headersToRecord(response.headers);
      const respCtx = {
        status: response.status,
        ok: response.ok,
        url: reqCtx.url,
        headers: respHeaders,
        durationMs: endedAt - startedAt,
        attempt
      };
      const rid = strOrUndefined(respHeaders["x-request-id"]);
      if (rid !== void 0) respCtx.requestId = rid;
      const etagRaw = strOrUndefined(respHeaders["etag"]);
      if (etagRaw !== void 0) respCtx.etag = etagRaw.replace(/^"|"$/g, "");
      await config.onResponse(respCtx);
    }
    if (opts.rawResponse === true) {
      return { data: response, response };
    }
    if (response.ok) {
      if (response.status === 204) {
        return { data: void 0, response };
      }
      const text = await response.text();
      if (text.length === 0) {
        return { data: void 0, response };
      }
      try {
        return { data: JSON.parse(text), response };
      } catch (err) {
        throw new BarkparkAPIError("unexpected non-JSON response", {
          status: response.status,
          body: text,
          url: reqCtx.url,
          cause: err
        });
      }
    }
    await decodeErrorAndThrow(response, reqCtx.url);
    throw new BarkparkAPIError("unreachable", { status: response.status, url: reqCtx.url });
  }, policy);
}

// src/doc.ts
function stripEtagQuotes(raw) {
  if (raw === null) return void 0;
  const trimmed = raw.replace(/^W\//, "").replace(/^"|"$/g, "");
  return trimmed.length > 0 ? trimmed : void 0;
}
async function getDoc(config, type, id, opts) {
  const perspective = opts?.perspective ?? config.perspective;
  const query = perspective !== void 0 ? `?perspective=${encodeURIComponent(perspective)}` : "";
  const path = `${scopePrefix(config)}/v1/data/doc/${encodeURIComponent(config.dataset)}/${encodeURIComponent(type)}/${encodeURIComponent(id)}${query}`;
  try {
    const reqOpts = { kind: "read" };
    if (opts?.signal !== void 0) reqOpts.signal = opts.signal;
    const { data, response } = await request(config, path, reqOpts);
    const doc = data !== null && typeof data === "object" && "result" in data ? data.result : data;
    const etag = stripEtagQuotes(response.headers.get("ETag"));
    const result = { data: doc };
    if (etag !== void 0) result.etag = etag;
    return result;
  } catch (err) {
    if (err instanceof BarkparkNotFoundError) return { data: null };
    throw err;
  }
}

// src/filter-builder.ts
var VALID_OPS = ["eq", "in", "contains", "gt", "gte", "lt", "lte"];
function makeFilterExpression(field, op, value) {
  if (typeof field !== "string" || field.length === 0) {
    throw new BarkparkValidationError("filter field must be a non-empty string", { field: "field" });
  }
  if (!VALID_OPS.includes(op)) {
    throw new BarkparkValidationError(`unknown filter op: ${op}`, {
      field: "op",
      issues: [{ op, allowed: VALID_OPS }]
    });
  }
  if (op === "in" && !Array.isArray(value)) {
    throw new BarkparkValidationError(`op 'in' requires array value`, { field: "value" });
  }
  if (op !== "in" && Array.isArray(value)) {
    throw new BarkparkValidationError(`op '${op}' does not accept array`, { field: "value" });
  }
  return { field, op, value };
}
function createDocsBuilder(executor) {
  const state = { filters: [] };
  const b = {
    where(field, op, value) {
      state.filters.push(makeFilterExpression(field, op, value));
      return b;
    },
    order(spec) {
      if (!/^(_updatedAt|_createdAt):(asc|desc)$/.test(spec)) {
        throw new BarkparkValidationError(`invalid order spec: ${spec}`, { field: "order" });
      }
      state.order = spec;
      return b;
    },
    limit(n) {
      if (!Number.isInteger(n) || n < 1 || n > 1e3) {
        throw new BarkparkValidationError(`limit must be an integer 1..1000`, { field: "limit" });
      }
      state.limit = n;
      return b;
    },
    offset(n) {
      if (!Number.isInteger(n) || n < 0) {
        throw new BarkparkValidationError(`offset must be a non-negative integer`, {
          field: "offset"
        });
      }
      state.offset = n;
      return b;
    },
    async find() {
      return executor(state);
    },
    async findOne() {
      const old = state.limit;
      state.limit = 1;
      try {
        const [doc] = await executor(state);
        return doc ?? null;
      } finally {
        if (old === void 0) delete state.limit;
        else state.limit = old;
      }
    }
  };
  return b;
}
function buildQueryString(state) {
  const params = new URLSearchParams();
  for (const f of state.filters) {
    const key = `filter[${f.field}][${f.op}]`;
    let encoded;
    if (Array.isArray(f.value)) {
      encoded = f.value.map((v) => String(v)).join(",");
    } else if (f.value === null) {
      encoded = "";
    } else {
      encoded = String(f.value);
    }
    params.append(key, encoded);
  }
  if (state.order) params.set("order", state.order);
  if (state.limit !== void 0) params.set("limit", String(state.limit));
  if (state.offset !== void 0) params.set("offset", String(state.offset));
  return params.toString();
}

// src/docs.ts
function createDocsOperation(config, type, opts) {
  return createDocsBuilder(async (state) => {
    const perspective = opts?.perspective ?? config.perspective;
    const qs = buildQueryString(state);
    const parts = [];
    if (qs.length > 0) parts.push(qs);
    if (perspective !== void 0) parts.push(`perspective=${encodeURIComponent(perspective)}`);
    const query = parts.length > 0 ? `?${parts.join("&")}` : "";
    const path = `${scopePrefix(config)}/v1/data/query/${encodeURIComponent(config.dataset)}/${encodeURIComponent(type)}${query}`;
    const reqOpts = { kind: "read" };
    if (opts?.signal !== void 0) reqOpts.signal = opts.signal;
    const { data } = await request(config, path, reqOpts);
    return data.result?.documents ?? data.documents ?? [];
  });
}

// src/patch.ts
var FORBIDDEN_SET_KEYS = /* @__PURE__ */ new Set([
  "_id",
  "_type",
  "_rev",
  "_createdAt",
  "_updatedAt",
  "_draft",
  "_publishedId"
]);
function createPatch(config, id) {
  if (typeof id !== "string" || id.length === 0) {
    throw new BarkparkValidationError("patch requires a non-empty document id", { field: "id" });
  }
  const state = { id, set: {} };
  const b = {
    set(fields) {
      if (fields === null || typeof fields !== "object" || Array.isArray(fields)) {
        throw new BarkparkValidationError("patch.set requires a plain object", { field: "set" });
      }
      for (const k of Object.keys(fields)) {
        if (FORBIDDEN_SET_KEYS.has(k)) {
          throw new BarkparkValidationError(
            `patch.set cannot modify system field: ${k}`,
            { field: k }
          );
        }
      }
      Object.assign(state.set, fields);
      return b;
    },
    // Phoenix Phase 1A does NOT implement patch.inc (see w6.3-phoenix-contract.md §mutate).
    // Throw eagerly at chain-time so callers discover the limitation immediately rather
    // than via a confusing 422 at commit time.
    inc(_fields) {
      throw new BarkparkValidationError(
        "patch.inc is not implemented in Barkpark Phase 1A. Use patch.set with a pre-computed value, or roll a transaction with createOrReplace.",
        { field: "inc" }
      );
    },
    async commit(opts) {
      if (opts?.ifMatch !== void 0) state.ifMatch = opts.ifMatch;
      if (Object.keys(state.set).length === 0) {
        throw new BarkparkValidationError(
          "patch.commit requires at least one set() call before commit",
          { field: "set" }
        );
      }
      const patchBody = {
        id: state.id,
        set: state.set
      };
      if (state.ifMatch !== void 0) patchBody.ifMatch = state.ifMatch;
      const body = { mutations: [{ patch: patchBody }] };
      const reqOpts = {
        method: "POST",
        body,
        kind: "write"
      };
      if (opts?.idempotencyKey !== void 0 && opts.idempotencyKey.length > 0) {
        reqOpts.headers = { "Idempotency-Key": opts.idempotencyKey };
      }
      if (opts?.retry === true) {
        reqOpts.retryPolicy = "on-idempotency-key";
      }
      const { data } = await request(
        config,
        `${scopePrefix(config)}/v1/data/mutate/${config.dataset}`,
        reqOpts
      );
      const first = data.results[0];
      if (first === void 0) {
        throw new BarkparkAPIError("mutate response missing results[0]", {
          status: 200,
          body: data
        });
      }
      return first;
    }
  };
  return b;
}

// src/transaction.ts
var FORBIDDEN_PATCH_FIELDS = /* @__PURE__ */ new Set([
  "_id",
  "_type",
  "_rev",
  "_createdAt",
  "_updatedAt",
  "_draft",
  "_publishedId"
]);
function createTransaction(config) {
  const mutations = [];
  const tx = {
    create(doc) {
      if (!doc || typeof doc !== "object" || !("_type" in doc) || typeof doc._type !== "string") {
        throw new BarkparkValidationError("transaction.create requires a doc with _type", {
          field: "_type"
        });
      }
      mutations.push({ create: doc });
      return tx;
    },
    createOrReplace(doc) {
      if (!doc || !doc._id || !doc._type) {
        throw new BarkparkValidationError(
          "transaction.createOrReplace requires _id and _type",
          { field: "_id" }
        );
      }
      mutations.push({ createOrReplace: doc });
      return tx;
    },
    patch(id, build, opts) {
      const set = {};
      const miniBuilder = {
        set(fields) {
          if (fields == null || typeof fields !== "object" || Array.isArray(fields)) {
            throw new BarkparkValidationError("patch.set requires an object", { field: "set" });
          }
          for (const k of Object.keys(fields)) {
            if (FORBIDDEN_PATCH_FIELDS.has(k)) {
              throw new BarkparkValidationError(`patch.set cannot modify ${k}`, { field: k });
            }
          }
          Object.assign(set, fields);
          return miniBuilder;
        },
        inc(_fields) {
          throw new BarkparkValidationError("patch.inc not implemented in Phase 1A", {
            field: "inc"
          });
        },
        async commit() {
          throw new BarkparkValidationError(
            "inner patch.commit() is not valid inside transaction \u2014 use tx.commit()",
            { field: "commit" }
          );
        }
      };
      build(miniBuilder);
      if (Object.keys(set).length === 0) {
        throw new BarkparkValidationError(
          `patch on ${id} inside transaction had no set()`,
          { field: "set" }
        );
      }
      const patchOp = { id, set };
      if (opts?.ifMatch !== void 0) patchOp.ifMatch = opts.ifMatch;
      mutations.push({ patch: patchOp });
      return tx;
    },
    publish(id, type) {
      if (!id || !type) {
        throw new BarkparkValidationError("publish requires id and type", {
          field: !id ? "id" : "type"
        });
      }
      mutations.push({ publish: { id, type } });
      return tx;
    },
    unpublish(id, type) {
      if (!id || !type) {
        throw new BarkparkValidationError("unpublish requires id and type", {
          field: !id ? "id" : "type"
        });
      }
      mutations.push({ unpublish: { id, type } });
      return tx;
    },
    delete(id, type, opts) {
      if (!id || !type) {
        throw new BarkparkValidationError("delete requires id and type", {
          field: !id ? "id" : "type"
        });
      }
      const op = { id, type };
      if (opts?.ifMatch !== void 0) op.ifMatch = opts.ifMatch;
      mutations.push({ delete: op });
      return tx;
    },
    async commit(opts) {
      if (mutations.length === 0) {
        throw new BarkparkValidationError("transaction.commit called with no mutations", {
          field: "mutations"
        });
      }
      const headers = {};
      if (opts?.idempotencyKey !== void 0 && opts.idempotencyKey.length > 0) {
        headers["Idempotency-Key"] = opts.idempotencyKey;
      }
      const { data } = await request(
        config,
        `${scopePrefix(config)}/v1/data/mutate/${config.dataset}`,
        {
          method: "POST",
          body: { mutations },
          headers,
          kind: "write",
          retryPolicy: opts?.retry === true ? "on-idempotency-key" : "none"
        }
      );
      return data;
    }
  };
  return tx;
}

// src/publish.ts
async function publishDoc(config, id, type) {
  if (!id || !type) {
    throw new BarkparkValidationError("publishDoc requires id and type", {
      field: !id ? "id" : "type"
    });
  }
  const { data } = await request(
    config,
    `${scopePrefix(config)}/v1/data/mutate/${config.dataset}`,
    {
      method: "POST",
      body: { mutations: [{ publish: { id, type } }] },
      kind: "write"
    }
  );
  const first = data.results[0];
  if (!first) {
    throw new BarkparkValidationError("publish: server returned empty results", {
      field: "results"
    });
  }
  return first;
}
async function unpublishDoc(config, id, type) {
  if (!id || !type) {
    throw new BarkparkValidationError("unpublishDoc requires id and type", {
      field: !id ? "id" : "type"
    });
  }
  const { data } = await request(
    config,
    `${scopePrefix(config)}/v1/data/mutate/${config.dataset}`,
    {
      method: "POST",
      body: { mutations: [{ unpublish: { id, type } }] },
      kind: "write"
    }
  );
  const first = data.results[0];
  if (!first) {
    throw new BarkparkValidationError("unpublish: server returned empty results", {
      field: "results"
    });
  }
  return first;
}

// src/util/edge-detect.ts
function detectEdgeRuntime() {
  const g = globalThis;
  if (g?.EdgeRuntime) return "vercel-edge-runtime";
  const nextRuntime = g?.process?.env?.NEXT_RUNTIME;
  if (nextRuntime === "edge") return "next-runtime-edge";
  const ua = g?.navigator?.userAgent;
  if (typeof ua === "string" && ua.includes("Cloudflare-Workers")) return "cloudflare-workers";
  if (typeof g?.WebSocketPair !== "undefined") return "workerd";
  return null;
}

// src/listen.ts
function createListenHandle(config, type, filter, opts) {
  const edge = detectEdgeRuntime();
  if (edge !== null) {
    throw new BarkparkEdgeRuntimeError(
      `listen() is not supported in ${edge} runtime \u2014 streaming fetch is unavailable. Use polling via client.docs() on a short interval instead.`
    );
  }
  const abortController = new AbortController();
  if (opts?.signal) {
    if (opts.signal.aborted) {
      abortController.abort(opts.signal.reason);
    } else {
      opts.signal.addEventListener(
        "abort",
        () => abortController.abort(opts.signal?.reason),
        { once: true }
      );
    }
  }
  let unsubscribed = false;
  let lastEventId;
  let reconnectCount = 0;
  const maxReconnects = opts?.maxReconnects ?? 5;
  const reconnectBase = opts?.reconnectBaseMs ?? 500;
  const handle = {
    unsubscribe() {
      if (unsubscribed) return;
      unsubscribed = true;
      try {
        abortController.abort(new BarkparkNetworkError("listen unsubscribed by caller"));
      } catch {
      }
      opts?.onUnsubscribe?.();
    },
    async *[Symbol.asyncIterator]() {
      try {
        outer: while (!unsubscribed) {
          try {
            const fetchImpl = config.fetch ?? globalThis.fetch;
            if (typeof fetchImpl !== "function") {
              throw new BarkparkNetworkError("fetch is unavailable in this runtime");
            }
            const base = config.projectUrl.replace(/\/+$/, "");
            const prefix = scopePrefix(config);
            const url = new URL(`${base}${prefix}/v1/data/listen/${config.dataset}`);
            if (type) url.searchParams.set("types", type);
            const p = opts?.perspective ?? config.perspective;
            if (p) url.searchParams.set("perspective", p);
            if (filter && typeof filter === "object") {
              for (const [k, v] of Object.entries(filter)) {
                url.searchParams.set(`filter[${k}]`, String(v));
              }
            }
            const headers = {
              Accept: "text/event-stream",
              "X-Barkpark-Api-Version": config.apiVersion
            };
            if (config.token) headers.Authorization = `Bearer ${config.token}`;
            if (lastEventId !== void 0) headers["Last-Event-ID"] = lastEventId;
            let response;
            try {
              response = await fetchImpl(url.toString(), {
                method: "GET",
                headers,
                signal: abortController.signal
              });
            } catch (fetchErr) {
              if (unsubscribed || abortController.signal.aborted) return;
              throw new BarkparkNetworkError("listen: fetch failed", { cause: fetchErr, url: url.toString() });
            }
            if (response.status === 401 || response.status === 403) {
              throw new BarkparkAuthError(`listen: ${response.status} auth failed`, {
                status: response.status,
                url: url.toString()
              });
            }
            if (!response.ok) {
              throw new BarkparkAPIError(`listen: HTTP ${response.status}`, {
                status: response.status,
                url: url.toString()
              });
            }
            const ct = response.headers.get("content-type") ?? "";
            if (!ct.includes("text/event-stream")) {
              throw new BarkparkAPIError(
                `listen: expected text/event-stream, got ${ct || "(none)"}`,
                { status: response.status, url: url.toString() }
              );
            }
            if (!response.body) {
              throw new BarkparkAPIError("listen: response has no body", {
                status: response.status,
                url: url.toString()
              });
            }
            reconnectCount = 0;
            const reader = response.body.getReader();
            const decoder = new TextDecoder("utf-8");
            let buffer = "";
            try {
              while (!unsubscribed) {
                const { done, value } = await reader.read();
                if (done) break;
                buffer += decoder.decode(value, { stream: true });
                let frameEnd = findFrameBoundary(buffer);
                while (frameEnd !== -1) {
                  const frame = buffer.slice(0, frameEnd.start);
                  buffer = buffer.slice(frameEnd.end);
                  const parsed = parseSseFrame(frame);
                  if (!parsed) {
                    frameEnd = findFrameBoundary(buffer);
                    continue;
                  }
                  if (parsed.eventId !== void 0) lastEventId = parsed.eventId;
                  if (parsed.dataLines.length === 0) {
                    frameEnd = findFrameBoundary(buffer);
                    continue;
                  }
                  let payload;
                  try {
                    const joined = parsed.dataLines.join("\n");
                    const v = JSON.parse(joined);
                    payload = v && typeof v === "object" ? v : {};
                  } catch {
                    frameEnd = findFrameBoundary(buffer);
                    continue;
                  }
                  const event = buildListenEvent(parsed.eventName, parsed.eventId, payload);
                  yield event;
                  frameEnd = findFrameBoundary(buffer);
                }
              }
            } finally {
              try {
                reader.releaseLock();
              } catch {
              }
            }
            if (unsubscribed) return;
            continue outer;
          } catch (err) {
            if (unsubscribed || abortController.signal.aborted) return;
            const code = err?.code;
            if (code === "BarkparkAuthError" || err instanceof BarkparkAuthError) throw err;
            const isNetworkish = err instanceof BarkparkNetworkError || err instanceof BarkparkAPIError && (err.status ?? 0) >= 500;
            if (isNetworkish && reconnectCount < maxReconnects) {
              const delay = Math.min(reconnectBase * 2 ** reconnectCount, 8e3);
              reconnectCount++;
              await sleep2(delay, abortController.signal);
              if (unsubscribed || abortController.signal.aborted) return;
              continue outer;
            }
            throw err;
          }
        }
      } finally {
        if (!unsubscribed) {
          unsubscribed = true;
          try {
            abortController.abort();
          } catch {
          }
          opts?.onUnsubscribe?.();
        }
      }
    }
  };
  return handle;
}
function parseSseFrame(frame) {
  if (frame.length === 0) return null;
  let eventName = "message";
  let eventId;
  const dataLines = [];
  for (const rawLine of frame.split("\n")) {
    const line = rawLine.replace(/\r$/, "");
    if (line.length === 0) continue;
    if (line.startsWith(":")) continue;
    const colon = line.indexOf(":");
    if (colon === -1) continue;
    const field = line.slice(0, colon);
    let val = line.slice(colon + 1);
    if (val.startsWith(" ")) val = val.slice(1);
    if (field === "event") {
      eventName = val === "welcome" || val === "mutation" ? val : "message";
    } else if (field === "id") {
      eventId = val;
    } else if (field === "data") {
      dataLines.push(val);
    }
  }
  return { eventName, eventId, dataLines };
}
function findFrameBoundary(buffer) {
  const lf = buffer.indexOf("\n\n");
  const crlf = buffer.indexOf("\r\n\r\n");
  if (lf === -1 && crlf === -1) return -1;
  if (lf !== -1 && (crlf === -1 || lf < crlf)) return { start: lf, end: lf + 2 };
  return { start: crlf, end: crlf + 4 };
}
function buildListenEvent(sseEvent, sseEventId, payload) {
  const eventType = sseEvent === "mutation" ? "mutation" : "welcome";
  const eventId = sseEventId ?? (payload["eventId"] !== void 0 && payload["eventId"] !== null ? String(payload["eventId"]) : "");
  const evt = { eventId, type: eventType };
  const m = payload["mutation"];
  if (m === "create" || m === "update" || m === "delete" || m === "publish" || m === "unpublish") {
    evt.mutation = m;
  }
  if (typeof payload["documentId"] === "string") evt.documentId = payload["documentId"];
  if (typeof payload["rev"] === "string") evt.rev = payload["rev"];
  if ("previousRev" in payload) {
    const p = payload["previousRev"];
    evt.previousRev = p === null || typeof p === "string" ? p : null;
  }
  if ("result" in payload && payload["result"] !== void 0) {
    evt.result = payload["result"];
  }
  if (Array.isArray(payload["syncTags"])) {
    evt.syncTags = payload["syncTags"].filter((x) => typeof x === "string");
  }
  return evt;
}
function sleep2(ms, signal) {
  return new Promise((resolve) => {
    const onAbort = () => {
      clearTimeout(timer);
      resolve();
    };
    if (signal.aborted) return resolve();
    const timer = setTimeout(() => {
      signal.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    signal.addEventListener("abort", onAbort, { once: true });
  });
}

// src/fetchRaw.ts
async function fetchRawDoc(config, path, init) {
  if (!path.startsWith("/")) {
    throw new BarkparkValidationError(`fetchRaw path must start with "/"`, { field: "path" });
  }
  const prefix = scopePrefix(config);
  if (prefix.length > 0 && !path.startsWith(`${prefix}/`) && path !== prefix) {
    path = `${prefix}${path}`;
  }
  const method = (init?.method ?? "GET").toUpperCase();
  const opts = {
    method,
    rawResponse: true,
    kind: method === "GET" ? "read" : "write"
  };
  if (init?.body !== void 0 && init.body !== null) {
    opts.body = init.body;
  }
  if (init?.headers !== void 0) {
    const h = {};
    if (init.headers instanceof Headers) {
      init.headers.forEach((v, k) => {
        h[k] = v;
      });
    } else if (Array.isArray(init.headers)) {
      for (const [k, v] of init.headers) h[k] = v;
    } else {
      for (const [k, v] of Object.entries(init.headers)) h[k] = v;
    }
    opts.headers = h;
  }
  if (init?.signal != null) opts.signal = init.signal;
  const { data } = await request(config, path, opts);
  return data;
}

// src/tenancy.ts
async function listWorkspaces(config) {
  const { data } = await request(config, "/api/workspaces", {
    kind: "read"
  });
  return data?.workspaces ?? [];
}
async function listProjects(config, workspaceSlug) {
  if (typeof workspaceSlug !== "string" || workspaceSlug.length === 0) {
    throw new BarkparkValidationError("listProjects requires a workspace slug", {
      field: "workspaceSlug"
    });
  }
  const { data } = await request(
    config,
    `/api/workspaces/${encodeURIComponent(workspaceSlug)}/projects`,
    { kind: "read" }
  );
  return data?.projects ?? [];
}

// src/handshake.ts
function cacheKey(config) {
  return `${config.projectUrl}|${config.dataset}`;
}
function createHandshakeCache() {
  const map = /* @__PURE__ */ new Map();
  return {
    get(config) {
      const key = cacheKey(config);
      const entry = map.get(key);
      if (entry?.resolved) return Promise.resolve(entry.resolved);
      if (entry?.inflight) return entry.inflight;
      const inflight = (async () => {
        const prefix = scopePrefix(config);
        const { data } = await request(config, `${prefix}/v1/meta?dataset=${encodeURIComponent(config.dataset)}`, {
          method: "GET",
          kind: "read"
        });
        return data;
      })();
      const newEntry = { inflight };
      map.set(key, newEntry);
      inflight.then(
        (value) => {
          map.set(key, { resolved: value });
        },
        () => {
          map.delete(key);
        }
      );
      return inflight;
    },
    invalidate(config) {
      map.delete(cacheKey(config));
    },
    clear() {
      map.clear();
    }
  };
}

// src/client.ts
var API_VERSION_RE = /^\d{4}-\d{2}-\d{2}$/;
var DATASET_RE = /^[a-z0-9][a-z0-9_-]*$/;
var SLUG_RE = /^[a-z0-9][a-z0-9_-]*$/;
var PERSPECTIVES = ["published", "drafts", "raw"];
function validateConfig(config) {
  if (typeof config.projectUrl !== "string" || config.projectUrl.length === 0) {
    throw new BarkparkValidationError("invalid projectUrl: must be absolute http(s) URL", {
      field: "projectUrl"
    });
  }
  let parsed;
  try {
    parsed = new URL(config.projectUrl);
  } catch {
    throw new BarkparkValidationError("invalid projectUrl: must be absolute http(s) URL", {
      field: "projectUrl"
    });
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    throw new BarkparkValidationError("invalid projectUrl: must be absolute http(s) URL", {
      field: "projectUrl"
    });
  }
  if (typeof config.dataset !== "string" || config.dataset.length === 0 || !DATASET_RE.test(config.dataset)) {
    throw new BarkparkValidationError(
      "invalid dataset: must match /^[a-z0-9][a-z0-9_-]*$/",
      { field: "dataset" }
    );
  }
  if (config.workspace !== void 0) {
    if (typeof config.workspace !== "string" || config.workspace.length === 0 || !SLUG_RE.test(config.workspace)) {
      throw new BarkparkValidationError(
        "invalid workspace: must match /^[a-z0-9][a-z0-9_-]*$/",
        { field: "workspace" }
      );
    }
  }
  if (config.project !== void 0) {
    if (typeof config.project !== "string" || config.project.length === 0 || !SLUG_RE.test(config.project)) {
      throw new BarkparkValidationError(
        "invalid project: must match /^[a-z0-9][a-z0-9_-]*$/",
        { field: "project" }
      );
    }
  }
  if (typeof config.apiVersion !== "string" || !API_VERSION_RE.test(config.apiVersion)) {
    throw new BarkparkValidationError("invalid apiVersion: must be YYYY-MM-DD", {
      field: "apiVersion"
    });
  }
  if (config.token !== void 0) {
    if (typeof config.token !== "string" || config.token.length === 0) {
      throw new BarkparkValidationError("invalid token: must be non-empty string", {
        field: "token"
      });
    }
  }
  if (config.perspective !== void 0 && !PERSPECTIVES.includes(config.perspective)) {
    throw new BarkparkValidationError(
      "invalid perspective: must be one of 'published' | 'drafts' | 'raw'",
      { field: "perspective" }
    );
  }
  if (config.useCdn === true && config.perspective === "drafts") {
    throw new BarkparkValidationError(
      "useCdn:true is incompatible with perspective:'drafts'",
      { field: "useCdn" }
    );
  }
}
function filtersToRecord(filter) {
  if (!filter || filter.length === 0) return void 0;
  const out = {};
  for (const f of filter) {
    if (f.op !== "eq") {
      throw new BarkparkValidationError(
        `listen filter op '${f.op}' is not supported in Phase 1A (eq only)`,
        { field: "op" }
      );
    }
    out[f.field] = f.value;
  }
  return out;
}
function createClient(config) {
  validateConfig(config);
  const frozen = Object.freeze({ ...config });
  const handshakeCache = createHandshakeCache();
  const client = {
    config: frozen,
    withConfig(patch) {
      return createClient({ ...frozen, ...patch });
    },
    async doc(type, id) {
      const { data } = await getDoc(frozen, type, id);
      return data;
    },
    docs(type) {
      return createDocsOperation(frozen, type);
    },
    patch(id) {
      return createPatch(frozen, id);
    },
    transaction() {
      return createTransaction(frozen);
    },
    async publish(id, type) {
      return publishDoc(frozen, id, type);
    },
    async unpublish(id, type) {
      return unpublishDoc(frozen, id, type);
    },
    listen(type, filter) {
      return createListenHandle(frozen, type, filtersToRecord(filter));
    },
    async fetchRaw(path, init) {
      const response = await fetchRawDoc(frozen, path, init);
      return response;
    },
    async listWorkspaces() {
      return listWorkspaces(frozen);
    },
    async listProjects(workspaceSlug) {
      return listProjects(frozen, workspaceSlug);
    },
    handshake() {
      return handshakeCache.get(frozen);
    },
    __handshakeCache: handshakeCache
  };
  return client;
}

// src/index.ts
function typedClient(client) {
  return client;
}
function defineActions(client) {
  return client;
}

exports.BarkparkAPIError = BarkparkAPIError;
exports.BarkparkAuthError = BarkparkAuthError;
exports.BarkparkConflictError = BarkparkConflictError;
exports.BarkparkEdgeRuntimeError = BarkparkEdgeRuntimeError;
exports.BarkparkError = BarkparkError;
exports.BarkparkHmacError = BarkparkHmacError;
exports.BarkparkNetworkError = BarkparkNetworkError;
exports.BarkparkNotFoundError = BarkparkNotFoundError;
exports.BarkparkRateLimitError = BarkparkRateLimitError;
exports.BarkparkSchemaMismatchError = BarkparkSchemaMismatchError;
exports.BarkparkTimeoutError = BarkparkTimeoutError;
exports.BarkparkValidationError = BarkparkValidationError;
exports.buildQueryString = buildQueryString;
exports.createClient = createClient;
exports.createDocsBuilder = createDocsBuilder;
exports.createDocsOperation = createDocsOperation;
exports.createHandshakeCache = createHandshakeCache;
exports.createListenHandle = createListenHandle;
exports.createPatch = createPatch;
exports.createTransaction = createTransaction;
exports.defineActions = defineActions;
exports.fetchRawDoc = fetchRawDoc;
exports.getDoc = getDoc;
exports.listProjects = listProjects;
exports.listWorkspaces = listWorkspaces;
exports.makeFilterExpression = makeFilterExpression;
exports.publishDoc = publishDoc;
exports.scopePrefix = scopePrefix;
exports.typedClient = typedClient;
exports.unpublishDoc = unpublishDoc;
//# sourceMappingURL=index.cjs.map
//# sourceMappingURL=index.cjs.map