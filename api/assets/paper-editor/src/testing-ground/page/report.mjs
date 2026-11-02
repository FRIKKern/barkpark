const post = (path, payload) =>
  fetch(path, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(payload) }).then(async (res) => ({ ok: res.ok, ...(await res.json()) }));

export function wireReport({ what, show, preview, file, result }, snapshot) {
  let shown = null;
  what.addEventListener("input", () => {
    shown = null;
    file.disabled = true;
  });
  show.addEventListener("click", async () => {
    show.disabled = true;
    const body = { what: what.value, repro: snapshot() };
    const answer = await post("report/preview", body);
    show.disabled = false;
    preview.hidden = false;
    preview.textContent = answer.ok ? ["bp", ...answer.args].join("\n") : answer.error;
    shown = answer.ok ? body : null;
    file.disabled = !answer.ok;
    result.textContent = "";
  });
  file.addEventListener("click", async () => {
    file.disabled = true;
    const answer = await post("report", shown);
    result.textContent = answer.ok ? `Filed ${answer.id}. An agent replays it with npm run drill -- --repro.` : `Not filed: ${answer.error}`;
  });
}
