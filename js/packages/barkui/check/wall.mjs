// The wall round the browser library: the one closed list of what the check's code may reach on the library's
// objects. check/acts.mjs holds the library's own objects and hands every other file a wall object in each one's
// place (`launch`, and everything an allowed call hands back). On a wall object a name on this list goes through;
// every other name, the library's own, inherited, underscored or a symbol, is refused by name. The list holds what
// is allowed; nothing lists what is refused. Keys, the pointer and touch are on no list: check/acts.mjs makes them,
// each followed by its rest step.

/** What every wall object answers, of any kind: `then`, which await and Promise read (a wall object is no promise). */
export const EVERY = ['then']
const EVENTS = ['on', 'once', 'off', 'addListener', 'removeListener', 'waitForEvent']
/** The check's own fields on a page (proofs.mjs, open), the only names a wall object takes a value for. */
export const PAGE_FIELDS = ['barkCdp', 'barkCensus', 'barkCheck', 'barkCover', 'barkPlacement', 'barkPress', 'barkRef', 'barkScale', 'barkStyles']

/** The allowed names, by the library's name for each kind of object. */
export const ALLOWED = {
  Browser: [...EVERY, 'close', 'newContext', 'newPage', 'version'],
  BrowserContext: [...EVERY, ...EVENTS, 'close', 'newCDPSession', 'newPage', 'pages'],
  Page: [...EVERY, ...EVENTS, ...PAGE_FIELDS, 'clock', 'close', 'context', 'evaluate', 'goto', 'isClosed', 'locator', 'screenshot', 'setContent', 'waitForSelector', 'waitForTimeout'],
  Locator: [...EVERY, 'screenshot'],
  Clock: [...EVERY, 'install', 'pauseAt', 'runFor'],
  CDPSession: [...EVERY, ...EVENTS, 'detach', 'send'],
  ConsoleMessage: [...EVERY, 'text', 'type'],
  Request: [...EVERY, 'url'],
}
/** The protocol commands a CDP session may send: reads, isolated worlds and scripts. No command of the Input domain. */
export const CDP_ALLOWED = ['Accessibility.getPartialAXTree', 'DOM.describeNode', 'DOM.getDocument', 'DOM.querySelector', 'Page.addScriptToEvaluateOnNewDocument', 'Page.createIsolatedWorld', 'Page.enable', 'Page.getFrameTree', 'Runtime.enable', 'Runtime.evaluate', 'Runtime.getProperties', 'Runtime.releaseObjectGroup']
/** Kinds of the library's objects that do not descend from its ChannelOwner, known by their class's name. */
export const PLAIN_KINDS = ['Accessibility', 'Clock', 'ConsoleMessage', 'Coverage', 'FileChooser', 'FrameLocator', 'Keyboard', 'Locator', 'Mouse', 'Selectors', 'Touchscreen', 'Tracing', 'Video', 'WebError']

/** What the wall has read of the library's own objects: each kind's methods, by the library's name for it. */
export const WALL = { read: {} }

/** One line for a run's end: the library's methods read from its own objects, and the closed list, each counted
    from itself. */
export const wallLine = () => {
  const kinds = Object.keys(WALL.read)
  const read = kinds.reduce((n, k) => n + WALL.read[k], 0)
  const allowed = Object.values(ALLOWED).reduce((n, l) => n + new Set(l).size, 0)
  return `the wall: ${read} methods read from the browser library's own objects (${kinds.map((k) => `${k} ${WALL.read[k]}`).join(', ')}); the closed list allows ${allowed} names and ${CDP_ALLOWED.length} protocol commands; every other name refused by name`
}
