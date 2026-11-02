import { canonical } from "../traps.mjs";

let standIn;
let latest = 0;

async function renderStandIn(blocks) {
  standIn ||= import("/reader-standin.js");
  return (await standIn).render(blocks);
}

export async function paintReader({ label, body }, { golden, start, saved }, render = renderStandIn) {
  const turn = ++latest;
  if (golden && canonical(saved) === canonical(start)) {
    label.textContent = "Golden reader HTML for this sample.";
    body.innerHTML = golden;
    return;
  }
  const paint = await Promise.resolve(saved).then(render).then(
    (html) => () => { body.innerHTML = html; },
    (error) => () => { body.textContent = error.message; },
  );
  if (turn !== latest) return;
  label.textContent = "Stand-in: the @barkpark/react render of this doc, not the golden reader.";
  paint();
}
