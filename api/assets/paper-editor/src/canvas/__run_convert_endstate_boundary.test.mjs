import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import * as root from "./run-convert.js";
import * as kinds from "./run-kinds.js";
import * as project from "./run-project.js";
import * as nodeCore from "./run-node-core.js";
import * as containers from "./run-container-codecs.js";
import * as diffUtils from "./run-diff-utils.js";
import * as reverseEcho from "./run-reverse-echo.js";
import * as ops from "./run-ops.js";

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

const text = (value) => [{ type: "text", value }];
const paragraph = (id, value) => ({ id, type: "paragraph", content: text(value) });
const baseline = [paragraph("p1", "one"), paragraph("p2", "two")];
const projected = root.runToTiptap(baseline);
assert.deepEqual(root.docToBlocks(projected), baseline, "projection reconstructs the original blocks");
assert.deepEqual(root.runToOps(baseline, projected), [], "an unchanged projection emits no ops");

const edited = structuredClone(projected);
edited.content[1].content[0].text = "TWO";
assert.deepEqual(root.runToOps(baseline, edited), [{
  op: "patch-block", id: "p2", patch: { content: text("TWO") },
}], "an edited projection emits the expected patch");

const tree = [{
  id: "section", type: "section", blocks: [
    { id: "child", type: "paragraph", content: text("child") },
    { id: "steps", type: "steps", steps: [{ id: "step", type: "step", blocks: [] }] },
    { id: "tabs", type: "tabs", tabs: [{ id: "tab", type: "tab", children: [] }] },
  ],
}];
assert.deepEqual([...root.blockParents(tree)].map(([id, parents]) => [id, [...parents]]), [
  ["section", [null]], ["child", ["section"]], ["steps", ["section"]],
  ["step", ["steps"]], ["tabs", ["section"]], ["tab", ["tabs"]],
], "all nested block collections preserve parent identity");
assert.equal(root.holdsNodeIds({ type: "bpSection", content: [] }), true);
assert.equal(root.holdsNodeIds({ type: "bpStep", content: [] }), true);
assert.equal(root.holdsNodeIds({ type: "paragraph", content: [] }), false);

assert.equal(root.idCarriesKind(paragraph("same", "a"), paragraph("same", "b")), true);
assert.equal(root.idCarriesKind(paragraph("same", "a"), { id: "same", type: "heading", text: "b" }), true);
assert.equal(root.idCarriesKind(paragraph("same", "a"), { id: "same", type: "image", src: "/x" }), false);

const mine = [{ op: "patch-block", id: "p2", patch: { content: text("TWO") } }];
const peerOther = [paragraph("p1", "ONE"), paragraph("p2", "two")];
const peerSame = [paragraph("p1", "one"), paragraph("p2", "peer")];
assert.equal(root.hasOverlappingOps(mine, baseline, peerOther), false);
assert.equal(root.hasOverlappingOps(mine, baseline, peerSame), true);
assert.equal(root.opsRebaseSafe(mine, baseline, peerOther), true);
assert.equal(root.opsRebaseSafe(mine, baseline, peerSame), false);
assert.equal(root.opsRebaseSafe(mine, baseline, [baseline[1], baseline[0]]), false);

const uploadDoc = { type: "doc", content: [
  { type: "bpImage", attrs: { bpId: null, src: null, uploading: true } },
  { type: "bpImage", attrs: { bpId: "known", src: null, uploadError: "failed" } },
  { type: "bpImage", attrs: { bpId: null, src: "/ready.png", uploading: true } },
] };
assert.deepEqual([...root.pendingUploadIndexes(uploadDoc, [{ id: "known", type: "image" }])], [0]);

const echo = root.reconcileServerEcho(baseline, projected.content);
assert.deepEqual(echo, { ownEcho: true, idWrites: [] });
const mintedEcho = structuredClone(projected.content);
mintedEcho[0].attrs.bpId = null;
assert.deepEqual(root.reconcileServerEcho(baseline, mintedEcho), {
  ownEcho: true, idWrites: [{ index: 0, id: "p1", bpType: undefined }],
});
assert.equal(root.nodeContentEqual(projected.content[0], structuredClone(projected.content[0])), true);
assert.equal(root.nodeContentEqual(projected.content[0], edited.content[1]), false);

const overridden = root.withObjectOverrides(new Set(["paragraph"]), () => {
  const outer = root.runToTiptap([paragraph("outer", "opaque")]).content[0];
  const inner = root.withObjectOverrides(new Set(["heading"]), () =>
    root.runToTiptap([paragraph("inner", "editable")]).content[0]);
  const restored = root.runToTiptap([paragraph("restored", "opaque")]).content[0];
  return { outer, inner, restored };
});
assert.equal(overridden.outer.type, "bpOpaque");
assert.equal(overridden.inner.type, "paragraph");
assert.equal(overridden.restored.type, "bpOpaque");
assert.throws(() => root.withObjectOverrides(new Set(["paragraph"]), () => {
  throw new Error("boundary throw");
}), /boundary throw/);
assert.equal(root.runToTiptap([paragraph("after", "editable")]).content[0].type, "paragraph",
  "throw restores the prior override scope");

console.log("run-convert endstate public lock passed");

const PUBLIC_OWNERS = {
  idCarriesKind: kinds, runToTiptap: project, withObjectOverrides: project,
  blockParents: nodeCore, holdsNodeIds: nodeCore, pendingUploadIndexes: nodeCore,
  hasOverlappingOps: diffUtils, opsRebaseSafe: diffUtils,
  docToBlocks: reverseEcho, reconcileServerEcho: reverseEcho, nodeContentEqual: reverseEcho,
  runToOps: ops,
};
for (const [name, owner] of Object.entries(PUBLIC_OWNERS)) {
  assert.equal(root[name], owner[name], `${name} is the direct leaf binding`);
}

const here = dirname(fileURLToPath(import.meta.url));
const sha256 = (value) => createHash("sha256").update(value).digest("hex");
const GROUPS = `
P	run-project.js	de56f2ae22fc19227e921c2661e9487400b38bcae38cded5509e6abeb2834498	5221844d09bbe5b77f8a7c591f5a8b6d32feaeda5ee9c4549875ff2af37c5350	660
N	run-node-core.js	85bac095f762d0fb3ab77c81e01105991cb589d46139dec1241454807d019d64	69b4e687f4be029a7495adc5e688a90b9b3f7040e190df9731e372cdde22e462	430
C	run-container-codecs.js	18d587e1c72ca8a501582364d0db65c0711c43b15ca3be831174b21043620471	4bfb6dbf73a700bef03a5e6474d1eebc6e4b214737d41b1793274fd356dbca36	660
D	run-diff-utils.js	385738457a3b0bdf3df82465e48edb578b6991171cf2b0d214c4537fc449bd1f	e085b1c9c51753b47e1d9cbed8cc228aa9a874646165505acbb40c1ac9143ab1	200
R	run-reverse-echo.js	529fd96e3d8a6ad4ea82e05fb0af5fa0de4b2dfccbfa332dc2f885218bd3bc01	f77dc0d2a15d9f9fc023210f4779154dc6e3668f5380368d929474a99705d7f0	560
O	run-ops.js	599454a09c19841ada5909d12bc074822a1c9367c772bb2509e1aca655c67841	16731eeb1c35c0a8688d37a85638d22ce795914696fc39091196c1fb1b94b7b2	699
`.trim().split("\n").map((line) => {
  const [id, path, moduleHash, aggregateHash, cap] = line.split("\t");
  return { id, path, moduleHash, aggregateHash, cap: Number(cap) };
});
const DECLARATIONS = `
P	run-project.js	runToTiptap	1288	2356	2463	ade03c41c44bfa66577232ec193251db3ccf4fe373bcb009ffd597279f309c1e	2a0fe662d6db5f079323ad034e2f152acf33cfebde990abb6272bc56ba825b77
P	run-project.js	OBJECT_OVERRIDES	2463	2990	3018	7b202892244e22295d7f9b7ddcb3bf00ec2ab32e93629bdab4f448896f8eba53	fbd25d518aebbe3de32515a484e7816c9bea9d01db181b22f6a3acfdcedc7e8a
P	run-project.js	withObjectOverrides	3018	3020	3232	a94ad7e7977ce2844027936708e9f864b32e6af7a4dd28eae7cbab079bddb7f0	0beb0521892bbd832ba5bc3b56fc3c0861f6e9beb01de4248c674c1d03e36eb6
P	run-project.js	blockToNode	3232	3569	14367	3d6bc15423d6a1a24a0c62be38ac20e7b1bc08d56f1236ba9b6b667c5444b1dd	9b092e4e88385d05eef7f6ceee3b69c50fb12087ebb60675246a1102bcf6c665
P	run-project.js	sectionBlockToNode	14367	16138	18463	12c14ab1174c137cd76bc53c985d67df9b9261352964a4b3dacae21aea09a531	6144df2858b595b7169f4fafe71c26f95f81fa8ba9d68f729d7b183e256e33d4
P	run-project.js	expandableBody	18463	19060	19330	d5523c04ed489cb1074d6c4f18f012e51e56ab220ed9afd9332015845eda65e1	cbf46eb07920f63038240c6b47c2c4013cdd7566033e39f1271a31b994701d80
P	run-project.js	expandableBlockToNode	19330	19332	20026	d902050ed5028b85613d2eb427933dcd7af7485673dda28d18c935d74cd5c442	bab4fd6c2e99353d32cfd9e85efa9488d5225967f74d47d0552fd28700150bf6
P	run-project.js	rowsBody	20026	20604	20854	d07dabff8e71848aeae5a36c5ccb9faebed82b85116c830308a9888ae648716c	14447a06f1f72f1e58776620a79a40969023498ee4d3f64ff063c34cbec91b4f
P	run-project.js	rowsBlockToNode	20854	20856	22007	0ad30d54ea8ca79da13ae4fbabfcf46bf65fb09bea98ead1a65bdc916abf7806	fa3d8fa5b8b64de6e8196a8ec607f73af076daa1627b375507704ccefa19d2b7
P	run-project.js	childBlockToNode	22007	22577	23052	794bae9158c19a2753861ac760e0892fbd4f12789c560e19d644b94a083eae90	d12b04b55350b122ca60ba4592b2df7f534873ba21cbfe33e0f331b6c8626505
P	run-project.js	columnAtomBlockToNode	23052	23481	23706	0bd0a12a33ce119804d67d02ccaaa5dca0da5ed625d23b42f02f6e5dcda25ce1	cb33b252822d810e5cd02907762016122a9cb15c64d2a4b613808f90d0abba14
P	run-project.js	columnsBlockToNode	23706	24219	24839	1a4a77e618590e0e5521bb6546bc2453adcf1e0237c57369f16eafe80e23a36d	29d57e0e8a83609b887a9e208f542c8a195d06ddfff936ed4c43055b9a37f298
P	run-project.js	terminalChildBlockToNode	24839	26474	26721	f7ae18e62430031a704ebd7a3fd09b83e40a839377d1b4e56a0843c2bf7c98c3	044ba62499e8b65bea3e6e09748daf033dfac91af8142bb48bb19d1b8024bbf9
P	run-project.js	terminalAtomBlockToNode	26721	26998	27227	4c9e1e9d8db6b26a3e9ad13325be7fb63cf92e098c986b0c50386ed1152d44f3	c5460ba92248a3d9215a490146eb2a82f6a0a820b68d22ed4732d0301b53be82
P	run-project.js	terminalBlockToNode	27227	27675	28308	c5aa97f4bf1051ca93c5516f14aa6daadfe5bbd716c6bb733843b10d7df9df96	28a9f42461469e6d8afbb4ebd09f8cd094948a4bd2b2c81c63dfd0eb00a50fa4
N	run-node-core.js	walkBlockIds	650	1379	1888	0cb2ae20be5bd94a2aa5f81ef91f715491537474839ea387d5eda8cdb6c691d1	59426c638ca4d1c712c74be0c69949e6a84f31765248da8c2150d7b7e14eab05
N	run-node-core.js	blockParents	1888	2054	2442	4afd374be9046a50af148c0ba664c5b725e1e6b513965993dd9771544b8e39e1	4a9e69f99aaa6dba1353adf255d1609333d0468af1b421d3771ce9f85588bbcf
N	run-node-core.js	holdsNodeIds	2442	2660	2814	3f979ed21d995d3438d7d2065d120aa67093845698a79f9a05a0e9d0ea693af6	62c498021280256ca5e1f247e214b8e9a278f022b06200d551312167c1b0b5ec
N	run-node-core.js	walkNodeIds	2814	2939	3182	71ab9a4371207b59f5de3004df05bd50c5bcff40c01298b0b98dcf9ae4691eea	a4bd7429bf9aafab52703fb6b2f433242962e86aae178e8af96aec11da8b52ac
N	run-node-core.js	isEmptyParagraphBlock	3182	4986	5141	98cd5657de93f9ed79d4066f49779c3416b744b6e4b709756976bda261c45471	fa47f7495c56c4601718ce7ffb2ad25519ec503f100901cc089ac4d7a6c6292b
N	run-node-core.js	nodeToDocEnvelope	5141	6311	6390	d9f9159b2f0d93b353d9433c57443198557ea8a0b1f8151989c87055a54ccdea	7287122a6a621200aa4ce7676238cdab4d33b9378b945e99e9441edfabe832cd
N	run-node-core.js	mintId	6390	7136	7471	92b9a92200692ac410d0cc9c1b1ef3c524d3bfbc21c86782e1f67f97f63ef34f	3647032682967afec7784079f65448a8ded9eb34ff161850611ab242c2ca8bf7
N	run-node-core.js	mintCounter	7471	7473	7493	b8e20e4408c8f4f25d912a78ce7c8795b7ec4cd95ebf4921cfda59d7f4e996fe	9fac0eddac6887be1e81d77b89414dea01943cd66a5e2e4017dbc86459d037ce
N	run-node-core.js	randomNonce	7493	7768	7974	0dd94fc1a3c048be7be2643498c652ec2aa277f021454779874bdd3924b0abfa	29b7c545252b5580197cfa6f876d53b82a6fb26427e866322225c03e68453a5e
N	run-node-core.js	proseNodeChanged	7974	8283	8396	06c05c6ff286d31c1e2721e54a27f2c003f1d560bd29f1627e6a6a9877855cdf	e38de742dc7ac242ab18df64bb1b0451ba8136bc2d306be3322e3045b6c7feb3
N	run-node-core.js	stableProseKey	8396	8858	9511	84f76beef4c771b00c1c7df296d4c30fc3d85cbd8e9386e81eb2d2b64dafd6fa	713386976cb212e29905a1ad88fafaacf2805d81d3df203a995a0f8472e1601b
N	run-node-core.js	classifyNode	9511	10187	14187	edff2b7562c75f0f154a035ba10ccef09296a855e8a37f9ccbe2c0232fb9f524	154c45ab91e8e5a110de545cc12a06368c966c463486774ad974859e00c9063c
N	run-node-core.js	pendingUploadIndexes	14187	15945	16433	e7dbcb06cec6a296d4623e6bd8fcf0709c149c757af30cc02914f63b13f0da15	69ef0a0b980541e348081f6f6fcada6c8d4a4ff885ac424ea2723f29361cd4eb
C	run-container-codecs.js	CONTAINER_MODELED_KEYS	1121	1947	2177	97b8ce00a79b54812e9b771a08231715a725335878e7676b44d5151e0d0faeb5	a7c95db2d3eeb87eb1e620cce8b563836b915841b588d04ac037ac5153ebd6b7
C	run-container-codecs.js	carryUnmodeledKeys	2177	2178	2527	72adc50bce2634b4a09d8aa35a01c0273de23698bdfa5e7de7daa5d0ce8697fa	27c958aae1604351d32f31149dfa4ac16d1ae01e4958e9223c25a43dd947a530
C	run-container-codecs.js	carryRowKeys	2527	2688	3488	9458276087d0070eed03c6be3e14d8c106a613d82e7d4236503aad1bb43ef348	7e26a390b91e1aaf6423f4a460beb2de7778218fa41a9b1b6ce1856f0494cfdc
C	run-container-codecs.js	sectionNodeToBlock	3488	3490	5551	8dd92a073df9cd319a415070a8cf390fdf7e436aecf761c86205a993a21a6b0b	e83f7a59607d8eb102d5d1d083cb79a4baec86410aa4654e7105d0690351a656
C	run-container-codecs.js	expandableNodeToBlock	5551	5553	6252	78ff8e2092e1bc74ab4e0bf78a249e6e59510dc4520ae03f15383ae2472e8585	c9b73fcb146ded24c40ae70c4f41b24dcda825cfbe1b8de03b4e01dff4d8b20b
C	run-container-codecs.js	expandableSummaryChanged	6252	6254	6476	adca28b0b2dd484b833808a02ff5198355ae6b28f474d8e1620fcb948256c99e	3986b1fbcde685af5516890d4b96f39d843bef857f1adf9afc259f5d32553938
C	run-container-codecs.js	expandableSummaryPatch	6476	6478	6645	1ae2529d912dc86af79094ad9f3d9908cd892a6ea029a626a0b316bb7b78ac98	f7828619c5725afa5e28727071212aa99ae5fedb74cc75d422af706663250a41
C	run-container-codecs.js	expandableChildPatchOps	6645	6807	6997	3654f3ebb860d422480165be40a505a2d8ee5d64f3308abd8370fb3e4484ca18	6c810f48c0c3391eb1da9df8391e55a657f61dd5e0abe460b48e234bcd7b2696
C	run-container-codecs.js	stableExpandableKey	6997	6999	7265	bb880d82d6df02dc590986d9e18362cb94ba88f96093c1ca79e3a10d3b918ba6	256cc9c37a37f0404dc9e84eeac95b95c9aee52af422e77b2a8098ac07347638
C	run-container-codecs.js	rowsNodeToRows	7265	7433	8770	ca6064c99fafb464cf25e62fd3f1e48ee62a857ac696b0397c4e261f74c89e6b	4b5f2e84ef3b4089412c69a16a9fa17d0dd338605b6c1317e0133aa47aaafdda
C	run-container-codecs.js	rowsNodeToBlock	8770	8772	9052	55a850a08b3c286d953d8f65f196c7d541d9849ba8b2e60dd31af7e992022e85	e26b25360fdae4dcd6760d04d2f3e05f33231bf99f4b279406cd6c9488add418
C	run-container-codecs.js	stableRowsKey	9052	9290	9640	d2b3d48145b283b2fbfbab96834b9df4b8d7a40498354b5132f7ba5643b8147d	b1bbcaebf23c64190a66aed556925fc7e33af1a8c15425c500c049d14cbb3ffd
C	run-container-codecs.js	rowsNodeChanged	9640	9642	9752	5b092f56bb2dcca8073c72926e977354a3c5d333c4b2676f2cd5094f3f55ddab	4fdbe76462d9f9538017a4d7f32109a8c4825a0354aee8a174d85e9576ee0611
C	run-container-codecs.js	sectionChildIdSeq	9752	10105	10261	ca084f762f343a9e488ca2ad8777c53b5fe17ff6f8a6c9bda80ecc61ba52ed6e	5ec9a1115ca159b6c30a88dc457448649787e3e3a90a9825960fc4ea2115d161
C	run-container-codecs.js	sectionChildSeqChanged	10261	10431	10705	18141e56952e1dc1c94525bf3bb92223e993e813453e9c9ccd28661a51c5b817	77d0c744b4c14a3b801cd2d49b9000b1736bb83af8058ff7973b06f9e7de9f33
C	run-container-codecs.js	sectionTitleChanged	10705	11104	11319	5fe035ca049e9ad543cf51e40abe8249822df6242c3c042d761c3c67bed8db3b	2887106736bc06ff5717991aa2df222a0b9a4a76b2abc494d6a1349401dae312
C	run-container-codecs.js	sectionTitlePatch	11319	11576	11734	0be5f10fd0955a6cdffb56670c9dd78669b9edfd3ab817f2d4df5ab7931d9299	bb874916c3675d164420c9e631638f93bbb61bb9198e42e6bc5110c31cfba62b
C	run-container-codecs.js	normLayout	11734	12178	12291	977f6034f8d9ab9267f0ba299e624ed7985ee39f0f25de5b523f78fef05ff414	01917e74e86a33d62a1458edcdd4d8bfc452c8c7b4f7e5bd27f945d57fea6016
C	run-container-codecs.js	sectionLayoutChanged	12291	12293	12432	93fcd1f5e56af26e090c59f497ee6393409e428e83ed05842bd7a5c4ca401e2a	db1458533ef976e5cbf2a95a0791203a5e4255b8d6f6c458c2449c9970b1e9ab
C	run-container-codecs.js	sectionLayoutPatch	12432	12689	12838	965d8c8d143083b964ca8b22d9eaed31458b46fdd0803cc082dd188e0dae5aa7	95a199626aef64523fa1f1e9bbcc4a65c13b026eca46d89dad196ac5ff155b63
C	run-container-codecs.js	sectionChildPatchOps	12838	13153	13933	44a200231a335b134490edce4a0d3b5d407a324a7848478b83bf0060312d3d53	f9f87148ded5d020604d8de8d875cc0bdfa3070b79c988dc06fb9d12b9ea9650
C	run-container-codecs.js	childInteriorPatch	13933	14333	17480	31fbb0ca22c43971ba8a4b1998f710f83f5d65bb0db7da5658fb55ac4a955383	2866d96b502e133dccfa502deceac022f90683746520af91c82917d16162ccc0
C	run-container-codecs.js	childNodeToBlock	17480	17793	18537	7265e32d8bd3669d633d390fc504182616566e1ea2ddb7fb4158e2ddc932f241	4b639c1ea659bbbba79d58c8ac664b64d0be0f49bd27afbec6bd4e5b8a16c83b
C	run-container-codecs.js	columnNodeChildren	18537	18702	18902	154c1f891f2c0b61a0b67ee037fdbcb6e50da212722b325ebfeac4c10d51ec3c	f8219fdb2cbabb7e15093eaea14cfc89766202307c9a4db862950c67cb573823
C	run-container-codecs.js	columnsNodeToColumns	18902	19242	19346	3854bd8a8f86334e75c274397f49b002f69100dc8ecc31679ff82d8ade5ebfe7	1c08afa4bcff53e067bceba6549e689fce79f89c0f6a9dfef1cb4ef83b5dde25
C	run-container-codecs.js	columnsNodeToBlock	19346	19799	19911	5f91af749b96a282cfbe38eff54c71dd8509f2805c6e4a3d2f9344b6e1767710	fdafccbc45bd435043d7cd92accb038df6b46aad01bfe6c9a900c5cbeb656c20
C	run-container-codecs.js	columnsNodeChanged	19911	20410	20581	1de1012f479c4f3ec28ea9666b62671d0b141e8e6d3267db81820b27f8d92079	06ed47177ea3f595beeb95f9199ef14ebdb780453248e18b5f21697e97d54d80
C	run-container-codecs.js	terminalChildNodeToBlock	20581	20893	21647	629375633b93158dcb13b20e0a154b718471946be4f0b64ec60f2ce482b6d342	7f5743d35131be2bbc00bdf38e06ee22c0c2c85964f07dc8bcd636fe3f793de4
C	run-container-codecs.js	terminalNodeChildren	21647	21962	22163	f82a7cfc90a77fccc0b67732faa768e3956f8c8663f69cc45e914b1098040d10	df979790929e0f9d8fc69c5f1f19280be56180d5a9a8af58f04b49814dfabe7c
C	run-container-codecs.js	terminalNodeToBlock	22163	22483	22798	be728cb81c13db23bd2c660a3db64d06cce975e90b090461df6720cdee898aba	b7ebf153b1fb2ce074c4a6eda7ff13796b1fed8e0da42b2a7268c7d2ce08caef
C	run-container-codecs.js	terminalNodeToPatch	22798	23229	23485	4ec1ece824afb53ec8d2a123e792b234c57c06046ec23f09c1d6d4e690f7265f	9dc0dc47b21cfd00f2a5cfe886d02c170514b0ad38f86942b30d9dee14e92146
C	run-container-codecs.js	stableTerminalKey	23485	23692	23946	e9e31759e3c1d18772a4884d6453dcd1c644162ed2e042c6fa1272493e21b561	19abe5c764ee4189e8d9b1b480df715dc9a7ba084c218482c3a570ef3728e6a5
C	run-container-codecs.js	terminalNodeChanged	23946	24129	24295	d93bf1b0fb43ed7c0feed93ef32fe3f4b08dd3cb43344e251f5daa77d43eebee	146f0c72b07e9fa40db4738dc63e931b6ec8fb45bbebec06173d386921be22a4
D	run-diff-utils.js	hasOverlappingOps	96	339	1156	2187107537795bd9044007aca72d140ebbf6b078fb16ae5544464a6f51e7d4c2	18a6165d2825546098a6025e3a380e704495f52ea7ed6c380cf3600dc6e50bf6
D	run-diff-utils.js	opsRebaseSafe	1156	1711	2657	16cecc4fddad304388eabdbf091968155ef0987148cce4aefae6c876f6f9c015	4af2cf3d94a1407fcf8e8bbb55ab39344bef5f66c3ad33578280b135b344c584
D	run-diff-utils.js	minimalMoves	2657	3135	4414	cae76be7111d625a16dde569f83dd9e9ab32d3b3878939e5e0381c8974463b4f	d8a5b4b5ee97164d65bb740dd9386615e4591430d2dee42bbafae762aa525027
D	run-diff-utils.js	withAlignDrop	4414	4948	5362	d884e7979f70bdc72f879ddb98bea83d27d3b7221c6cb5f59cae5ffc80e61417	e1fbd494c3db1adde59fa66b2e79d66dbb2708bd99d156c49b3b91f3b373e0a6
D	run-diff-utils.js	withListStartDrop	5362	5775	6078	5c078584935df9d288e58b63b6f53760275459bd5ae09574d20f00aab3b75b1e	14c2a00a9bc5facf569dbafb51888f1e18ffbe606bd834d26740105a3c05cf73
R	run-reverse-echo.js	docToBlocks	1785	3261	4145	1d1e28744019daf0a48f77cebe82edec68c6af7cb27fb1730c9458c38c948aa9	27ff141359559795fb79173dc897635ee3ebea2ac12b20ca3b74eea725f2ea58
R	run-reverse-echo.js	reconcileServerEcho	4145	6496	8128	c30b57100a3f418fa721da335d982800758ce09e5986659d97164f1297da5bd3	4ef74943e2f857d2c53f6ea01f310182ac2d0a2446b06c04e4da697a0d26cd31
R	run-reverse-echo.js	nodeContentEqual	8128	8492	13587	84e627a0be3a2baba6a1afb018d14c8764d6f5e8a6fc379aa8a5bf3da49f26ff	efcc5c04940a7f39523aac6e50db4bbc89c79946aa6e429e05d9d4493ee244ab
R	run-reverse-echo.js	stableSectionKey	13587	13848	14610	bc179196ba0eebcd7da16c04c827ccfaeeeb06611dffb5d232ffbcca74549378	d73985965fee30803675c724bfc50dcef5e8f0a9361197d3db61ec355780ae7b
R	run-reverse-echo.js	carriedBlockEqual	14610	14806	15066	a2f4e53b40048455559a69bc9a63fb00489b84c9b8fceb01e3c2c0daa68fdcd0	289745f0cd653540bb4a791ffdafd500cc2f00b9cd9f78299845d7a1439d54fc
R	run-reverse-echo.js	stripId	15066	15148	15285	b6d8b8bca96037af77ad73b3de74503c20ad51b22061213cf97f1104ece00e75	69b7be1b0f288fea49bee5bded5a5c461e0b3cbf27e1a260f2985027eed3507e
R	run-reverse-echo.js	nextNodeToBlock	15285	15808	22547	9ea4bee07d9bf7cd2421c5904474023aca3317f68b251dcf3179c93505ba4f67	da02350ed38ca8b1ef7e8b9d8f6d8660002caf2cb00fad3078d2c4d70fc04255
O	run-ops.js	runToOps	1842	1844	29957	4116cbc3b5d3b01c345dbd72017787fec55064c019c8014443dd761748e298db	af94290a5d4a71fbbfbb9c19e25afe1d47807b758c0fa13c6fb8ab5341ec6097
`.trim().split("\n").map((line) => {
  const [group, path, name, attachedStart, start, end, declHash, attachedHash] = line.split("\t");
  return { group, path, name, attachedStart: Number(attachedStart), start: Number(start), end: Number(end), declHash, attachedHash };
});
const IMPORTS = `
run-project.js	./run-kinds.js	BP_COLUMN_ATOM_NODE_NAME	BP_COLUMN_ATOM_NODE_NAME
run-project.js	./run-kinds.js	BP_COLUMN_NODE_NAME	BP_COLUMN_NODE_NAME
run-project.js	./run-kinds.js	BP_TERMINAL_ATOM_NODE_NAME	BP_TERMINAL_ATOM_NODE_NAME
run-project.js	./run-kinds.js	CANVAS_CONTAINER_NODE_NAME	CANVAS_CONTAINER_NODE_NAME
run-project.js	./run-kinds.js	CANVAS_CONTAINER_NODE_NAMES	CANVAS_CONTAINER_NODE_NAMES
run-project.js	./run-kinds.js	CANVAS_EXPANDABLE_NODE_NAME	CANVAS_EXPANDABLE_NODE_NAME
run-project.js	./run-kinds.js	CANVAS_ROWS	CANVAS_ROWS
run-project.js	./run-kinds.js	TECHNICAL_ATOM_SHAPES	TECHNICAL_ATOM_SHAPES
run-project.js	./run-structured-codecs.js	actionBlockToNode	actionBlockToNode
run-project.js	../convert.js	blockToTiptap	blockToTiptap
run-project.js	./run-content-codecs.js	calloutBlockToNode	calloutBlockToNode
run-project.js	./run-content-codecs.js	cardBlockEditable	cardBlockEditable
run-project.js	./run-content-codecs.js	cardBlockToNode	cardBlockToNode
run-project.js	./run-scalar-codecs.js	codeBlockToNode	codeBlockToNode
run-project.js	./projection-json.js	deepClone	deepClone
run-project.js	./run-scalar-codecs.js	diagramBlockToNode	diagramBlockToNode
run-project.js	./run-structured-codecs.js	fieldBlockToNode	fieldBlockToNode
run-project.js	./run-structured-codecs.js	figureBlockToNode	figureBlockToNode
run-project.js	./run-structured-codecs.js	fleetBlockToNode	fleetBlockToNode
run-project.js	./run-structured-codecs.js	imageBlockToNode	imageBlockToNode
run-project.js	./run-kinds.js	isCanvasActionType	isCanvasActionType
run-project.js	./run-kinds.js	isCanvasAtomType	isCanvasAtomType
run-project.js	./run-kinds.js	isCanvasAttrAtomType	isCanvasAttrAtomType
run-project.js	./run-kinds.js	isCanvasCardType	isCanvasCardType
run-project.js	./run-kinds.js	isCanvasContainerType	isCanvasContainerType
run-project.js	./run-kinds.js	isCanvasContentType	isCanvasContentType
run-project.js	./run-kinds.js	isCanvasFieldType	isCanvasFieldType
run-project.js	./run-kinds.js	isCanvasFigureType	isCanvasFigureType
run-project.js	./run-kinds.js	isCanvasFleetType	isCanvasFleetType
run-project.js	./run-kinds.js	isCanvasImageType	isCanvasImageType
run-project.js	./run-kinds.js	isCanvasIslandType	isCanvasIslandType
run-project.js	./run-kinds.js	isCanvasReadOnlyAtomType	isCanvasReadOnlyAtomType
run-project.js	./run-kinds.js	isCanvasRoleType	isCanvasRoleType
run-project.js	./run-kinds.js	isCanvasStageType	isCanvasStageType
run-project.js	./run-kinds.js	isCanvasTableType	isCanvasTableType
run-project.js	./run-kinds.js	isLiveTaskListBlock	isLiveTaskListBlock
run-project.js	./run-kinds.js	isNoteType	isNoteType
run-project.js	./run-kinds.js	isProseType	isProseType
run-project.js	./run-structured-codecs.js	islandBlockToNode	islandBlockToNode
run-project.js	./run-content-codecs.js	noteBlockToNode	noteBlockToNode
run-project.js	./run-structured-codecs.js	readOnlyAtomBlockToNode	readOnlyAtomBlockToNode
run-project.js	./run-scalar-codecs.js	roleBlockToNode	roleBlockToNode
run-project.js	./run-scalar-codecs.js	stageBlockToNode	stageBlockToNode
run-project.js	./run-template-attrs.js	stampTemplateAttrs	stampTemplateAttrs
run-project.js	./run-kinds.js	tableBlockEditable	tableBlockEditable
run-project.js	./table-convert.js	tableBlockToNode	tableBlockToNode
run-project.js	./run-structured-codecs.js	taskListBlockToNode	taskListBlockToNode
run-project.js	./run-scalar-codecs.js	technicalBlockToNode	technicalBlockToNode
run-node-core.js	./run-kinds.js	CANVAS_ATTR_ATOM_BP_TYPE_BY_NODE	CANVAS_ATTR_ATOM_BP_TYPE_BY_NODE
run-node-core.js	./run-kinds.js	CANVAS_CONTAINER_BP_TYPE_BY_NODE	CANVAS_CONTAINER_BP_TYPE_BY_NODE
run-node-core.js	./run-kinds.js	CANVAS_IMAGE_NODE_NAME	CANVAS_IMAGE_NODE_NAME
run-node-core.js	./run-kinds.js	CANVAS_ISLAND_BP_TYPE_BY_NODE	CANVAS_ISLAND_BP_TYPE_BY_NODE
run-node-core.js	./run-kinds.js	CANVAS_READONLY_ATOM_BP_TYPE_BY_NODE	CANVAS_READONLY_ATOM_BP_TYPE_BY_NODE
run-node-core.js	./run-kinds.js	CANVAS_ROW_NODE_NAMES	CANVAS_ROW_NODE_NAMES
run-node-core.js	./run-kinds.js	CONVERTIBLE_KINDS	CONVERTIBLE_KINDS
run-node-core.js	./run-kinds.js	CONVERTIBLE_NODE_KIND	CONVERTIBLE_NODE_KIND
run-node-core.js	./projection-json.js	canonicalJSON	canonicalJSON
run-node-core.js	./run-kinds.js	isCanvasActionNode	isCanvasActionNode
run-node-core.js	./run-kinds.js	isCanvasAtomType	isCanvasAtomType
run-node-core.js	./run-kinds.js	isCanvasAttrAtomNode	isCanvasAttrAtomNode
run-node-core.js	./run-kinds.js	isCanvasCardNode	isCanvasCardNode
run-node-core.js	./run-kinds.js	isCanvasContainerNode	isCanvasContainerNode
run-node-core.js	./run-kinds.js	isCanvasContentType	isCanvasContentType
run-node-core.js	./run-kinds.js	isCanvasFieldNode	isCanvasFieldNode
run-node-core.js	./run-kinds.js	isCanvasFigureNode	isCanvasFigureNode
run-node-core.js	./run-kinds.js	isCanvasFleetNode	isCanvasFleetNode
run-node-core.js	./run-kinds.js	isCanvasImageNode	isCanvasImageNode
run-node-core.js	./run-kinds.js	isCanvasIslandNode	isCanvasIslandNode
run-node-core.js	./run-kinds.js	isCanvasReadOnlyAtomNode	isCanvasReadOnlyAtomNode
run-node-core.js	./run-kinds.js	isCanvasRoleType	isCanvasRoleType
run-node-core.js	./run-kinds.js	isCanvasStageNode	isCanvasStageNode
run-node-core.js	./run-kinds.js	isCanvasTableNode	isCanvasTableNode
run-node-core.js	./run-kinds.js	isCanvasTaskListNode	isCanvasTaskListNode
run-container-codecs.js	./run-kinds.js	BP_COLUMN_ATOM_NODE_NAME	BP_COLUMN_ATOM_NODE_NAME
run-container-codecs.js	./run-kinds.js	BP_TERMINAL_ATOM_NODE_NAME	BP_TERMINAL_ATOM_NODE_NAME
run-container-codecs.js	./run-kinds.js	CANVAS_CONTAINER_BP_TYPE_BY_NODE	CANVAS_CONTAINER_BP_TYPE_BY_NODE
run-container-codecs.js	./run-kinds.js	CANVAS_ROWS	CANVAS_ROWS
run-container-codecs.js	../convert.js	buildPatchBlockOp	buildPatchBlockOp
run-container-codecs.js	./run-content-codecs.js	calloutNodeChanged	calloutNodeChanged
run-container-codecs.js	./run-content-codecs.js	calloutNodeToPatch	calloutNodeToPatch
run-container-codecs.js	./projection-json.js	canonicalJSON	canonicalJSON
run-container-codecs.js	./run-content-codecs.js	cardNodeChanged	cardNodeChanged
run-container-codecs.js	./run-content-codecs.js	cardNodeToPatch	cardNodeToPatch
run-container-codecs.js	./run-node-core.js	classifyNode	classifyNode
run-container-codecs.js	./run-scalar-codecs.js	codeNodeChanged	codeNodeChanged
run-container-codecs.js	./run-scalar-codecs.js	codeNodeToPatch	codeNodeToPatch
run-container-codecs.js	./projection-json.js	deepClone	deepClone
run-container-codecs.js	./run-scalar-codecs.js	diagramNodeChanged	diagramNodeChanged
run-container-codecs.js	./run-scalar-codecs.js	diagramNodeToPatch	diagramNodeToPatch
run-container-codecs.js	./run-project.js	expandableBody	expandableBody
run-container-codecs.js	./run-structured-codecs.js	fieldNodeChanged	fieldNodeChanged
run-container-codecs.js	./run-structured-codecs.js	fieldNodeToPatch	fieldNodeToPatch
run-container-codecs.js	./run-structured-codecs.js	imageNodeChanged	imageNodeChanged
run-container-codecs.js	./run-structured-codecs.js	imageNodeToPatch	imageNodeToPatch
run-container-codecs.js	./run-node-core.js	isEmptyParagraphBlock	isEmptyParagraphBlock
run-container-codecs.js	./run-kinds.js	isNoteType	isNoteType
run-container-codecs.js	./run-kinds.js	isPlainObject	isPlainObject
run-container-codecs.js	./run-scalar-codecs.js	isTechnicalAtomNode	isTechnicalAtomNode
run-container-codecs.js	./run-structured-codecs.js	islandNodeChanged	islandNodeChanged
run-container-codecs.js	./run-structured-codecs.js	islandNodeToPatch	islandNodeToPatch
run-container-codecs.js	./run-node-core.js	mintId	mintId
run-container-codecs.js	./run-node-core.js	nodeToDocEnvelope	nodeToDocEnvelope
run-container-codecs.js	./run-content-codecs.js	noteNodeChanged	noteNodeChanged
run-container-codecs.js	./run-content-codecs.js	noteNodeToPatch	noteNodeToPatch
run-container-codecs.js	./run-node-core.js	proseNodeChanged	proseNodeChanged
run-container-codecs.js	./run-structured-codecs.js	readOnlyAtomRetargetPatch	readOnlyAtomRetargetPatch
run-container-codecs.js	./run-scalar-codecs.js	roleNodeChanged	roleNodeChanged
run-container-codecs.js	./run-scalar-codecs.js	roleNodeToPatch	roleNodeToPatch
run-container-codecs.js	./run-scalar-codecs.js	stageNodeChanged	stageNodeChanged
run-container-codecs.js	./run-scalar-codecs.js	stageNodeToPatch	stageNodeToPatch
run-container-codecs.js	./run-scalar-codecs.js	technicalNodeChanged	technicalNodeChanged
run-container-codecs.js	./run-scalar-codecs.js	technicalNodeToPatch	technicalNodeToPatch
run-container-codecs.js	../convert.js	tiptapToBlock	tiptapToBlock
run-container-codecs.js	./run-diff-utils.js	withAlignDrop	withAlignDrop
run-diff-utils.js	./projection-json.js	canonicalJSON	canonicalJSON
run-diff-utils.js	../convert.js	listStart	listStart
run-reverse-echo.js	./run-kinds.js	CANVAS_CONTAINER_BP_TYPE_BY_NODE	CANVAS_CONTAINER_BP_TYPE_BY_NODE
run-reverse-echo.js	./run-structured-codecs.js	actionNodeChanged	actionNodeChanged
run-reverse-echo.js	./run-structured-codecs.js	actionNodeToBlock	actionNodeToBlock
run-reverse-echo.js	../convert.js	buildPatchBlockOp	buildPatchBlockOp
run-reverse-echo.js	./run-content-codecs.js	calloutNodeChanged	calloutNodeChanged
run-reverse-echo.js	./run-content-codecs.js	calloutNodeToBlock	calloutNodeToBlock
run-reverse-echo.js	./projection-json.js	canonicalJSON	canonicalJSON
run-reverse-echo.js	./run-content-codecs.js	cardNodeChanged	cardNodeChanged
run-reverse-echo.js	./run-content-codecs.js	cardNodeToBlock	cardNodeToBlock
run-reverse-echo.js	./run-template-attrs.js	carryTemplateAttrs	carryTemplateAttrs
run-reverse-echo.js	./run-node-core.js	classifyNode	classifyNode
run-reverse-echo.js	./run-scalar-codecs.js	codeNodeChanged	codeNodeChanged
run-reverse-echo.js	./run-scalar-codecs.js	codeNodeToBlock	codeNodeToBlock
run-reverse-echo.js	./run-container-codecs.js	columnsNodeChanged	columnsNodeChanged
run-reverse-echo.js	./run-container-codecs.js	columnsNodeToBlock	columnsNodeToBlock
run-reverse-echo.js	./projection-json.js	deepClone	deepClone
run-reverse-echo.js	./run-scalar-codecs.js	diagramNodeChanged	diagramNodeChanged
run-reverse-echo.js	./run-scalar-codecs.js	diagramNodeToBlock	diagramNodeToBlock
run-reverse-echo.js	./run-container-codecs.js	expandableNodeToBlock	expandableNodeToBlock
run-reverse-echo.js	./run-structured-codecs.js	fieldNodeChanged	fieldNodeChanged
run-reverse-echo.js	./run-structured-codecs.js	fieldNodeToBlock	fieldNodeToBlock
run-reverse-echo.js	./run-structured-codecs.js	figureNodeChanged	figureNodeChanged
run-reverse-echo.js	./run-structured-codecs.js	figureNodeToBlock	figureNodeToBlock
run-reverse-echo.js	./run-structured-codecs.js	fleetNodeToBlock	fleetNodeToBlock
run-reverse-echo.js	./run-structured-codecs.js	imageNodeChanged	imageNodeChanged
run-reverse-echo.js	./run-structured-codecs.js	imageNodeToBlock	imageNodeToBlock
run-reverse-echo.js	./run-kinds.js	isCanvasActionNode	isCanvasActionNode
run-reverse-echo.js	./run-kinds.js	isCanvasAtomType	isCanvasAtomType
run-reverse-echo.js	./run-kinds.js	isCanvasAttrAtomNode	isCanvasAttrAtomNode
run-reverse-echo.js	./run-kinds.js	isCanvasCardNode	isCanvasCardNode
run-reverse-echo.js	./run-kinds.js	isCanvasContainerNode	isCanvasContainerNode
run-reverse-echo.js	./run-kinds.js	isCanvasContentType	isCanvasContentType
run-reverse-echo.js	./run-kinds.js	isCanvasFieldNode	isCanvasFieldNode
run-reverse-echo.js	./run-kinds.js	isCanvasFigureNode	isCanvasFigureNode
run-reverse-echo.js	./run-kinds.js	isCanvasFleetNode	isCanvasFleetNode
run-reverse-echo.js	./run-kinds.js	isCanvasImageNode	isCanvasImageNode
run-reverse-echo.js	./run-kinds.js	isCanvasIslandNode	isCanvasIslandNode
run-reverse-echo.js	./run-kinds.js	isCanvasReadOnlyAtomNode	isCanvasReadOnlyAtomNode
run-reverse-echo.js	./run-kinds.js	isCanvasRoleType	isCanvasRoleType
run-reverse-echo.js	./run-kinds.js	isCanvasStageNode	isCanvasStageNode
run-reverse-echo.js	./run-kinds.js	isCanvasTableNode	isCanvasTableNode
run-reverse-echo.js	./run-kinds.js	isCanvasTaskListNode	isCanvasTaskListNode
run-reverse-echo.js	./run-kinds.js	isNoteType	isNoteType
run-reverse-echo.js	./run-scalar-codecs.js	isTechnicalAtomNode	isTechnicalAtomNode
run-reverse-echo.js	./run-structured-codecs.js	islandNodeChanged	islandNodeChanged
run-reverse-echo.js	./run-structured-codecs.js	islandNodeToBlock	islandNodeToBlock
run-reverse-echo.js	./run-node-core.js	mintId	mintId
run-reverse-echo.js	./run-node-core.js	nodeToDocEnvelope	nodeToDocEnvelope
run-reverse-echo.js	./run-content-codecs.js	noteNodeToBlock	noteNodeToBlock
run-reverse-echo.js	./run-node-core.js	proseNodeChanged	proseNodeChanged
run-reverse-echo.js	./run-structured-codecs.js	readOnlyAtomNodeToBlock	readOnlyAtomNodeToBlock
run-reverse-echo.js	./run-scalar-codecs.js	roleNodeChanged	roleNodeChanged
run-reverse-echo.js	./run-scalar-codecs.js	roleNodeToBlock	roleNodeToBlock
run-reverse-echo.js	./run-container-codecs.js	rowsNodeChanged	rowsNodeChanged
run-reverse-echo.js	./run-container-codecs.js	rowsNodeToBlock	rowsNodeToBlock
run-reverse-echo.js	./run-project.js	runToTiptap	runToTiptap
run-reverse-echo.js	./run-container-codecs.js	sectionNodeToBlock	sectionNodeToBlock
run-reverse-echo.js	./run-container-codecs.js	stableExpandableKey	stableExpandableKey
run-reverse-echo.js	./run-content-codecs.js	stableNoteKey	stableNoteKey
run-reverse-echo.js	./run-scalar-codecs.js	stageNodeChanged	stageNodeChanged
run-reverse-echo.js	./run-scalar-codecs.js	stageNodeToBlock	stageNodeToBlock
run-reverse-echo.js	./table-convert.js	tableNodeChanged	tableNodeChanged
run-reverse-echo.js	./table-convert.js	tableNodeToBlock	tableNodeToBlock
run-reverse-echo.js	./run-structured-codecs.js	taskListNodeChanged	taskListNodeChanged
run-reverse-echo.js	./run-structured-codecs.js	taskListNodeToBlock	taskListNodeToBlock
run-reverse-echo.js	./run-scalar-codecs.js	technicalNodeChanged	technicalNodeChanged
run-reverse-echo.js	./run-scalar-codecs.js	technicalNodeToBlock	technicalNodeToBlock
run-reverse-echo.js	./run-container-codecs.js	terminalNodeChanged	terminalNodeChanged
run-reverse-echo.js	./run-container-codecs.js	terminalNodeToBlock	terminalNodeToBlock
run-reverse-echo.js	./run-node-core.js	walkNodeIds	walkNodeIds
run-ops.js	./run-kinds.js	CANVAS_ROWS	CANVAS_ROWS
run-ops.js	./run-kinds.js	CONVERTIBLE_KINDS	CONVERTIBLE_KINDS
run-ops.js	./run-structured-codecs.js	READ_ONLY_ATOM_RETARGET_KEY	READ_ONLY_ATOM_RETARGET_KEY
run-ops.js	./run-structured-codecs.js	actionNodeChanged	actionNodeChanged
run-ops.js	./run-structured-codecs.js	actionNodeToPatch	actionNodeToPatch
run-ops.js	./run-kinds.js	blockKind	blockKind
run-ops.js	../convert.js	buildPatchBlockOp	buildPatchBlockOp
run-ops.js	./run-content-codecs.js	calloutNodeChanged	calloutNodeChanged
run-ops.js	./run-content-codecs.js	calloutNodeToPatch	calloutNodeToPatch
run-ops.js	./projection-json.js	canonicalJSON	canonicalJSON
run-ops.js	./run-content-codecs.js	cardNodeChanged	cardNodeChanged
run-ops.js	./run-content-codecs.js	cardNodeToPatch	cardNodeToPatch
run-ops.js	./run-container-codecs.js	carryRowKeys	carryRowKeys
run-ops.js	./run-container-codecs.js	carryUnmodeledKeys	carryUnmodeledKeys
run-ops.js	./run-node-core.js	classifyNode	classifyNode
run-ops.js	./run-scalar-codecs.js	codeNodeChanged	codeNodeChanged
run-ops.js	./run-scalar-codecs.js	codeNodeToPatch	codeNodeToPatch
run-ops.js	./run-container-codecs.js	columnsNodeChanged	columnsNodeChanged
run-ops.js	./run-container-codecs.js	columnsNodeToColumns	columnsNodeToColumns
run-ops.js	./projection-json.js	deepClone	deepClone
run-ops.js	./run-scalar-codecs.js	diagramNodeChanged	diagramNodeChanged
run-ops.js	./run-scalar-codecs.js	diagramNodeToPatch	diagramNodeToPatch
run-ops.js	./run-container-codecs.js	expandableChildPatchOps	expandableChildPatchOps
run-ops.js	./run-container-codecs.js	expandableNodeToBlock	expandableNodeToBlock
run-ops.js	./run-container-codecs.js	expandableSummaryChanged	expandableSummaryChanged
run-ops.js	./run-container-codecs.js	expandableSummaryPatch	expandableSummaryPatch
run-ops.js	./run-structured-codecs.js	fieldNodeChanged	fieldNodeChanged
run-ops.js	./run-structured-codecs.js	fieldNodeToPatch	fieldNodeToPatch
run-ops.js	./run-structured-codecs.js	figureNodeChanged	figureNodeChanged
run-ops.js	./run-structured-codecs.js	figureNodeToPatch	figureNodeToPatch
run-ops.js	./run-structured-codecs.js	fleetNodeChanged	fleetNodeChanged
run-ops.js	./run-structured-codecs.js	fleetNodeToPatch	fleetNodeToPatch
run-ops.js	./run-structured-codecs.js	imageNodeChanged	imageNodeChanged
run-ops.js	./run-structured-codecs.js	imageNodeToPatch	imageNodeToPatch
run-ops.js	./run-kinds.js	isNoteType	isNoteType
run-ops.js	./run-scalar-codecs.js	isTechnicalAtomNode	isTechnicalAtomNode
run-ops.js	./run-structured-codecs.js	islandNodeChanged	islandNodeChanged
run-ops.js	./run-structured-codecs.js	islandNodeToPatch	islandNodeToPatch
run-ops.js	./run-diff-utils.js	minimalMoves	minimalMoves
run-ops.js	./run-node-core.js	mintId	mintId
run-ops.js	./run-reverse-echo.js	nextNodeToBlock	nextNodeToBlock
run-ops.js	./run-node-core.js	nodeToDocEnvelope	nodeToDocEnvelope
run-ops.js	./run-content-codecs.js	noteNodeChanged	noteNodeChanged
run-ops.js	./run-content-codecs.js	noteNodeToPatch	noteNodeToPatch
run-ops.js	./run-node-core.js	proseNodeChanged	proseNodeChanged
run-ops.js	./run-structured-codecs.js	readOnlyAtomRetargetPatch	readOnlyAtomRetargetPatch
run-ops.js	./run-scalar-codecs.js	roleNodeChanged	roleNodeChanged
run-ops.js	./run-scalar-codecs.js	roleNodeToPatch	roleNodeToPatch
run-ops.js	./run-container-codecs.js	rowsNodeChanged	rowsNodeChanged
run-ops.js	./run-container-codecs.js	rowsNodeToRows	rowsNodeToRows
run-ops.js	./run-project.js	runToTiptap	runToTiptap
run-ops.js	./run-container-codecs.js	sectionChildPatchOps	sectionChildPatchOps
run-ops.js	./run-container-codecs.js	sectionChildSeqChanged	sectionChildSeqChanged
run-ops.js	./run-container-codecs.js	sectionLayoutChanged	sectionLayoutChanged
run-ops.js	./run-container-codecs.js	sectionLayoutPatch	sectionLayoutPatch
run-ops.js	./run-container-codecs.js	sectionNodeToBlock	sectionNodeToBlock
run-ops.js	./run-container-codecs.js	sectionTitleChanged	sectionTitleChanged
run-ops.js	./run-container-codecs.js	sectionTitlePatch	sectionTitlePatch
run-ops.js	./run-scalar-codecs.js	stageNodeChanged	stageNodeChanged
run-ops.js	./run-scalar-codecs.js	stageNodeToPatch	stageNodeToPatch
run-ops.js	./run-reverse-echo.js	stripId	stripId
run-ops.js	./table-convert.js	tableNodeChanged	tableNodeChanged
run-ops.js	./table-convert.js	tableNodeToPatch	tableNodeToPatch
run-ops.js	./run-structured-codecs.js	taskListNodeChanged	taskListNodeChanged
run-ops.js	./run-structured-codecs.js	taskListNodeToPatch	taskListNodeToPatch
run-ops.js	./run-scalar-codecs.js	technicalNodeChanged	technicalNodeChanged
run-ops.js	./run-scalar-codecs.js	technicalNodeToPatch	technicalNodeToPatch
run-ops.js	./run-container-codecs.js	terminalNodeChanged	terminalNodeChanged
run-ops.js	./run-container-codecs.js	terminalNodeToPatch	terminalNodeToPatch
run-ops.js	../convert.js	tiptapToBlock	tiptapToBlock
run-ops.js	./run-node-core.js	walkBlockIds	walkBlockIds
run-ops.js	./run-diff-utils.js	withAlignDrop	withAlignDrop
run-ops.js	./run-diff-utils.js	withListStartDrop	withListStartDrop
`.trim().split("\n").map((line) => line.split("\t"));
const CALLBACK_EDITS = `
function sectionNodeToBlock(node, id, taken) {	function sectionNodeToBlock(node, id, taken, nextNodeToBlock) {	1
function expandableNodeToBlock(node, id, taken) {	function expandableNodeToBlock(node, id, taken, nextNodeToBlock) {	1
function rowsNodeToRows(node, bpType, taken) {	function rowsNodeToRows(node, bpType, taken, nextNodeToBlock) {	1
function rowsNodeToBlock(node, id, taken) {	function rowsNodeToBlock(node, id, taken, nextNodeToBlock) {	1
[spec.rowsKey]: rowsNodeToRows(node, bpType, taken)	[spec.rowsKey]: rowsNodeToRows(node, bpType, taken, nextNodeToBlock)	1
rowsNodeToRows(entry.node, entry.bpType, taken),	rowsNodeToRows(entry.node, entry.bpType, taken, nextNodeToBlock),	1
expandableNodeToBlock(entry.node, entry.id, taken),	expandableNodeToBlock(entry.node, entry.id, taken, nextNodeToBlock),	1
sectionNodeToBlock(entry.node, entry.id, taken),	sectionNodeToBlock(entry.node, entry.id, taken, nextNodeToBlock),	1
sectionNodeToBlock(node, entry.id, taken || new Set());	sectionNodeToBlock(node, entry.id, taken || new Set(), nextNodeToBlock);	1
expandableNodeToBlock(node, entry.id, taken || new Set());	expandableNodeToBlock(node, entry.id, taken || new Set(), nextNodeToBlock);	1
rowsNodeToBlock(node, entry.id, taken || new Set());	rowsNodeToBlock(node, entry.id, taken || new Set(), nextNodeToBlock);	1
`.trim().split("\n").map((line) => {
  const [before, after, count] = line.split("\t");
  return { before, after, count: Number(count) };
});

assert.equal(GROUPS.length, 6, "all six production leaves are guarded");
assert.equal(DECLARATIONS.length, 74, "all 74 declarations are guarded");
assert.equal(IMPORTS.length, 259, "all 259 pre-proved import-owner records are guarded");
assert.equal(CALLBACK_EDITS.length, 11, "the callback seam stays limited to 11 edits");
const sources = Object.fromEntries(GROUPS.map(({ path }) => [path, readFileSync(resolve(here, path), "utf8")]));
const rootSource = readFileSync(resolve(here, "run-convert.js"), "utf8");

for (const group of GROUPS) {
  const source = sources[group.path];
  assert.ok(source.split("\n").length - 1 < 700, `${group.path} remains below 700 physical lines`);
  assert.ok(source.split("\n").length - 1 <= group.cap, `${group.path} remains below its planned cap`);
  assert.doesNotMatch(source, /export\s+\*/u, `${group.path} uses explicit exports`);
  assert.doesNotMatch(source, /from ["']\.\/run-convert\.js["']/u, `${group.path} never imports the facade`);
}
assert.ok(rootSource.split("\n").length - 1 < 800, "the public facade stays below 800 physical lines");
assert.ok(readFileSync(fileURLToPath(import.meta.url), "utf8").split("\n").length - 1 < 800,
  "the permanent boundary stays below 800 physical lines");
assert.doesNotMatch(rootSource, /export\s+\*/u, "the facade uses direct named re-exports");

const leafPaths = new Set(GROUPS.map(({ path }) => resolve(here, path)));
const actualImports = [];
for (const [consumer, source] of Object.entries(sources)) {
  const importDeclarations = [...source.matchAll(/(?:^|\n)\s*import(?!\s*[.(])[\s\S]*?;/gu)];
  const reexports = [...source.matchAll(
    /(?:^|\n)\s*export\s+(?:\*(?:\s+as\s+[\w$]+)?|\{[\s\S]*?\})\s+from\s*["'][^"']+["']\s*;/gu,
  )];
  const namedImports = [...source.matchAll(
    /(?:^|\n)\s*import\s*\{([\s\S]*?)\}\s*from\s*["']([^"']+)["']\s*;/gu,
  )];
  assert.equal(importDeclarations.length + reexports.length, namedImports.length,
    `${consumer} uses only the approved named static import form`);
  for (const match of namedImports) {
    for (const token of match[1].split(",").map((value) => value.trim()).filter(Boolean)) {
      const [imported, local = imported] = token.split(/\s+as\s+/u);
      actualImports.push([consumer, match[2], imported, local]);
    }
  }
}
// field-node.js and field-settings.js have one historical SCC below the structured-codec
// boundary. This graph is deliberately the six newly extracted leaves: those leaves must
// remain a DAG, and the exhaustive import table above fails closed on every other edge form.
const leafDependencies = new Map([...leafPaths].map((path) => [path, new Set()]));
for (const [consumer, specifier] of actualImports) {
  if (!specifier.startsWith(".")) continue;
  const dependency = resolve(dirname(resolve(here, consumer)), specifier);
  if (leafPaths.has(dependency)) leafDependencies.get(resolve(here, consumer)).add(dependency);
}
const visiting = new Set();
const visited = new Set();
function walkLeaf(file) {
  assert.ok(!visiting.has(file), `the six-leaf converter graph is acyclic at ${file}`);
  if (visited.has(file)) return;
  visiting.add(file);
  for (const dependency of leafDependencies.get(file)) walkLeaf(dependency);
  visiting.delete(file);
  visited.add(file);
}
for (const path of leafPaths) walkLeaf(path);

const orderRows = (rows) => rows.map((row) => row.join("\t")).sort();
assert.deepEqual(orderRows(actualImports), orderRows(IMPORTS),
  "named import syntax equals the independently pre-proved owner table in both directions");

for (const { before, after, count } of CALLBACK_EDITS) {
  const all = Object.values(sources).join("\n");
  assert.equal(all.split(after).length - 1, count, `approved callback edit appears once: ${after}`);
  assert.equal(all.split(before).length - 1, 0, `superseded callback form is absent: ${before}`);
}

for (const group of GROUPS) {
  const source = sources[group.path];
  let aggregate = "";
  for (const entry of DECLARATIONS.filter(({ group: id }) => id === group.id)) {
    const declaration = source.slice(entry.start, entry.end);
    const attached = source.slice(entry.attachedStart, entry.end);
    assert.equal(sha256(declaration), entry.declHash, `${entry.name} declaration stays exact`);
    assert.equal(sha256(attached), entry.attachedHash, `${entry.name} comments and body stay exact`);
    aggregate += `${entry.name}\0${attached}\0`;
  }
  assert.equal(sha256(aggregate), group.aggregateHash, `${group.path} aggregate stays exact`);
  assert.equal(sha256(source), group.moduleHash, `${group.path} keeps its exact projected source`);
}

console.log("run-convert endstate extraction boundary passed");
