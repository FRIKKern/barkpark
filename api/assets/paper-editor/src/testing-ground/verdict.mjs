import { tallyWords } from "./page/tally.mjs";

export const needsHands = (drill) => drill.steps.find((step) => step.hands);

export function verdict(drill, lights, tally, errors) {
  const red = drill.green.filter((key) => lights[key].ok !== "true").map((key) => lights[key].words);
  if (drill.tally && tally.hits !== drill.repeat) red.push(tallyWords(tally));
  red.push(...errors.map((error) => `page error: ${error}`));
  const checked = [...drill.green, ...(drill.tally ? ["the tally"] : [])];
  if (red.length) return { ok: false, words: red.join(" · ") };
  if (!checked.length) return { ok: false, words: "nothing to check: no light was red when this was recorded, so add a check to the drill" };
  return { ok: true, words: `${checked.join(", ")} green` };
}
