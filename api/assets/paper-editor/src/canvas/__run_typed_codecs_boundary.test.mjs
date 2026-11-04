import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import * as root from "./run-convert.js";

const ROOT_EXPORTS = [
  "blockParents", "docToBlocks", "hasOverlappingOps", "holdsNodeIds",
  "idCarriesKind", "nodeContentEqual", "opsRebaseSafe", "pendingUploadIndexes",
  "reconcileServerEcho", "runToOps", "runToTiptap", "withObjectOverrides",
];
const ROOT_ARITIES = {
  blockParents: 1, docToBlocks: 1, hasOverlappingOps: 3, holdsNodeIds: 1,
  idCarriesKind: 2, nodeContentEqual: 2, opsRebaseSafe: 3, pendingUploadIndexes: 2,
  reconcileServerEcho: 2, runToOps: 2, runToTiptap: 1, withObjectOverrides: 2,
};
assert.deepEqual(Object.keys(root), ROOT_EXPORTS, "run-convert public namespace stays exact");
for (const name of ROOT_EXPORTS) {
  assert.equal(typeof root[name], "function", `${name} stays a function`);
  assert.equal(root[name].name, name, `${name} keeps its function name`);
  assert.equal(root[name].length, ROOT_ARITIES[name], `${name} keeps its arity`);
}

const blocks = [
  { id: "stage", type: "stage", kind: "release", title: "Ship", detail: "Ready", files: "a", source: 1 },
  { id: "role", type: "byline", items: ["Ada", "Lin"] },
  { id: "code", type: "code", value: "x = 1", lang: "js" },
  { id: "diagram", type: "diagram", source: "A-->B", caption: "Flow" },
  { id: "technical", type: "diff", diff: "+one", file: "a.txt", lang: "diff" },
  { id: "field", type: "field-number", label: "Count", value: 12, unit: "items" },
  { id: "action", type: "action", label: "Go", href: "/go", priority: "primary" },
  { id: "sheet", type: "sheet", ref: "budget", snapshot: { rows: [[42]] } },
  { id: "fleet", type: "tasks", snapshot: [{ title: "One" }] },
  { id: "figure", type: "figure", caption: "Cap", child: { id: "child", type: "image", src: "/child.png" } },
  { id: "island", type: "equation", tex: "x^2", display: true },
  { id: "image", type: "image", src: "/hero.png", alt: "Hero", width: 640, locked: true, role: "featured" },
  { id: "task", type: "task-list", query: { label: "proj:x" }, title: "Plan", config: { limit: 5 } },
];
const doc = root.runToTiptap(blocks);
assert.deepEqual(root.docToBlocks(doc), blocks, "all extracted families round-trip through public projection");
assert.deepEqual(root.runToOps(blocks, doc), [], "all extracted families remain no-op stable");
assert.deepEqual(root.reconcileServerEcho(blocks, doc.content), { ownEcho: true, idWrites: [] },
  "all extracted families recognize their own server echo");
for (const [index, node] of doc.content.entries()) {
  assert.equal(root.nodeContentEqual(node, structuredClone(node)), true,
    `family ${blocks[index].type} keeps public node equality`);
}

const editedStage = root.runToTiptap([blocks[0]]);
editedStage.content[0].attrs.title = "Shipped";
assert.deepEqual(root.runToOps([blocks[0]], editedStage), [{
  op: "patch-block",
  id: "stage",
  patch: { kind: "release", title: "Shipped", detail: "Ready", files: "a", source: 1 },
}], "stage edits preserve numeric truthy source through the public patch API");

const legacyNumberField = { id: "legacy-number", type: "field-number", value: "12" };
const normalizedFieldDoc = root.runToTiptap([legacyNumberField]);
assert.equal(normalizedFieldDoc.content[0].attrs.value, 12, "field-number normalizes legacy numeric text");
assert.equal(root.docToBlocks(normalizedFieldDoc)[0].value, 12,
  "field-number reconstruction retains the normalized number");

const editedDiagram = root.runToTiptap([blocks[3]]);
editedDiagram.content[0].attrs.source = "B-->C";
assert.deepEqual(root.runToOps([blocks[3]], editedDiagram), [{
  op: "patch-block", id: "diagram", patch: { source: "B-->C", caption: "Flow" },
}], "diagram edits keep their public dispatch patch");
console.log("typed codec root public boundary passed");

let leaves;
try {
  leaves = await Promise.all([
    import("./run-template-attrs.js"),
    import("./run-scalar-codecs.js"),
    import("./run-structured-codecs.js"),
  ]);
} catch (error) {
  if (error && error.code === "ERR_MODULE_NOT_FOUND") {
    console.log("typed codec leaves missing");
    process.exit(1);
  }
  throw error;
}
const [template, scalar, structured] = leaves;

const TEMPLATE_EXPORTS = ["carryTemplateAttrs", "stampTemplateAttrs"];
const SCALAR_EXPORTS = [
  "codeBlockToNode", "codeNodeChanged", "codeNodeToBlock", "codeNodeToPatch",
  "diagramBlockToNode", "diagramNodeChanged", "diagramNodeToBlock", "diagramNodeToPatch",
  "isTechnicalAtomNode", "roleBlockToNode", "roleNodeChanged", "roleNodeToBlock",
  "roleNodeToPatch", "stageBlockToNode", "stageNodeChanged", "stageNodeToBlock",
  "stageNodeToPatch", "technicalBlockToNode", "technicalNodeChanged",
  "technicalNodeToBlock", "technicalNodeToPatch",
];
const STRUCTURED_EXPORTS = [
  "READ_ONLY_ATOM_RETARGET_KEY", "actionBlockToNode", "actionNodeChanged",
  "actionNodeToBlock", "actionNodeToPatch", "fieldBlockToNode", "fieldNodeChanged",
  "fieldNodeToBlock", "fieldNodeToPatch", "figureBlockToNode", "figureNodeChanged",
  "figureNodeToBlock", "figureNodeToPatch", "fleetBlockToNode", "fleetNodeChanged",
  "fleetNodeToBlock", "fleetNodeToPatch", "imageBlockToNode", "imageNodeChanged",
  "imageNodeToBlock", "imageNodeToPatch", "islandBlockToNode", "islandNodeChanged",
  "islandNodeToBlock", "islandNodeToPatch", "readOnlyAtomBlockToNode",
  "readOnlyAtomNodeToBlock", "readOnlyAtomRetargetPatch", "taskListBlockToNode",
  "taskListNodeChanged", "taskListNodeToBlock", "taskListNodeToPatch",
];
assert.deepEqual(Object.keys(template), TEMPLATE_EXPORTS, "template leaf namespace stays exact");
assert.deepEqual(Object.keys(scalar), SCALAR_EXPORTS, "scalar leaf namespace stays exact");
assert.deepEqual(Object.keys(structured), STRUCTURED_EXPORTS, "structured leaf namespace stays exact");

const MANIFEST = `
template	stampTemplateAttrs	146-150	ccee950f514cacbb1523e39566e0b5107a2f6215a1209aaa6f8c5a11310a4724
template	carryTemplateAttrs	155-159	d9ac29e698ec7dfe1420ab4127dcfff529c01a9da6c2cc85477dd0b00ed83709
scalar	stageTruthy	982-984	cf11c1d29c0adf13a441e613767ec4445ae6351621e4e73413498ba48cfb645f
scalar	stageFieldText	991-998	3ef8274cc0ffa2d1aaa98dccbbdbd137abeaa94153e1c3bbdda26fa89a1ee075
scalar	flattenInlineTextPlain	1003-1013	7fec57c19d8eb945f54c57c8bb59784cd7e8b703f88d9e5d6a66e99d95cf4032
scalar	stageBlockToNode	1018-1030	ed975a200ae1a87c747f15dce5ffcc620d0ae9eaf68f5ae54ef653a4f00eaf43
scalar	stageNodeToBlock	1036-1045	dbb7f252e04e3ac06092ccc5f804e00e081e52933d1747d260e26fc4e5ef7d9b
scalar	stageNodeToPatch	1053-1063	259faeb1afa78c2ad5cf4fef4fd458c37b4426818feecc4d52d76c6afb73a38e
scalar	stageNodeChanged	1068-1070	f3e43f6db3192aa4390b5d5755e9a6875015eabe01500d3a090f89c588fc7cbe
scalar	stableStageKey	1072-1082	a8dc07a89908aeeb574883a53f60c2344778e82aedba04f3979fcf6b4a3ddbd1
scalar	roleNodeText	1105-1107	1c3639b888e6e6159a37a40118b7c9877bfd813e538d6327de502aed2d9cf2ba
scalar	splitBylineItems	1111-1116	3201ec482ea49d1de57d43582b62518e14ad3f60787555c67bb155224dbcd08d
scalar	bylineDisplay	1120-1124	6be984f4753a4dba1a5dc304e6ff3e16bdd954b28598da4e7c874f2fda504cee
scalar	roleBlockToNode	1132-1153	13b2054d2a48fcad95fe74e35e3de1d8f4d24bd07b33ec0c6cde4c278f3cd87e
scalar	roleNodeToBlock	1160-1177	c618a67337640969f37ffdbe0f71cd36f8ca8ab55768486faed38cef29b0e24b
scalar	roleNodeToPatch	1184-1194	1f378c9541b35eb0c5b2d99f5320b8e43f0a48a9c1dea35232eb55bf40fe9f86
scalar	roleNodeChanged	1201-1203	aabc47bf24e2ccd35b2dd19dd73aee042475e2bd3a039e74df33faa88a3062c2
scalar	stableRoleKey	1205-1215	b0d7199c8ad8babcc4be775c46fdc3df60e9f988231c9315a72e4d9495b93f64
scalar	codeBlockToNode	1235-1246	dbf2b3b7116afd63f3d1683c8eb56cdab22a2e5903611936d5098f4ae613d6ff
scalar	codeNodeToBlock	1254-1263	cd9c0df3d16134addbd5e428638de15b1af3614e6950ca10733a96c75d1f16ec
scalar	codeNodeToPatch	1277-1285	bf23b95b009dbf6f1fdf45ebb0b42fe71a22c3462fb696bd2130970fc480e212
scalar	codeNodeChanged	1292-1294	3a8fe0a25a5a7e2e84179990ee5ab1907af88910fc9900ce63ee67fbaedf3622
scalar	stableCodeKey	1296-1302	f3ca1ebb12901aaf6505b10086e1219f1e818a392bc08f79937dc4c95944875d
scalar	diagramBlockToNode	1330-1342	27d8a00b77c4fe1fe6e2fe5f407fca8d76f00293a5ec48c595e62bb158075285
scalar	diagramNodeToBlock	1350-1360	490fe1fd83a22bdb4e5ae7778b4e8a29754c278854655247e15feb3f875c7ea9
scalar	diagramNodeToPatch	1372-1378	e40bdb0e325ddcfef7a42d786a488eea6d6e3e3a61808ba67b5ec2583f977831
scalar	diagramNodeChanged	1386-1388	8709461a34fd1544470ac31fed960aa0a0bf64ef3a7c574bc48270f927402971
scalar	stableDiagramKey	1390-1396	599a5b9e0a0a155de5b7f66429ccfc0bc64237e6e106cc01302e5ca7dfdfd283
scalar	isTechnicalAtomNode	1413-1415	fdb1852364c159daba12ae0ee85c9a09fbd21d6f7e4e2e6c24d0578c055b36bc
scalar	technicalShapeForNode	1418-1421	4d75ab5c244fb76bcd5071a024f111171b8e903ed73c22e152dbfee6218d2b44
scalar	technicalBlockToNode	1429-1439	ca1ef33f0ee5a88685db6bd8f504b401b18c53de6ff57b97561a864bfbdc32b6
scalar	technicalNodeToBlock	1447-1457	c077e56fcdfb97a4c46be81bdef08be4481d6d2cc4fe5bded2cb99045cca5ee7
scalar	technicalNodeToPatch	1473-1485	3f5a25679ab1b4c3bfd1b86ebff6337f08f18179f0f667357c66b617163dfb8e
scalar	technicalNodeChanged	1492-1494	02e88cdf994f9cb454435265d046e9f400012e0229237bec38b976c1c7e19d03
scalar	stableTechnicalKey	1496-1505	f0d30390a0c1ccc59c0855e9c4c7a678fc4a031cd938cf7b436f6f613b882656
structured	normalizeFieldValue	1527-1535	135bba36e34c061766cf040d51fc6fc813fccb01647433a2977c45861d93c501
structured	FIELD_NUMBER_CONFIG	1547-1547	86225970bf385c332e48f6648178a9cdbc5d30637c00474edf497da7cddf61dd
structured	fieldBlockToNode	1549-1575	a8b71ddd4f539b7f7c1ebd2ef0c997df863867e1290902b15c7d2ccddabd523b
structured	fieldNodeToBlock	1585-1609	86a90cde2664cb68b7c08c5d8680d5c5d2ec4836b1414bb0f26a7b6bc7f8b45b
structured	fieldNodeToPatch	1620-1638	112e43e84f7168dabff491881b1c577b1cd57fff84ac61ee985575bdab3c2ff3
structured	FIELD_SETTINGS_CONFIG	1640-1640	e4b56620e51526c283ce969f549fa7ea8a234741e3c6080ca2ac50305ca23182
structured	fieldNodeChanged	1647-1649	a895c87f8d0eaf346af710642965bd8a70420606545d6f136b71ef94575aa02b
structured	stableFieldKey	1651-1657	8694f16b484689cff9d81670176ec84f85549855fc35d84fb424e807a54b6357
structured	normalizeActionPriority	1676-1678	268fffd24e53a38e2f7a3a6c30e68c4f60a3232bce7f7e7654bd595747e9d75a
structured	actionBlockToNode	1686-1693	35cb5e1ab6de21b3d7663b5a54789acaf112cdda54513102ed8c2d01935f8461
structured	actionNodeToBlock	1701-1709	93a4d18a0df38710fb9683157874d38b7bb9e302883a25732d69ef0714d4b81f
structured	actionNodeToPatch	1715-1722	418b9e240b794d75e2f56180d307b530850ca659e1ba9abe7c7371bbcddf597a
structured	stableActionKey	1728-1735	5969c51ee7e6f34cb19ce027c440b93a26e5f8060ba88a68d9f266012c34a908
structured	actionNodeChanged	1740-1742	ff1151020b40a241c44777f0753e9ecb4a0fa45e3fbe36e14251bc0b43d7df22
structured	readOnlyAtomBlockToNode	1764-1770	4ad93944d5442ec597a676f199c58a48143b11d8afcc5e5359e985804921dcd9
structured	readOnlyAtomNodeToBlock	1777-1787	7ff108bee88d20f91726d4ad6e040a769291197246a4145660f03c4df91b29c5
structured	READ_ONLY_ATOM_RETARGET_KEY	1819-1819	a84186d3ae81b075c4d8c33d3d9ee64394b15ca29ad18cb5088d6a6a924944e9
structured	readOnlyAtomRef	1823-1827	b599c5a35c848228a4e56a66563ca6250cf21d9a54ae076595a6a1c3ca9f2bde
structured	readOnlyAtomRetargetPatch	1832-1839	cacb0b8e59a02109bbf691d3e95929d7324ced2ee9cc74c1b6855e007d9b30eb
structured	fleetBlockToNode	1860-1865	67ff07931eaa41847464df0bbe6424cd1a13cf7f71c5e3912b8383ce9a1625f3
structured	fleetNodeToBlock	1872-1880	3a7a408e24d2775a320a3086e40eae5df9303e43ba9a7b8318f249b487d2239f
structured	fleetNodeToPatch	1891-1899	36d4ce4a408dc17bf357bdf32d157cdfb50106a3b8efc6b0d88c8174ebbecd2e
structured	fleetNodeChanged	1907-1909	6b3095e95430e7be57ffe36e73894ad5a5c7ae8c53dba77f0f606dba67a90975
structured	stableFleetKey	1911-1915	dd936d0dceb57196785343725137a281aaac55b67f29aeea93efee9f2961333d
structured	figureBlockToNode	1935-1947	18b70b5d6d07a18f0ca2c34b002606b0498f13b829f5f75a34cbc7424764aa60
structured	figureNodeToBlock	1955-1964	6653b502e70ac71c5a59bc9d2c61d485c47f8234b84af33e0d9a445f90a136d7
structured	figureNodeToPatch	1972-1975	1dce8182d6a9a73d3176ccb4e63dd949fa59b411743ed3daa096f3bfa6de5613
structured	figureNodeChanged	1983-1985	6df5c13b6ef2ee2c5b87195d31563968e6303fbf0fc2285af8005b07579b9d33
structured	stableFigureKey	1987-1993	69ef7f64eedfbbd108d49f21a2cf5114f34440ad8ed56ff5b7bb2db965030af9
structured	islandEmpty	1996-1996	207052bf5671ae77581e5e8643a0fc83af45c2f638cb23bc938f9e1055870c49
structured	islandBlockToNode	1998-2015	a5120d29d3e697e3986c54929cb5fee6ce55705c97fc9e9acfe25b5c80cafc66
structured	islandNodeToBlock	2017-2031	e28999db59e4a42c4f6454956957cfcfa1770969a7067f31eafe24eae41d2496
structured	islandNodeToPatch	2035-2045	775c4e182e2ba2a4205a2cf6b18f408f1af586321ee32589c1f36e72b5915627
structured	stableIslandKey	2047-2054	4ae793fa61cd8601464583a77b5faeed92268d5fa595ae1e08cd08d0fda33275
structured	islandNodeChanged	2056-2058	d5dbd6947cfcfb8fce604d825b171113342ff3f25fcbec0a158ede89adc66590
structured	IMAGE_OWN_KEYS	2066-2066	488e4d08d5d99e79697e677343af3f9a9e6f9b506deba675fc775f9f402f9c92
structured	imageBlockToNode	2068-2088	a70b0048a2a865eafcb9640ed352d9d48292f90640150a0b23296d702c3ae10e
structured	imageNodeToBlock	2091-2103	d2de61d3f1168b4f4981dbc654e09c9895d128c71e6e8a004ebc5ebd0ebf093a
structured	imageNodeToPatch	2108-2111	a2f43a50bf105ba1fc89740ee1aa70ca4652eef4b35a1e5545d40323a48a57eb
structured	stableImageKey	2113-2121	8a0571edd3d2dd710751123109409956b89bac9895b3a0ca233bea82d85e1b6d
structured	imageNodeChanged	2123-2125	217a61e4d75f4b20c4451d430593b02cac3872e345bfc5be8fcfaa8ecf9b3d6a
structured	taskListBlockToNode	2144-2155	7c7d510215ed855dd24750f2243cf43dc0e841182d8a988d554863438f334be4
structured	taskListNodeToBlock	2162-2172	bb5a8f05f51a944444c010be9857967e4c20d76a8b0812f3f88d1794195ce6e3
structured	taskListNodeToPatch	2180-2193	26095a5e1610bff5f3f171161908d6b84032d938716c781243ebc5285e10490a
structured	taskListNodeChanged	2200-2202	cc9b23eb2ee7bc5f54516e61edbe694e05787f0914e10aa232eb7cc2f95b5278
structured	stableTaskListKey	2204-2211	a9be88171aa76f9e5a26ea1967b10cbb62c019fac009b98bffe3b66828f55ef0
`.trim().split("\n").map((line) => {
  const [group, declaration, lines, hash] = line.split("\t");
  const [start, end] = lines.split("-").map(Number);
  return { group, declaration, start, end, hash };
});
assert.equal(MANIFEST.length, 81, "inline declaration manifest stays complete");
assert.equal(MANIFEST.filter(({ group }) => group === "template").length, 2);
assert.equal(MANIFEST.filter(({ group }) => group === "scalar").length, 33);
assert.equal(MANIFEST.filter(({ group }) => group === "structured").length, 46);

const here = dirname(fileURLToPath(import.meta.url));
const paths = {
  root: resolve(here, "run-convert.js"),
  template: resolve(here, "run-template-attrs.js"),
  scalar: resolve(here, "run-scalar-codecs.js"),
  structured: resolve(here, "run-structured-codecs.js"),
};
const sources = Object.fromEntries(Object.entries(paths).map(([key, path]) => [key, readFileSync(path, "utf8")]));
const sha256 = (value) => createHash("sha256").update(value).digest("hex");
const regions = {
  template: {
    start: 132, lines: 28, marker: "// ── doctrine template attrs (pdd-t2): locked / role round-trip ───────────────",
    hash: "760f9bdf19b33038e5ec448eb72a1c38bcbd631f50896697b8a74dda53ea25b5",
  },
  scalar: {
    start: 967, lines: 539, marker: "// ── stage ⇄ canvas control-atom node (the pipeline-node twin) ────────────────",
    hash: "69b6b2db95c0172176c4cdbb119c9f76dc84c3a55aa2996b7e87b1e630744cba",
  },
  structured: {
    start: 1507, lines: 705, marker: "// ── field ⇄ canvas control-atom node (S3.5) ─────────────────────────────────",
    hash: "663161d45f1d9e6d7f0c5a4cd89644604db5546947ba03aa60eeba686dfd7aa2",
  },
};
for (const [group, spec] of Object.entries(regions)) {
  const allLines = sources[group].split("\n");
  const markerIndex = allLines.indexOf(spec.marker);
  assert.ok(markerIndex >= 0, `${group} copied-region marker remains exact`);
  const regionLines = allLines.slice(markerIndex, markerIndex + spec.lines);
  assert.equal(sha256(regionLines.join("\n") + "\n"), spec.hash, `${group} copied region stays byte-exact`);
  for (const entry of MANIFEST.filter((item) => item.group === group)) {
    const from = entry.start - spec.start;
    const declaration = regionLines.slice(from, from + entry.end - entry.start + 1).join("\n");
    assert.equal(sha256(declaration), entry.hash, `${group} declaration ${entry.declaration} stays byte-exact`);
    const declarationPattern = new RegExp(`\\b(?:function|const)\\s+${entry.declaration}\\b`, "g");
    assert.equal([...sources[group].matchAll(declarationPattern)].length, 1,
      `${entry.declaration} is defined exactly once in its leaf`);
    assert.equal([...sources.root.matchAll(declarationPattern)].length, 0,
      `${entry.declaration} is absent from the root`);
  }
}

const importSpecifiers = (source) => [...source.matchAll(
  /(?:^|\n)\s*(?:import|export)\s+(?:[^"'\n]*?\s+from\s+)?["']([^"']+)["']/g,
)].map((match) => match[1]);
for (const key of ["root", "template", "scalar", "structured"]) {
  assert.doesNotMatch(sources[key], /export\s+\*/u, `${key} uses explicit exports`);
}
const visiting = new Set();
const visited = new Set();
const leafPaths = new Set([paths.template, paths.scalar, paths.structured]);
function walk(file) {
  assert.notEqual(file, paths.root, "typed codec dependency closure cannot reach run-convert");
  if (visiting.has(file)) {
    assert.ok(!leafPaths.has(file), `typed codec leaf participates in a relative import cycle at ${file}`);
    return;
  }
  if (visited.has(file)) return;
  visiting.add(file);
  for (const specifier of importSpecifiers(readFileSync(file, "utf8"))) {
    if (specifier.startsWith(".")) walk(resolve(dirname(file), specifier));
  }
  visiting.delete(file);
  visited.add(file);
}
for (const key of ["template", "scalar", "structured"]) walk(paths[key]);

assert.ok(sources.root.split("\n").length - 1 > 800, "residual run-convert remains an explicit size gap");
for (const key of ["template", "scalar", "structured"]) {
  assert.ok(sources[key].split("\n").length - 1 < 800, `${key} leaf stays below 800 physical lines`);
}
assert.ok(readFileSync(fileURLToPath(import.meta.url), "utf8").split("\n").length - 1 < 800,
  "typed codec boundary test stays below 800 physical lines");

console.log("run typed codec extraction boundary passed");
