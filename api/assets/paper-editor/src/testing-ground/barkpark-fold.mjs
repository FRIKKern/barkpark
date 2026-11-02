const LOOPBACK = /^(localhost|127\.\d+\.\d+\.\d+|\[::1\])$/;
const TYPE = "post";

export function barkparkFold(origin, token) {
  const base = new URL(origin);
  if (!LOOPBACK.test(base.hostname)) throw new Error(`refused: ${base.hostname} is not this machine. The testing ground folds only through a Barkpark on localhost.`);
  const id = `tg-${process.pid}`;
  const doc = `/v1/data/doc/production/${TYPE}/${id}`;
  const call = async (method, path, body) => {
    const res = await fetch(new URL(path, base), {
      method,
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: body && JSON.stringify(body),
    });
    const json = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(json.error?.code ? `${json.error.code}: ${json.error.message}` : `HTTP ${res.status} from ${path}`);
    return json;
  };
  return {
    name: `Local Barkpark at ${base.origin}`,
    apply: async (blocks, ops) => {
      await call("POST", "/v1/data/mutate/production", { mutations: [{ createOrReplace: { _type: TYPE, _id: id, blocks } }] });
      const before = await call("GET", `${doc}?perspective=raw`);
      await call("POST", `${doc}/ops`, { ops, ifRev: before.result._rev });
      return (await call("GET", `${doc}?perspective=raw`)).result.blocks;
    },
  };
}
