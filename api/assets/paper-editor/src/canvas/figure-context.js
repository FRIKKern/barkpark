export function isFigureSingletonCanvas(host) {
  const context = host.closest("[data-paper-container-kind]");
  return context?.getAttribute("data-paper-container-kind") === "figure" &&
    host._blocks.length === 1;
}
