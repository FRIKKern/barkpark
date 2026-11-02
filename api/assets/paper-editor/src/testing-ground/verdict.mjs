import { tallyWords } from "./page/tally.mjs";

export const needsHands = (drill) => drill.steps.find((step) => step.hands);

export function verdict(drill, lights, tally, errors) {
  const red = drill.green.filter((key) => lights[key].ok !== "true").map((key) => lights[key].words);
  if (drill.tally && tally.hits !== drill.repeat) red.push(tallyWords(tally));
  red.push(...errors.map((error) => `page error: ${error}`));
  return { ok: red.length === 0, words: red.length ? red.join(" · ") : `${[...drill.green, ...(drill.tally ? ["the tally"] : [])].join(", ")} green` };
}
