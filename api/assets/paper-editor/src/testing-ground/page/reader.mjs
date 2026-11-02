import { canonical } from "../traps.mjs";

let standIn;

async function renderStandIn(blocks) {
  standIn ||= import("/reader-standin.js");
  return (await standIn).render(blocks);
}

export async function paintReader({ label, body }, { golden, start, saved }) {
  if (golden && canonical(saved) === canonical(start)) {
    label.textContent = "Golden reader HTML for this sample.";
    body.innerHTML = golden;
    return;
  }
  label.textContent = "Stand-in: the @barkpark/react render of this doc, not the golden reader.";
  try {
    body.innerHTML = await renderStandIn(saved);
  } catch (error) {
    body.textContent = error.message;
  }
}
