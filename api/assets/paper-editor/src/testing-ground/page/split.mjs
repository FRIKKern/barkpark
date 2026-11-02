import { mirror } from "./mirror.mjs";

const frames = [...document.querySelectorAll(".tg-frame")];
const labels = [...document.querySelectorAll(".tg-split-label")];
const builds = await Promise.all(frames.map((_, i) => fetch(`/b/${i}/build.json`).then((r) => r.json())));
const seen = new Set();
let mirrored = false;

window.addEventListener("message", ({ source, data }) => {
  const side = frames.findIndex((frame) => frame.contentWindow === source);
  if (side === -1 || data?.tg !== "mounted") return;
  seen.add(side);
  const [left, right] = frames.map((frame) => frame.contentWindow);
  if (side === 0 && seen.has(1)) {
    if (data.reload) right.testingGround.reload();
    else if (right.testingGround.state.key !== data.key) right.testingGround.openDoc(data.key);
  }
  if (mirrored || seen.size < 2) return;
  mirrored = true;
  mirror(left.document.querySelector(".tg-edit"), () => left.testingGround.state.canvases[0], () => right.testingGround.state.canvases[0]);
});

builds.forEach((build, i) => {
  labels[i].textContent = `${i ? "Right" : "Left"}: ${build.label} at ${build.sha}`;
  frames[i].title = `${build.label} at ${build.sha}`;
  frames[i].src = `/b/${i}/${location.search}`;
});
