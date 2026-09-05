import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;

for (const name of [
  "customElements",
  "CustomEvent",
  "document",
  "DOMParser",
  "Element",
  "Event",
  "EventTarget",
  "File",
  "FormData",
  "HTMLElement",
  "KeyboardEvent",
  "MouseEvent",
  "MutationObserver",
  "Node",
  "NodeFilter",
  "Selection",
  "Text",
]) {
  globalThis[name] = window[name];
}

globalThis.window = window;
globalThis.sessionStorage = window.sessionStorage;
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: window.navigator,
});
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (value) => String(value) };
window.BP_PAPER_EDITOR_NO_INJECT = true;

const fetches = [];
let resolveSlowSearch;

function searchResponse(scope) {
  return {
    ok: true,
    json: async () => ({
      result: {
        hits: [
          {
            id: `file-${scope}`,
            assetDocId: `asset-${scope}`,
            originalUrl: `/media/${scope}.png`,
            originalName: `${scope}.png`,
            mimeType: "image/png",
            kind: "image",
          },
        ],
      },
    }),
  };
}

const fetchMock = async (url, options = {}) => {
  const request = { url: String(url), options };
  fetches.push(request);

  if (options.method === "POST") {
    return {
      ok: true,
      json: async () => ({
        result: {
          url: "/media/uploaded.png",
          mimeType: "image/png",
          assetDocId: "asset-uploaded",
        },
      }),
    };
  }

  if (request.url.startsWith("/w/slow/p/project/")) {
    return new Promise((resolve) => {
      resolveSlowSearch = () => resolve(searchResponse("slow"));
    });
  }

  const scope = request.url.startsWith("/w/second/p/project/")
    ? "second"
    : request.url.startsWith("/w/fast/p/project/")
      ? "fast"
      : "first";
  return searchResponse(scope);
};
globalThis.fetch = fetchMock;
window.fetch = fetchMock;

await import("../../../../priv/static/assets/bp-asset-browser.js");
await import("../../../../priv/static/assets/bp-media-picker.js");
const { BpPaperCanvas } = await import("./index.js");

assert.equal(customElements.get("bp-paper-canvas"), BpPaperCanvas);
assert.ok(customElements.get("bp-media-picker"));
assert.ok(customElements.get("bp-asset-browser"));

function mountCanvas({ id, scopePrefix, token = "", value = "" }) {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.setAttribute("data-dataset", "production");
  canvas.setAttribute("data-picker-browse", "true");
  if (scopePrefix) canvas.setAttribute("data-scope-prefix", scopePrefix);
  if (token) canvas.setAttribute("data-token", token);
  canvas.blocks = [
    {
      id,
      type: "field-image",
      label: "Cover",
      fieldName: "cover",
      value,
    },
  ];
  const batches = [];
  canvas.addEventListener("bp-canvas-ops", (event) => batches.push(event.detail.ops));
  document.body.appendChild(canvas);
  return { canvas, batches };
}

async function settle() {
  await new Promise((resolve) => setTimeout(resolve, 25));
}

const mounted = [];

try {
  const first = mountCanvas({
    id: "public-image",
    scopePrefix: "/w/first/p/project",
    token: "first-token",
  });
  mounted.push(first.canvas);
  await settle();
  first.batches.length = 0;

  const placeholder = first.canvas.querySelector(
    '[data-test-id="paper-featured-image-placeholder"]'
  );
  assert.ok(placeholder, "the empty field-image offers its real canvas affordance");
  placeholder.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  await settle();

  const browser = document.querySelector("bp-asset-browser");
  assert.ok(browser && !browser.hidden, "the placeholder opens the real asset browser");
  const firstCard = browser.querySelector(".bp-ab-card");
  assert.ok(firstCard, "the scoped media result renders as a selectable card");
  firstCard.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  first.canvas.flushPendingChanges();

  assert.deepEqual(first.batches, [
    [
      {
        op: "patch-block",
        id: "public-image",
        patch: {
          value: JSON.stringify({
            url: "/media/first.png",
            assetId: "asset-first",
            alt: "first.png",
          }),
        },
      },
    ],
  ]);
  assert.equal(
    fetches[0].url,
    "/w/first/p/project/v1/media/production/search?limit=200&offset=0&sort=updated-desc&facet.kind=image"
  );
  assert.equal(fetches[0].options.headers.Authorization, "Bearer first-token");
  assert.equal(fetches[0].options.credentials, "same-origin");

  const second = mountCanvas({
    id: "second-image",
    scopePrefix: "/w/second/p/project",
    token: "second-token",
  });
  mounted.push(second.canvas);
  await settle();
  second.canvas
    .querySelector('[data-test-id="paper-featured-image-placeholder"]')
    .dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  await settle();
  assert.equal(
    fetches.at(-1).url,
    "/w/second/p/project/v1/media/production/search?limit=200&offset=0&sort=updated-desc&facet.kind=image",
    "the reused singleton adopts the current Paper tenant scope"
  );
  assert.equal(fetches.at(-1).options.headers.Authorization, "Bearer second-token");

  const legacyPicker = document.createElement("bp-media-picker");
  legacyPicker.setAttribute("dataset", "production");
  document.body.appendChild(legacyPicker);
  mounted.push(legacyPicker);
  legacyPicker.openBrowser();
  await settle();
  assert.equal(
    fetches.at(-1).url,
    "/v1/media/production/search?limit=200&offset=0&sort=updated-desc&facet.kind=image",
    "an explicit unscoped caller retains the supported legacy route"
  );
  assert.equal(
    fetches.at(-1).options.headers.Authorization,
    undefined,
    "scope and bearer state never leak from a prior singleton invocation"
  );

  browser.setAttribute("dataset", "configured");
  browser.setAttribute("scope-prefix", "/w/configured/p/project");
  browser.setAttribute("data-token", "configured-token");
  browser.open({});
  await settle();
  assert.match(
    fetches.at(-1).url,
    /^\/w\/configured\/p\/project\/v1\/media\/configured\/search\?/,
    "standalone declarative browser configuration remains supported"
  );
  assert.equal(fetches.at(-1).options.headers.Authorization, "Bearer configured-token");
  browser.removeAttribute("dataset");
  browser.removeAttribute("scope-prefix");
  browser.removeAttribute("data-token");

  const slow = mountCanvas({
    id: "slow-image",
    scopePrefix: "/w/slow/p/project",
    token: "slow-token",
  });
  mounted.push(slow.canvas);
  await settle();
  slow.canvas
    .querySelector('[data-test-id="paper-featured-image-placeholder"]')
    .dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  await settle();
  assert.equal(typeof resolveSlowSearch, "function", "the first tenant search remains pending");

  const fast = mountCanvas({
    id: "fast-image",
    scopePrefix: "/w/fast/p/project",
  });
  mounted.push(fast.canvas);
  await settle();
  fast.canvas
    .querySelector('[data-test-id="paper-featured-image-placeholder"]')
    .dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  await settle();

  assert.equal(
    fetches.at(-1).options.headers.Authorization,
    undefined,
    "a bearer from tenant A is absent when tenant B opens with an empty token"
  );
  assert.match(browser.querySelector(".bp-ab-card").textContent, /fast\.png/);

  resolveSlowSearch();
  await settle();
  const cardsAfterSlowReply = [...browser.querySelectorAll(".bp-ab-card")];
  assert.equal(cardsAfterSlowReply.length, 1);
  assert.match(
    cardsAfterSlowReply[0].textContent,
    /fast\.png/,
    "a late tenant-A response cannot replace tenant B's results"
  );
  cardsAfterSlowReply[0].dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  fast.canvas.flushPendingChanges();
  assert.deepEqual(fast.batches, [
    [
      {
        op: "patch-block",
        id: "fast-image",
        patch: {
          value: JSON.stringify({
            url: "/media/fast.png",
            assetId: "asset-fast",
            alt: "fast.png",
          }),
        },
      },
    ],
  ]);
  assert.deepEqual(slow.batches, [], "selection is delivered only to the current picker");

  const upload = mountCanvas({
    id: "upload-image",
    scopePrefix: "/w/first/p/project",
    token: "upload-token",
  });
  mounted.push(upload.canvas);
  await settle();
  upload.batches.length = 0;

  const uploadPicker = upload.canvas.querySelector(
    '[data-test-id="paper-field-field-image"]'
  );
  assert.ok(uploadPicker, "the field-image mounts the real media picker");
  const fileInput = uploadPicker.querySelector('input[type="file"]');
  const file = new window.File([new Uint8Array([137, 80, 78, 71])], "cover.png", {
    type: "image/png",
  });
  Object.defineProperty(fileInput, "files", { configurable: true, value: [file] });
  fileInput.dispatchEvent(new window.Event("change", { bubbles: true }));
  await settle();
  upload.canvas.flushPendingChanges();

  const uploadRequest = fetches.find(({ options }) => options.method === "POST");
  assert.ok(uploadRequest, "choosing a real file performs the picker upload request");
  assert.equal(
    uploadRequest.url,
    "/w/first/p/project/v1/media/production/upload"
  );
  assert.equal(uploadRequest.options.headers.Authorization, "Bearer upload-token");
  assert.equal(uploadRequest.options.credentials, "same-origin");
  assert.equal(uploadRequest.options.body.get("file").name, "cover.png");
  assert.equal(uploadRequest.options.body.get("dataset"), "production");
  assert.deepEqual(upload.batches, [
    [
      {
        op: "patch-block",
        id: "upload-image",
        patch: {
          value: JSON.stringify({
            url: "/media/uploaded.png",
            assetId: "asset-uploaded",
          }),
        },
      },
    ],
  ]);

  console.log("mounted public field-image browse/select/upload regression passed");
} finally {
  for (const node of mounted) node.remove();
  window.close();
}
