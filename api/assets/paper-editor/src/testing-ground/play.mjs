async function boxOf(page, text, at) {
  const box = await page.evaluate(([text, at]) => {
    const walker = document.createTreeWalker(document.querySelector(".tg-edit"), NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const start = node.data.indexOf(text);
      if (start === -1) continue;
      const range = document.createRange();
      if (at === "end") range.setStart(node, start + text.length - 1), range.setEnd(node, start + text.length);
      else if (at === "start") range.setStart(node, start), range.setEnd(node, start + 1);
      else range.setStart(node, start), range.setEnd(node, start + text.length);
      const r = range.getBoundingClientRect();
      const x = at === "end" ? r.right - 1 : at === "start" ? r.left + 1 : r.left + r.width / 2;
      return { x, y: r.top + r.height / 2 };
    }
    return null;
  }, [text, at]);
  if (!box) throw new Error(`"${text}" is not on screen`);
  return box;
}

async function caretRead(page) {
  await page.waitForFunction(() => {
    const view = window.testingGround.state.canvases[0]._editor.view;
    const dom = getSelection();
    return dom.anchorNode && view.state.selection.from === view.posAtDOM(dom.anchorNode, dom.anchorOffset);
  });
}

const doors = {
  async click(page, { text, at }) {
    const { x, y } = await boxOf(page, text, at);
    await page.mouse.click(x, y);
    await caretRead(page);
  },
  async button(page, name) {
    await page.locator(".tg-edit").getByRole("button", { name, exact: true }).first().click();
    await caretRead(page);
  },
  async dblclick(page, { word }) {
    const { x, y } = await boxOf(page, word, "middle");
    await page.mouse.dblclick(x, y);
    await page.waitForFunction(() => !window.testingGround.state.canvases[0]._editor.view.state.selection.empty);
  },
  async key(page, key, { times = 1 }) {
    for (let i = 0; i < times; i++) await page.keyboard.press(key);
  },
  async type(page, text) {
    await page.keyboard.type(text);
  },
  async paste(page, { html }) {
    await page.evaluate((html) => {
      const data = new DataTransfer();
      data.setData("text/html", html);
      data.setData("text/plain", new DOMParser().parseFromString(html, "text/html").body.innerText);
      document.activeElement.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
    }, html);
  },
  async reload(page) {
    await page.evaluate(() => window.testingGround.reload());
  },
};

async function once(page, steps) {
  for (const step of steps) {
    const door = Object.keys(doors).find((name) => name in step);
    await doors[door](page, step[door], step);
  }
  await page.evaluate(() => window.testingGround.settle());
}

export async function play(page, drill) {
  if (!drill.repeat) return once(page, drill.steps);
  for (let run = 0; run < drill.repeat; run++) {
    await page.evaluate((key) => window.testingGround.openDoc(key), `drill:${drill.id}`);
    await page.waitForFunction(() => window.testingGround.state.canvases[0]._editor);
    await once(page, drill.steps);
    await page.waitForFunction((run) => window.testingGround.state.tally.tries > run, run);
  }
}

export async function lightsOf(page) {
  return page.evaluate(() => {
    window.testingGround.paintLights();
    return Object.fromEntries([...document.querySelectorAll(".tg-light")].map((li) => [li.dataset.trap, { ok: li.dataset.ok, words: li.textContent }]));
  });
}
