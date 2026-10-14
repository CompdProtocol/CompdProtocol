import { createHash } from 'node:crypto';
import { appendFile, mkdir, open, readFile, unlink } from 'node:fs/promises';
import { dirname } from 'node:path';
import { canonicalJson, addressHex, bytes32Hex } from './codec.mjs';
import { verifyInputBundle } from './core.mjs';

export const REVIEW_SECONDS = 1_800n;
export const AUTOMATION_EXECUTOR = '0xb878884a07fc84e6a1336e15ca8c6580cd7164c3';
const PRODUCTION_EXECUTION_AUTHORITY = Symbol('application-owned production execution service');
export const PHASE5_STATES = Object.freeze([
  'GENERATED', 'VERIFICATION_PENDING', 'VERIFIED', 'FINALIZER_READY', 'COMMIT_SUBMITTED',
  'REVIEW_PENDING', 'EXECUTABLE', 'EXECUTING', 'COMPLETED', 'FAILED_PENDING_MANUAL',
  'PAID_MANUALLY', 'SUPERSEDED', 'BLOCKED',
]);

const allowedTransitions = Object.freeze({
  GENERATED: { VERIFY: 'VERIFICATION_PENDING', BLOCK: 'BLOCKED' },
  VERIFICATION_PENDING: { VERIFIED: 'VERIFIED', REJECT: 'BLOCKED' },
  VERIFIED: { FINALIZER_READY: 'FINALIZER_READY', SUPERSEDE: 'SUPERSEDED', BLOCK: 'BLOCKED' },
  FINALIZER_READY: { SUBMITTED: 'COMMIT_SUBMITTED', SUPERSEDE: 'SUPERSEDED' },
  COMMIT_SUBMITTED: { ACCEPTED: 'REVIEW_PENDING', REJECT: 'BLOCKED', SUPERSEDE: 'SUPERSEDED' },
  REVIEW_PENDING: { CORRECTED: 'REVIEW_PENDING', REVIEW_ELAPSED: 'EXECUTABLE', SUPERSEDE: 'SUPERSEDED' },
  EXECUTABLE: { EXECUTING: 'EXECUTING', CORRECTED: 'REVIEW_PENDING', SUPERSEDE: 'SUPERSEDED' },
  EXECUTING: { PAID: 'COMPLETED', FAILED: 'FAILED_PENDING_MANUAL', SUPERSEDE: 'SUPERSEDED' },
  FAILED_PENDING_MANUAL: { MANUALLY_PAID: 'PAID_MANUALLY' },
});

/** Event-driven operational state, with all review timestamps sourced from canonical observations. */
export function transitionPhase5(state, event, evidence = {}) {
  if (!PHASE5_STATES.includes(state)) throw new Error('unknown Phase 5 state');
  const next = allowedTransitions[state]?.[event];
  if (!next) throw new Error(`invalid Phase 5 transition ${state} -> ${event}`);
  if (event === 'VERIFIED' && evidence.verification?.status !== 'VERIFIED') throw new Error('verified result required');
  if (event === 'ACCEPTED') {
    const acceptedAt = BigInt(required(evidence, 'acceptedAt'));
    const executableAfter = BigInt(required(evidence, 'executableAfter'));
    demand(executableAfter === acceptedAt + REVIEW_SECONDS, 'on-chain commitment review interval mismatch');
    demand(evidence.canonical === true, 'commitment acceptance must be canonical on-chain');
  }
  if (event === 'CORRECTED') {
    demand(BigInt(required(evidence, 'newVersion')) === BigInt(required(evidence, 'oldVersion')) + 1n,
      'correction version must increase exactly once');
    demand(BigInt(required(evidence, 'executableAfter')) === BigInt(required(evidence, 'acceptedAt')) + REVIEW_SECONDS,
      'correction must restart full on-chain review');
    demand(evidence.canonical === true, 'correction must be canonical on-chain');
  }
  if (event === 'REVIEW_ELAPSED') {
    demand(evidence.canonical === true && BigInt(required(evidence, 'blockTimestamp')) >= BigInt(required(evidence, 'executableAfter')),
      'review has not elapsed at canonical chain timestamp');
  }
  if (event === 'PAID') demand(evidence.canonical === true && evidence.paid === true && evidence.txHash,
    'on-chain canonical payout receipt required');
  if (event === 'FAILED') demand(evidence.canonical === true && evidence.failed === true,
    'on-chain automatic failure record required');
  if (event === 'MANUALLY_PAID') demand(evidence.canonical === true && evidence.paid === true && evidence.txHash,
    'on-chain manual settlement receipt required');
  if (event === 'SUBMITTED' || event === 'EXECUTING') demand(/^0x[0-9a-fA-F]{64}$/.test(evidence.txHash ?? ''),
    'transaction hash required to record a submitted transaction');
  return next;
}

const digest = value => `0x${createHash('sha256').update(value).digest('hex')}`;
const eq = (a, b) => typeof a === 'string' && typeof b === 'string' && a.toLowerCase() === b.toLowerCase();
const required = (obj, key) => {
  if (!obj || !Object.hasOwn(obj, key)) throw new Error(`missing required ${key}; fail closed`);
  return obj[key];
};

// This identity is auxiliary provenance only. It never feeds the frozen Phase 4 datasetHash/root.
// Addresses and balance lists are normalized semantically; event/header ordering remains canonical.
function semanticManifestProjection(input, result) {
  const normalizeBalances = list => [...list].map(x => ({
    address: addressHex(x.address, 'snapshot.address', { allowZero: false }), balance: String(x.balance),
  })).sort((a, b) => BigInt(a.address) < BigInt(b.address) ? -1 : BigInt(a.address) > BigInt(b.address) ? 1 : 0);
  return {
    datasetHash: result.dataset.datasetHash,
    root: result.dataset.merkle.root,
    dataset: result.dataset,
    normalizedHeaders: result.normalizedHeaders,
    normalizedEvents: result.normalizedEvents,
    initialState: {
      blockNumber: String(input.replay.initialState.blockNumber),
      blockHash: bytes32Hex(input.replay.initialState.blockHash),
      totalSupply: String(input.replay.initialState.totalSupply),
      balances: normalizeBalances(input.replay.initialState.balances),
    },
    checkpoint: {
      blockNumber: String(input.checkpoint.blockNumber), blockHash: bytes32Hex(input.checkpoint.blockHash),
      balances: normalizeBalances(input.checkpoint.balances), totalSupply: String(input.checkpoint.totalSupply),
    },
  };
}

export function semanticManifestIdentity(input, result = verifyInputBundle(input)) {
  return digest(canonicalJson(semanticManifestProjection(input, result)));
}

/** Phase 5 envelope joins Phase 4 output with normalized provenance while retaining raw input hash separately. */
export function createPhase5Candidate(input) {
  const result = verifyInputBundle(input);
  return Object.freeze({
    dataset: result.dataset,
    manifest: Object.freeze({
      semantic: semanticManifestProjection(input, result),
      semanticIdentity: semanticManifestIdentity(input, result),
      sourceRepresentationSha256: result.inputBundleHash,
      phase4SourceManifest: result.sourceManifest,
    }),
  });
}

/** Replays Phase 4 from the canonical input and requires byte-semantic equality of the full dataset. */
export function verifyCanonicalCandidate(input, candidate, manifest = undefined) {
  const result = verifyInputBundle(input);
  if (candidate?.dataset) { manifest ??= candidate.manifest; candidate = candidate.dataset; }
  if (!candidate || typeof candidate !== 'object' || Array.isArray(candidate)) throw new Error('candidate must be the complete Phase 4 dataset object');
  if (canonicalJson(candidate) !== result.datasetBytes) throw new Error('candidate differs from independent Phase 4 replay; no Finalizer readiness');
  if (!result.dataset.merkle.root || result.dataset.finalizedTotalPayable === '0') throw new Error('candidate has no payable root');
  const semanticId = semanticManifestIdentity(input, result);
  if (!manifest || typeof manifest !== 'object' || !manifest.semantic) throw new Error('Phase 4 replay manifest is required for Finalizer readiness');
  if (canonicalJson(manifest.semantic) !== canonicalJson(semanticManifestProjection(input, result))
      || manifest.semanticIdentity !== semanticId) throw new Error('normalized replay manifest identity mismatch');
  if (!/^0x[0-9a-f]{64}$/i.test(manifest.sourceRepresentationSha256 ?? '')) throw new Error('raw source representation hash is missing');
  return Object.freeze({
    status: 'VERIFIED', distributionId: result.dataset.distributionId, windowId: result.dataset.windowId,
    version: Number(result.dataset.commitmentVersion), datasetHash: result.dataset.datasetHash,
    root: result.dataset.merkle.root, windowStart: result.dataset.window.start, windowEnd: result.dataset.window.end,
    rewardAsset: result.dataset.rewardAsset, pool: result.dataset.profitAttribution.windowPool,
    recipientCount: result.dataset.recipientCount, totalEligibleWeight: result.dataset.totalEligibleTop30Weight,
    checkpointNumber: result.dataset.replay.checkpointBlock, checkpointHash: result.dataset.replay.checkpointBlockHash,
    algorithmVersion: result.dataset.algorithmVersion, schemaVersion: result.dataset.schemaVersion,
    semanticManifestIdentity: semanticId, dataset: result.dataset,
  });
}

const unresolved = Object.freeze([
  'DISTRIBUTION_FINALIZER', 'HOLDER_REWARD_SETTLER_ROLE wallet', 'BNB finality policy',
  'verified activation block/timestamp', 'canonical production replay/checkpoint source',
  'Flap ERC-20 attribution dependency', 'deployed production Vault/Distributor addresses',
]);

export function requireProductionConfig(config) {
  if (!config || config.mode !== 'PRODUCTION') throw new Error('production mode must be explicit');
  for (const key of ['chainId', 'vault', 'distributor', 'finalizer', 'settler', 'automationExecutor', 'activation', 'finality', 'sourceAdapter', 'deploymentBlock', 'flapAttribution']) {
    if (!config[key]) throw new Error(`production ${key} unresolved; blocked by ${unresolved.join('; ')}`);
  }
  if (BigInt(config.chainId) !== 56n) throw new Error('wrong production chain; expected BNB Chain 56');
  if (addressHex(config.automationExecutor, 'automationExecutor', { allowZero: false }) !== AUTOMATION_EXECUTOR) {
    throw new Error('Automation Executor differs from canonical production identity');
  }
  if (config.finality.status !== 'VERIFIED' || !config.finality.reference || config.activation.status !== 'VERIFIED'
      || !config.activation.blockHash || config.activation.blockNumber === undefined || config.activation.timestamp === undefined
      || config.sourceAdapter.status !== 'VERIFIED' || !config.sourceAdapter.reference
      || config.flapAttribution.status !== 'VERIFIED' || !config.flapAttribution.reference
      || config.deploymentBlock.status !== 'VERIFIED' || config.deploymentBlock.blockNumber === undefined) {
    throw new Error('production finality, activation, deployment, Flap attribution and canonical source must be independently verified');
  }
  const finalizer = addressHex(config.finalizer, 'DISTRIBUTION_FINALIZER', { allowZero: false });
  const settler = addressHex(config.settler, 'HOLDER_REWARD_SETTLER_ROLE', { allowZero: false });
  if (finalizer === AUTOMATION_EXECUTOR || settler === AUTOMATION_EXECUTOR || settler === finalizer) {
    throw new Error('Finalizer, Automation Executor, and Holder Reward Settler must remain distinct');
  }
  if (!Array.isArray(config.otherRoleAddresses) || config.otherRoleAddresses.length === 0) {
    throw new Error('other production role identities remain unresolved');
  }
  const roles = config.otherRoleAddresses.map((x, i) => addressHex(x, `otherRoleAddresses[${i}]`, { allowZero: false }));
  if (new Set([finalizer, settler, ...roles]).size !== 2 + roles.length || roles.some(x => x === AUTOMATION_EXECUTOR)) {
    throw new Error('production role identities must be valid and distinct');
  }
  return true;
}

export function deterministicPaymentId(candidate, entry) {
  return digest(canonicalJson({
    chainId: String(candidate.chainId ?? 56), distributor: String(candidate.distributor).toLowerCase(),
    distributionId: candidate.distributionId.toLowerCase(), version: String(candidate.version),
    index: String(entry.recipientIndex), recipient: entry.recipient.toLowerCase(), amount: String(entry.amount),
    rewardAsset: String(entry.rewardAsset).toLowerCase(), leafHash: String(entry.leafHash).toLowerCase(),
  }));
}

function sameBig(a, b) { return BigInt(a) === BigInt(b); }
function demand(ok, message) { if (!ok) throw new Error(message); }

function snapshotBlockNumber(value) {
  let number;
  if (typeof value === 'number' && Number.isSafeInteger(value)) number = BigInt(value);
  else if (typeof value === 'bigint') number = value;
  else if (typeof value === 'string' && /^(0|[1-9][0-9]*)$/.test(value)) number = BigInt(value);
  else throw new Error('canonical snapshot blockNumber is missing or malformed');
  demand(number >= 0n && number <= BigInt(Number.MAX_SAFE_INTEGER), 'canonical snapshot blockNumber is out of range');
  return number;
}

function snapshotBlockHash(value, label = 'canonical snapshot blockHash') {
  demand(typeof value === 'string' && /^0x[0-9a-f]{64}$/i.test(value), `${label} is missing or malformed`);
  return value.toLowerCase();
}

async function readCanonicalPaymentSnapshot({ chain, dataset, index, version, mode }) {
  demand(typeof chain?.readPaymentSnapshot === 'function', 'canonical single-block payment snapshot adapter required');
  const snapshot = await chain.readPaymentSnapshot(dataset, index, Number(version));
  demand(snapshot && typeof snapshot === 'object' && !Array.isArray(snapshot), 'canonical payment snapshot unavailable');
  const blockNumber = snapshotBlockNumber(snapshot.blockNumber);
  const blockHash = snapshotBlockHash(snapshot.blockHash);
  demand(snapshot.canonical === true, 'payment snapshot is not canonical');
  demand(mode === 'TEST_ONLY' ? snapshot.testOnly === true : snapshot.testOnly === false,
    'snapshot mode does not match the explicit workflow mode');
  demand(snapshot.readsAt && snapshotBlockNumber(snapshot.readsAt.blockNumber) === blockNumber
    && snapshotBlockHash(snapshot.readsAt.blockHash, 'snapshot read blockHash') === blockHash,
  'payment snapshot reads are not anchored to its canonical block identity');
  demand(snapshot.distributionId === dataset.distributionId
    && Number(snapshot.version) === Number(version)
    && Number(snapshot.index) === index, 'payment snapshot identity mismatch');
  return snapshot;
}

/** Read-only chain preflight. Returns a narrowly scoped call plan; never signs or broadcasts. */
async function planAutomaticPaymentCore({ verified, entry, config, chain, journal }, authority) {
  if (config?.mode === 'PRODUCTION' && authority !== PRODUCTION_EXECUTION_AUTHORITY) {
    throw new Error('PRODUCTION planning is available only through the application-owned execution service');
  }
  if (!verified || verified.status !== 'VERIFIED') throw new Error('independently verified candidate required');
  if (config.mode === 'PRODUCTION') requireProductionConfig(config);
  else if (config.mode !== 'TEST_ONLY') throw new Error('workflow mode must be exactly TEST_ONLY or PRODUCTION');
  const ds = verified.dataset;
  if (!entry || typeof entry !== 'object' || Array.isArray(entry)
      || typeof entry.recipientIndex !== 'number' || !Number.isSafeInteger(entry.recipientIndex)) {
    throw new Error('explicit canonical recipient index required');
  }
  const index = entry.recipientIndex;
  demand(index >= 0 && index < ds.entries.length, 'recipient index out of bounds');
  const canonicalEntry = ds.entries[index];
  const leaf = ds.merkle.leaves[index];
  demand(canonicalEntry && leaf && canonicalEntry.index === String(index)
    && eq(canonicalEntry.address, entry.recipient), 'mutated recipient/index');
  demand(sameBig(canonicalEntry.payout, entry.amount) && sameBig(leaf.amount, entry.amount), 'mutated payout amount');
  demand(eq(leaf.leafHash, entry.leafHash) && canonicalJson(leaf.proof) === canonicalJson(entry.proof), 'mutated proof/leaf');
  demand(eq(ds.rewardAsset, entry.rewardAsset) && eq(ds.distributionId, entry.distributionId)
    && sameBig(ds.commitmentVersion, entry.version), 'mutated distribution/version/asset');
  demand(BigInt(entry.amount) > 0n, 'zero payout is not executable');
  const snapshot = await readCanonicalPaymentSnapshot({ chain, dataset: ds, index,
    version: ds.commitmentVersion, mode: config.mode });
  demand(Number(ds.chainId) === Number(snapshot.chainId), 'wrong chain');
  demand(eq(config.distributor, ds.distributor) && eq(config.vault, ds.vault), 'wrong contract binding');
  const id = deterministicPaymentId({ ...verified, chainId: config.chainId ?? 56, distributor: ds.distributor }, {
    ...entry, leafHash: leaf.leafHash,
  });
  if (!journal || typeof journal.get !== 'function' || typeof journal.claim !== 'function') {
    throw new Error('durable idempotency journal adapter required; no payment plan without it');
  }
  const prior = await journal.get(id);
  if (prior) {
    if (typeof chain.reconcileIntent !== 'function') throw new Error('existing intent requires authoritative chain reconciliation; refusing retry');
    const reconciliation = await chain.reconcileIntent(id, prior);
    if (!reconciliation || reconciliation.complete !== true) throw new Error('transaction intent remains uncertain; reconcile only, never resend');
    if (['PAID', 'FAILED_PENDING_MANUAL', 'PAID_MANUALLY'].includes(reconciliation.state)) {
      if (prior.state !== reconciliation.state) await journal.put(id, { ...prior, state: reconciliation.state, txHash: reconciliation.txHash });
      throw new Error(`chain reconciliation is terminal: ${reconciliation.state}`);
    }
    if (reconciliation.state !== 'NOT_SUBMITTED') throw new Error('existing transaction is unresolved; no retry');
  }
  // Always reconcile uncertain submissions from chain before any new plan.
  const observed = snapshot.paymentState;
  demand(observed && observed.canonical === true, 'uncanonical/stale payment state');
  demand(Number(observed.version) === Number(ds.commitmentVersion)
    && eq(observed.recipient, entry.recipient) && sameBig(observed.amount, entry.amount), 'snapshot payment state identity mismatch');
  demand(!observed.paid && !observed.failed && !observed.manualAvailable && !observed.terminal,
    'liability already paid, failed, manual, or terminal; never retry automatically');
  const candidate = snapshot.candidate;
  demand(candidate && Number(candidate.status) === 3, 'candidate is not EXECUTABLE');
  demand(sameBig(candidate.commitmentVersion, ds.commitmentVersion)
    && eq(candidate.domainSeparator, ds.domainSeparator) && eq(candidate.windowId, ds.windowId)
    && eq(candidate.root, ds.merkle.root) && eq(candidate.datasetHash, ds.datasetHash), 'stale/superseded candidate');
  demand(sameBig(candidate.windowStart, ds.window.start) && sameBig(candidate.windowEnd, ds.window.end)
    && eq(candidate.rewardAsset, ds.rewardAsset) && sameBig(candidate.windowPool, ds.profitAttribution.windowPool)
    && sameBig(candidate.finalizedTotalPayable, ds.finalizedTotalPayable)
    && sameBig(candidate.recipientCount, ds.recipientCount)
    && sameBig(candidate.positiveEntryCount, ds.positiveRecipientCount)
    && sameBig(candidate.algorithmVersion, ds.algorithmVersion), 'candidate context mismatch');
  const now = BigInt(snapshot.blockTimestamp);
  demand(now >= BigInt(candidate.acceptedAt) + REVIEW_SECONDS && now >= BigInt(candidate.executableAfter), '30-minute on-chain review has not elapsed');
  const lifecycle = Number(snapshot.lifecycle);
  demand([0, 1, 2, 3].includes(lifecycle), 'unknown lifecycle state');
  // Existing liabilities may continue through pause/shutdown; TERMINATED still requires an
  // exact COMMITTED_UNPAID entry (checked below), before the chain classifies it for terminal handling.
  demand(!observed.terminal, 'terminal-classified liability cannot use automatic payment');
  const onchainLeafHash = snapshot.leafHash;
  demand(eq(onchainLeafHash, leaf.leafHash), 'recipient leaf not materialized on chain');
  const versionRoot = snapshot.root;
  const versionDataset = snapshot.datasetHash;
  demand(eq(versionRoot, ds.merkle.root) && eq(versionDataset, ds.datasetHash), 'version root/dataset mismatch');
  const before = snapshot.entry;
  demand(before && Number(before.version) === Number(ds.commitmentVersion) && Number(before.status) === 2
    && eq(before.recipient, entry.recipient) && sameBig(before.amount, entry.amount), 'Vault exact unpaid liability mismatch');
  const record = { state: 'PLANNED', distributionId: ds.distributionId, version: ds.commitmentVersion,
    recipientIndex: index, leafHash: leaf.leafHash, recipient: entry.recipient, amount: String(entry.amount), rewardAsset: ds.rewardAsset };
  const claimed = prior ? (await journal.put(id, record), true) : await journal.claim(id, record);
  demand(claimed !== false, 'duplicate worker/job already has a deterministic plan');
  const leafCall = Object.fromEntries(['domainSeparator', 'distributionId', 'commitmentVersion', 'windowId',
    'windowStart', 'windowEnd', 'rewardAsset', 'windowPool', 'finalizedTotalPayable', 'recipientIndex',
    'recipient', 'amount', 'datasetHash', 'algorithmVersion'].map(key => [key, leaf[key]]));
  return Object.freeze({ id, method: 'executeProof', distributionId: ds.distributionId,
    leaf: leafCall, proof: [...leaf.proof], chainId: Number(ds.chainId),
    from: AUTOMATION_EXECUTOR, broadcast: false });
}

/** Low-level planner for explicit TEST_ONLY use. PRODUCTION callers must use the boot-time service boundary. */
export async function planAutomaticPayment(args) {
  if (args?.config?.mode === 'PRODUCTION') {
    throw new Error('PRODUCTION planning is available only through the application-owned execution service');
  }
  return planAutomaticPaymentCore(args, undefined);
}

/** Optional executor bridge. This is never called by local validation; it accepts only the exact executeProof plan. */
export async function relayAutomaticPayment({ verified, entry, config, chain, journal, relay }) {
  if (config?.mode === 'PRODUCTION') {
    throw new Error('PRODUCTION relay is unavailable outside the application-owned execution boundary');
  }
  if (!relay || addressHex(relay.address, 'relay Automation address', { allowZero: false }) !== AUTOMATION_EXECUTOR
      || typeof relay.executeProof !== 'function') {
    throw new Error('a narrowly scoped relay bound to canonical AUTOMATION_EXECUTOR is required');
  }
  if (relay.mode !== config.mode || (config.mode === 'TEST_ONLY' && relay.testOnly !== true)
      || (config.mode === 'PRODUCTION' && relay.productionApproved !== true)) {
    throw new Error('relay mode must be explicit and match the candidate/configuration');
  }
  demand(verified?.dataset && Number(relay.chainId) === Number(verified.dataset.chainId), 'relay chain identity mismatch');
  const plan = await planAutomaticPayment({ verified, entry, config, chain, journal });
  const submission = await relay.executeProof({
    to: config.distributor, from: AUTOMATION_EXECUTOR, chainId: plan.chainId,
    distributionId: plan.distributionId, leaf: plan.leaf, proof: plan.proof,
  });
  if (!submission || !/^0x[0-9a-fA-F]{64}$/.test(submission.hash ?? '')) {
    // The deterministic journal entry remains PLANNED. A subsequent run must reconcile the chain intent first.
    throw new Error('relay returned no transaction hash; execution state is uncertain, reconcile before any retry');
  }
  await journal.put(plan.id, { state: 'SUBMITTED', distributionId: plan.distributionId,
    version: verified.version, recipientIndex: entry.recipientIndex, leafHash: entry.leafHash,
    recipient: entry.recipient, amount: String(entry.amount), rewardAsset: entry.rewardAsset, txHash: submission.hash });
  return Object.freeze({ id: plan.id, state: 'SUBMITTED', txHash: submission.hash, canonical: false,
    recipient: entry.recipient, amount: String(entry.amount), distributionId: plan.distributionId,
    version: verified.version, broadcast: true });
}

/** Exact failed liability only. This prepares a Settler call and cannot replace recipient/amount/asset. */
async function planManualSettlementCore({ verified, entry, config, chain }, authority) {
  if (config?.mode === 'PRODUCTION' && authority !== PRODUCTION_EXECUTION_AUTHORITY) {
    throw new Error('PRODUCTION planning is available only through the application-owned execution service');
  }
  if (!verified || verified.status !== 'VERIFIED') throw new Error('verified candidate required');
  if (config.mode === 'PRODUCTION') requireProductionConfig(config);
  else if (config.mode !== 'TEST_ONLY') throw new Error('workflow mode must be exactly TEST_ONLY or PRODUCTION');
  const ds = verified.dataset;
  if (!entry || typeof entry !== 'object' || Array.isArray(entry)
      || typeof entry.recipientIndex !== 'number' || !Number.isSafeInteger(entry.recipientIndex)) {
    throw new Error('explicit canonical recipient index required');
  }
  const index = entry.recipientIndex;
  demand(index >= 0 && index < ds.entries.length, 'recipient index out of bounds');
  const expected = ds.entries[index];
  demand(expected && expected.index === String(index) && eq(expected.address, entry.recipient), 'manual settlement recipient changed');
  demand(sameBig(expected.payout, entry.amount) && eq(ds.rewardAsset, entry.rewardAsset), 'manual liability amount/asset changed');
  demand(sameBig(ds.commitmentVersion, entry.version) && eq(ds.distributionId, entry.distributionId), 'manual distribution/version changed');
  const snapshot = await readCanonicalPaymentSnapshot({ chain, dataset: ds, index,
    version: ds.commitmentVersion, mode: config.mode });
  demand(Number(snapshot.chainId) === Number(ds.chainId), 'wrong chain');
  demand(eq(config.distributor, ds.distributor) && eq(config.vault, ds.vault), 'wrong contract binding');
  const active = snapshot.candidate;
  demand(active && sameBig(active.commitmentVersion, ds.commitmentVersion)
    && eq(active.domainSeparator, ds.domainSeparator) && eq(active.windowId, ds.windowId)
    && sameBig(active.windowStart, ds.window.start) && sameBig(active.windowEnd, ds.window.end)
    && eq(active.rewardAsset, ds.rewardAsset) && sameBig(active.windowPool, ds.profitAttribution.windowPool)
    && sameBig(active.finalizedTotalPayable, ds.finalizedTotalPayable)
    && sameBig(active.recipientCount, ds.recipientCount)
    && sameBig(active.positiveEntryCount, ds.positiveRecipientCount)
    && sameBig(active.algorithmVersion, ds.algorithmVersion)
    && eq(active.root, ds.merkle.root) && eq(active.datasetHash, ds.datasetHash)
    && [3, 4].includes(Number(active.status)), 'manual liability candidate is stale or superseded');
  const state = snapshot.paymentState;
  demand(state?.canonical === true && state.failed && state.manualAvailable && !state.paid && !state.terminal
    && Number(state.version) === Number(ds.commitmentVersion)
    && eq(state.recipient, entry.recipient) && sameBig(state.amount, entry.amount),
    'only exact canonical FAILED_PENDING_MANUAL liability may be settled');
  demand([0, 1, 2, 3].includes(Number(snapshot.lifecycle)), 'unknown lifecycle state');
  const liability = snapshot.entry;
  demand(Number(liability.version) === Number(ds.commitmentVersion) && Number(liability.status) === 3
    && liability.manualSettlementAvailable === true
    && eq(liability.recipient, entry.recipient) && sameBig(liability.amount, entry.amount), 'Vault failed liability differs');
  return Object.freeze({ method: 'settleFailedHolderEntry', distributionId: ds.distributionId,
    version: Number(ds.commitmentVersion), windowId: ds.windowId, recipientIndex: index,
    recipient: expected.address, rewardAsset: ds.rewardAsset, amount: expected.payout,
    from: config.settler, broadcast: false });
}

/** Low-level planner for explicit TEST_ONLY use. PRODUCTION callers must use the boot-time service boundary. */
export async function planManualSettlement(args) {
  if (args?.config?.mode === 'PRODUCTION') {
    throw new Error('PRODUCTION planning is available only through the application-owned execution service');
  }
  return planManualSettlementCore(args, undefined);
}

/** Receipt state can only become successful after the adapter proves canonical chain evidence. */
export async function reconcileTransaction({ chain, txHash, distributionId, version, index }) {
  if (!/^0x[0-9a-fA-F]{64}$/.test(txHash)) throw new Error('transaction hash malformed');
  const result = await chain.reconcile(txHash);
  if (!result || result.status === 'UNKNOWN' || result.receiptAvailable !== true || result.canonical !== true) {
    return { state: 'UNCERTAIN', action: 'RECONCILE_ONLY', resubmit: false };
  }
  const onchain = await chain.paymentState(distributionId, Number(version), Number(index));
  const evidence = typeof chain.paymentEvent === 'function'
    ? await chain.paymentEvent(txHash, { distributionId, version: Number(version), index: Number(index), kind: 'AUTOMATIC' }) : undefined;
  if (result.status === 'SUCCESS' && evidence?.exact === true && evidence.state === 'PAID'
      && onchain?.canonical && onchain.paid) {
    return { state: 'PAID', txHash, receiptBlock: String(result.blockNumber), confirmations: result.confirmations,
      canonical: true, resubmit: false };
  }
  // executeProof catches the failed Vault subcall, records the liability and returns normally.
  if (result.status === 'SUCCESS' && evidence?.exact === true && evidence.state === 'FAILED_PENDING_MANUAL'
      && onchain?.canonical && onchain.failed && !onchain.paid) {
    return { state: 'FAILED_PENDING_MANUAL', txHash, canonical: true, resubmit: false };
  }
  return { state: 'UNCERTAIN', action: 'RECONCILE_ONLY', resubmit: false };
}

export async function reconcileManualSettlement({ chain, txHash, distributionId, version, index, recipient, amount }) {
  if (!/^0x[0-9a-fA-F]{64}$/.test(txHash)) throw new Error('transaction hash malformed');
  const receipt = await chain.reconcile(txHash);
  if (!receipt || receipt.status !== 'SUCCESS' || receipt.receiptAvailable !== true || receipt.canonical !== true) {
    return { state: 'UNCERTAIN', resubmit: false };
  }
  const evidence = await chain.paymentEvent?.(txHash, { distributionId, version: Number(version),
    index: Number(index), kind: 'MANUAL', recipient, amount });
  const state = await chain.paymentState(distributionId, Number(version), Number(index));
  if (evidence?.exact === true && evidence.state === 'PAID_MANUALLY' && state?.canonical && state.paid) {
    return { state: 'PAID_MANUALLY', txHash, canonical: true, receiptBlock: String(receipt.blockNumber), resubmit: false };
  }
  return { state: 'UNCERTAIN', resubmit: false };
}

/** Small append-only audit store; it is operational metadata, never payout/accounting truth. */
export class MemoryAuditJournal {
  #records = new Map();
  async get(id) { return this.#records.get(id); }
  async put(id, record) {
    const old = this.#records.get(id);
    if (old && (['PAID', 'PAID_MANUALLY'].includes(old.state)
      || (old.state === 'FAILED_PENDING_MANUAL' && record.state !== 'PAID_MANUALLY'))) {
      throw new Error('terminal payment record immutable except exact manual settlement');
    }
    this.#records.set(id, Object.freeze({ ...record }));
  }
  async claim(id, record) {
    if (this.#records.has(id)) return false;
    this.#records.set(id, Object.freeze({ ...record }));
    return true;
  }
  async all() { return [...this.#records.entries()]; }
}

/** Cross-process append-only journal. Stale lock files intentionally block until operator review. */
export class FileAuditJournal {
  #path;
  constructor(path) { this.#path = path; }
  static async open(path) { const journal = new FileAuditJournal(path); await mkdir(dirname(path), { recursive: true }); return journal; }
  async #events() {
    try {
      const content = await readFile(this.#path, 'utf8');
      if (!content) return [];
      return content.split('\n').filter(Boolean).map(line => JSON.parse(line));
    } catch (error) { if (error.code === 'ENOENT') return []; throw error; }
  }
  async #withLock(work) {
    const lockPath = `${this.#path}.lock`;
    let handle;
    for (let i = 0; i < 500; i++) {
      try { handle = await open(lockPath, 'wx'); break; }
      catch (error) { if (error.code !== 'EEXIST') throw error; await new Promise(r => setTimeout(r, 10)); }
    }
    if (!handle) throw new Error('journal lock timeout; fail closed and reconcile stale lock manually');
    try { return await work(); }
    finally { await handle.close(); await unlink(lockPath); }
  }
  async get(id) {
    const events = await this.#events();
    for (let i = events.length - 1; i >= 0; i--) if (events[i].id === id) return events[i].record;
    return undefined;
  }
  async claim(id, record) {
    return this.#withLock(async () => {
      if ((await this.#events()).some(event => event.id === id)) return false;
      await appendFile(this.#path, `${JSON.stringify({ id, record: this.#safe(record), recordedAt: new Date().toISOString() })}\n`, { flag: 'a' });
      return true;
    });
  }
  async put(id, record) {
    return this.#withLock(async () => {
      const events = await this.#events();
      const prior = [...events].reverse().find(event => event.id === id)?.record;
      if (prior && (['PAID', 'PAID_MANUALLY'].includes(prior.state)
        || (prior.state === 'FAILED_PENDING_MANUAL' && record.state !== 'PAID_MANUALLY'))) {
        throw new Error('terminal payment record immutable except exact manual settlement');
      }
      await appendFile(this.#path, `${JSON.stringify({ id, record: this.#safe(record), recordedAt: new Date().toISOString() })}\n`, { flag: 'a' });
    });
  }
  #safe(record) {
    const allowed = ['state', 'distributionId', 'version', 'recipientIndex', 'leafHash', 'recipient', 'amount', 'rewardAsset',
      'txHash', 'errorCode', 'receiptBlock', 'canonical', 'event', 'windowId', 'datasetHash', 'root',
      'semanticManifestIdentity', 'acceptedAt', 'executableAfter', 'correctionReasonHash'];
    return Object.fromEntries(Object.entries(record).filter(([key]) => allowed.includes(key)));
  }
}

/** Record public audit facts only; raw candidate bundles, credentials and secrets are not accepted. */
export async function recordPhase5Observation(journal, id, observation) {
  const allowed = new Set(['state', 'distributionId', 'version', 'recipientIndex', 'leafHash', 'recipient', 'amount',
    'rewardAsset', 'txHash', 'errorCode', 'receiptBlock', 'canonical', 'event', 'windowId', 'datasetHash', 'root',
    'semanticManifestIdentity', 'acceptedAt', 'executableAfter', 'correctionReasonHash']);
  if (!journal || typeof journal.put !== 'function' || !observation || typeof observation !== 'object') {
    throw new Error('audit journal and structured public observation required');
  }
  for (const key of Object.keys(observation)) {
    if (/private|secret|seed|mnemonic|password|credential/i.test(key) || !allowed.has(key)) {
      throw new Error(`audit field ${key} is not permitted`);
    }
  }
  await journal.put(id, observation);
}

const DISTRIBUTOR_READ_ABI = [
  'function candidate(bytes32) view returns (tuple(bytes32 domainSeparator,bytes32 windowId,uint64 windowStart,uint64 windowEnd,address rewardAsset,uint256 windowPool,uint256 finalizedTotalPayable,uint16 recipientCount,uint16 positiveEntryCount,bytes32 root,bytes32 datasetHash,uint32 algorithmVersion,uint32 commitmentVersion,uint64 acceptedAt,uint64 executableAfter,uint16 verifiedLeafCount,uint16 materializedEntryCount,uint256 materializedAmount,uint8 status))',
  'function rootByVersion(bytes32,uint32) view returns (bytes32)',
  'function datasetHashByVersion(bytes32,uint32) view returns (bytes32)',
  'function materializedLeafHash(bytes32,uint32,uint16) view returns (bytes32)',
  'event AutomaticPayoutSucceeded(bytes32 indexed distributionId,uint32 indexed version,uint16 indexed recipientIndex,address recipient,uint256 amount)',
  'event AutomaticPayoutFailed(bytes32 indexed distributionId,uint32 indexed version,uint16 indexed recipientIndex,address recipient,uint256 amount,bytes32 revertDataHash)',
];
const VAULT_READ_ABI = [
  'function lifecycle() view returns (uint8)',
  'function holderRewardEntry(bytes32,uint16) view returns (tuple(address recipient,uint256 amount,uint64 terminalGraceStartAt,uint32 version,uint8 status,bool manualSettlementAvailable))',
  'event HolderPayoutSucceeded(bytes32 indexed distributionId,bytes32 indexed windowId,uint32 version,uint16 recipientIndex,address recipient,uint256 amount,bool manual)',
  'event HolderPayoutFailed(bytes32 indexed distributionId,bytes32 indexed windowId,uint32 version,uint16 recipientIndex,address recipient,uint256 amount)',
];

/** Narrow ethers v6 read adapter. It has no signer, write ABI, or broadcaster. */
export async function createReadOnlyChainAdapter({ provider, distributorAddress, vaultAddress, deploymentBlock, finality, contractFactory }) {
  if (!provider || !distributorAddress || !vaultAddress || deploymentBlock === undefined) {
    throw new Error('provider, verified contract addresses, and deployment block are required');
  }
  if (!finality || !['TEST_ONLY', 'VERIFIED'].includes(finality.status) || typeof finality.isFinalized !== 'function') {
    throw new Error('explicit test-only or externally verified finality verifier required; no confirmation value is assumed');
  }
  if (!contractFactory) ({ Contract: contractFactory } = await import('ethers'));
  const distributor = new contractFactory(distributorAddress, DISTRIBUTOR_READ_ABI, provider);
  const vault = new contractFactory(vaultAddress, VAULT_READ_ABI, provider);
  const canonicalAtTip = async () => {
    const block = await provider.getBlock('latest');
    if (!block || !Number.isSafeInteger(block.number) || block.number < 0
        || typeof block.hash !== 'string' || !/^0x[0-9a-f]{64}$/i.test(block.hash)) {
      throw new Error('canonical block identity unavailable or malformed');
    }
    const reread = await provider.getBlock(block.number);
    if (!reread || reread.number !== block.number || reread.hash?.toLowerCase() !== block.hash.toLowerCase()) {
      throw new Error('RPC block hash changed during canonical snapshot creation; retry only after fresh reconciliation');
    }
    return block;
  };
  const callAt = (contract, method, args, blockTag) => contract[method](...args, { blockTag });
  return Object.freeze({
    async chainId() { return Number((await provider.getNetwork()).chainId); },
    async blockTimestamp() { return BigInt((await canonicalAtTip()).timestamp); },
    async lifecycleState() { return Number(await vault.lifecycle()); },
    async candidate(id) { return distributor.candidate(id); },
    async rootByVersion(id, version) { return distributor.rootByVersion(id, version); },
    async datasetHashByVersion(id, version) { return distributor.datasetHashByVersion(id, version); },
    async materializedLeafHash(id, version, index) { return distributor.materializedLeafHash(id, version, index); },
    async vaultEntry(id, index) { return vault.holderRewardEntry(id, index); },
    async readPaymentSnapshot(ds, index, version) {
      const block = await canonicalAtTip(); const blockTag = block.number;
      const [network, candidate, leaf, root, datasetHash, entry, lifecycle] = await Promise.all([
        provider.getNetwork(),
        callAt(distributor, 'candidate', [ds.distributionId], blockTag),
        callAt(distributor, 'materializedLeafHash', [ds.distributionId, version, index], blockTag),
        callAt(distributor, 'rootByVersion', [ds.distributionId, version], blockTag),
        callAt(distributor, 'datasetHashByVersion', [ds.distributionId, version], blockTag),
        callAt(vault, 'holderRewardEntry', [ds.distributionId, index], blockTag),
        callAt(vault, 'lifecycle', [], blockTag),
      ]);
      // Re-read only after every block-pinned contract call has completed.
      const reread = await provider.getBlock(blockTag);
      if (!reread || reread.number !== block.number || reread.hash?.toLowerCase() !== block.hash.toLowerCase()) {
        throw new Error('canonical snapshot block hash mismatch after block-pinned reads');
      }
      const canonical = await finality.isFinalized(block.number, block.hash) === true;
      const status = Number(entry.status);
      return { distributionId: ds.distributionId, version: Number(version), index: Number(index),
        blockNumber: block.number, blockHash: block.hash, blockTimestamp: BigInt(block.timestamp),
        readsAt: { blockNumber: reread.number, blockHash: reread.hash },
        testOnly: finality.status === 'TEST_ONLY', chainId: Number(network.chainId), canonical, candidate, leafHash: leaf, root, datasetHash,
        lifecycle: Number(lifecycle), paymentState: { canonical, paid: status === 6, failed: status === 3,
          manualAvailable: Boolean(entry.manualSettlementAvailable), terminal: status === 4 || status === 5,
          version: Number(entry.version), recipient: entry.recipient, amount: entry.amount }, entry };
    },
    async paymentState(id, version, index) {
      const block = await canonicalAtTip();
      const [entry, after] = await Promise.all([vault.holderRewardEntry(id, index), provider.getBlock(block.number)]);
      if (!after || after.hash !== block.hash) return { canonical: false };
      const finalized = await finality.isFinalized(block.number, block.hash);
      const status = Number(entry.status);
      return { canonical: finalized === true,
        paid: status === 6, failed: status === 3, manualAvailable: Boolean(entry.manualSettlementAvailable),
        terminal: status === 4 || status === 5, version: Number(entry.version), recipient: entry.recipient,
        amount: entry.amount, lifecycle: Number(await vault.lifecycle()) };
    },
    async reconcile(txHash) {
      const receipt = await provider.getTransactionReceipt(txHash);
      if (!receipt) return { status: 'UNKNOWN', receiptAvailable: false, canonical: false };
      const tip = await canonicalAtTip();
      const block = await provider.getBlock(receipt.blockNumber);
      const canonical = Boolean(block && block.hash === receipt.blockHash && tip.number >= receipt.blockNumber
        && await finality.isFinalized(receipt.blockNumber, receipt.blockHash));
      return { status: Number(receipt.status) === 1 ? 'SUCCESS' : 'FAILED', receiptAvailable: true, canonical,
        blockNumber: receipt.blockNumber, confirmations: tip.number - receipt.blockNumber + 1, txHash: receipt.hash };
    },
    async reconcileIntent(id, prior) {
      // An absent event cannot prove no transaction is pending or replaced. Only matching finalized events settle intent.
      const latest = await canonicalAtTip();
      const from = Number(deploymentBlock?.blockNumber ?? deploymentBlock);
      if (!Number.isSafeInteger(from) || from < 0 || from > latest.number) return { complete: false, state: 'UNKNOWN' };
      const distId = prior.distributionId; const version = Number(prior.version);
      const recipientIndex = Number(prior.recipientIndex);
      if (!Number.isInteger(recipientIndex)) return { complete: false, state: 'UNKNOWN' };
      const [paidLogs, failedLogs] = await Promise.all([
        distributor.queryFilter(distributor.filters.AutomaticPayoutSucceeded(distId, version, recipientIndex), from, latest.number),
        distributor.queryFilter(distributor.filters.AutomaticPayoutFailed(distId, version, recipientIndex), from, latest.number),
      ]);
      const match = [...paidLogs.map(x => ({ ...x, state: 'PAID' })), ...failedLogs.map(x => ({ ...x, state: 'FAILED_PENDING_MANUAL' }))]
        .sort((a, b) => a.blockNumber - b.blockNumber || a.index - b.index).at(-1);
      if (!match) return { complete: false, state: 'UNKNOWN', reason: 'no finalized canonical matching log; absence is not proof of non-submission' };
      const args = match.args;
      if (!eq(args.recipient ?? args[3], prior.recipient)
          || !sameBig(args.amount ?? args[4], prior.amount)) return { complete: false, state: 'UNKNOWN', reason: 'event does not match deterministic exact liability' };
      const status = await this.reconcile(match.transactionHash);
      if (!status.canonical || status.status !== 'SUCCESS') return { complete: false, state: 'UNKNOWN' };
      const onchain = await this.paymentState(distId, version, recipientIndex);
      if (match.state === 'PAID' && onchain.paid) return { complete: true, state: 'PAID', txHash: match.transactionHash };
      if (match.state === 'FAILED_PENDING_MANUAL' && onchain.failed) return { complete: true, state: 'FAILED_PENDING_MANUAL', txHash: match.transactionHash };
      return { complete: false, state: 'UNKNOWN' };
    },
    async paymentEvent(txHash, expected) {
      const receipt = await provider.getTransactionReceipt(txHash);
      if (!receipt) return { exact: false, state: 'UNKNOWN' };
      const parsed = [];
      for (const log of receipt.logs ?? []) {
        try {
          if (eq(log.address, distributorAddress)) { const p = distributor.interface.parseLog(log); if (p) parsed.push({ p, source: 'DISTRIBUTOR' }); }
          if (eq(log.address, vaultAddress)) { const p = vault.interface.parseLog(log); if (p) parsed.push({ p, source: 'VAULT' }); }
        } catch { /* unrelated log topic */ }
      }
      const automaticEvent = parsed.find(({ p, source }) => source === 'DISTRIBUTOR'
        && ['AutomaticPayoutSucceeded', 'AutomaticPayoutFailed'].includes(p.name)
        && eq(p.args.distributionId ?? p.args[0], expected.distributionId)
        && sameBig(p.args.version ?? p.args[1], expected.version)
        && sameBig(p.args.recipientIndex ?? p.args[2], expected.index));
      if (expected.kind === 'AUTOMATIC') {
        if (!automaticEvent) return { exact: false, state: 'UNKNOWN' };
        const autoArgs = automaticEvent.p.args;
        const state = automaticEvent.p.name === 'AutomaticPayoutSucceeded' ? 'PAID' : 'FAILED_PENDING_MANUAL';
        const vaultName = state === 'PAID' ? 'HolderPayoutSucceeded' : 'HolderPayoutFailed';
        const settlementEvent = parsed.find(({ p, source }) => source === 'VAULT' && p.name === vaultName
          && eq(p.args.distributionId ?? p.args[0], expected.distributionId)
          && sameBig(p.args.version ?? p.args[2], expected.version)
          && sameBig(p.args.recipientIndex ?? p.args[3], expected.index)
          && (state !== 'PAID' || (p.args.manual ?? p.args[6]) === false));
        const recipient = autoArgs.recipient ?? autoArgs[3]; const amount = autoArgs.amount ?? autoArgs[4];
        const vaultRecipient = settlementEvent?.p.args.recipient ?? settlementEvent?.p.args[4];
        const vaultAmount = settlementEvent?.p.args.amount ?? settlementEvent?.p.args[5];
        return { exact: Boolean(settlementEvent && eq(recipient, vaultRecipient) && sameBig(amount, vaultAmount)), state };
      }
      const manual = parsed.find(({ p, source }) => source === 'VAULT' && p.name === 'HolderPayoutSucceeded'
        && eq(p.args.distributionId ?? p.args[0], expected.distributionId)
        && sameBig(p.args.version ?? p.args[2], expected.version)
        && sameBig(p.args.recipientIndex ?? p.args[3], expected.index)
        && (p.args.manual ?? p.args[6]) === true
        && (!expected.recipient || eq(p.args.recipient ?? p.args[4], expected.recipient))
        && (expected.amount === undefined || sameBig(p.args.amount ?? p.args[5], expected.amount)));
      return { exact: Boolean(manual), state: manual ? 'PAID_MANUALLY' : 'UNKNOWN' };
    },
  });
}

function freezeConfiguration(value) {
  if (value && typeof value === 'object' && !Object.isFrozen(value)) {
    for (const child of Object.values(value)) freezeConfiguration(child);
    Object.freeze(value);
  }
  return value;
}

function rejectPlanningAuthorityOverrides(request) {
  if (!request || typeof request !== 'object' || Array.isArray(request)) {
    throw new Error('production planning request must be an object');
  }
  for (const key of ['chain', 'adapter', 'provider', 'config', 'mode', 'finality', 'journal', 'contractFactory']) {
    if (Object.hasOwn(request, key)) throw new Error(`production planning request cannot override ${key}`);
  }
  if (!request.verified || !request.entry) throw new Error('verified candidate and exact entry are required');
}

/**
 * Application boot-time composition root. Call once from trusted process startup, never from a request
 * handler. It constructs and closes over the read-only RPC adapter, immutable production config and journal.
 * `provider` and `contractFactory` are composition dependencies, not per-plan inputs; request payloads cannot
 * replace them. For production bootstrap use createProductionExecutionServiceFromEnvironment.
 */
export async function createProductionExecutionService({
  provider, productionConfig, finality, journal, contractFactory,
} = {}) {
  if (!provider) throw new Error('NO_TRUSTED_PRODUCTION_ADAPTER: application startup must configure a provider');
  if (!productionConfig || productionConfig.mode !== 'PRODUCTION') {
    throw new Error('NO_TRUSTED_PRODUCTION_ADAPTER: verified PRODUCTION configuration is required at startup');
  }
  if (!finality || finality.status !== 'VERIFIED' || typeof finality.isFinalized !== 'function') {
    throw new Error('NO_TRUSTED_PRODUCTION_ADAPTER: verified finality boundary is required at startup');
  }
  if (!journal || typeof journal.get !== 'function' || typeof journal.claim !== 'function' || typeof journal.put !== 'function') {
    throw new Error('NO_TRUSTED_PRODUCTION_ADAPTER: application-owned durable journal is required at startup');
  }
  const config = freezeConfiguration(structuredClone(productionConfig));
  requireProductionConfig(config);
  const trustedFinality = Object.freeze({ status: finality.status, isFinalized: finality.isFinalized });
  const chain = await createReadOnlyChainAdapter({ provider,
    distributorAddress: config.distributor, vaultAddress: config.vault,
    deploymentBlock: config.deploymentBlock.blockNumber, finality: trustedFinality, contractFactory });

  return Object.freeze({
    async planAutomaticPayment(request) {
      rejectPlanningAuthorityOverrides(request);
      return planAutomaticPaymentCore({ verified: request.verified, entry: request.entry,
        config, chain, journal }, PRODUCTION_EXECUTION_AUTHORITY);
    },
    async planManualSettlement(request) {
      rejectPlanningAuthorityOverrides(request);
      return planManualSettlementCore({ verified: request.verified, entry: request.entry,
        config, chain }, PRODUCTION_EXECUTION_AUTHORITY);
    },
  });
}

/** Process-startup convenience using the established BSC_RPC_URL/BSC_CHAIN_ID environment contract. */
export async function createProductionExecutionServiceFromEnvironment({ productionConfig, finality, journal } = {}) {
  const rpcUrl = process.env.BSC_RPC_URL?.trim();
  if (!rpcUrl) throw new Error('NO_TRUSTED_PRODUCTION_ADAPTER: BSC_RPC_URL is not configured');
  let parsedUrl;
  try { parsedUrl = new URL(rpcUrl); } catch { throw new Error('BSC_RPC_URL must be an absolute HTTP(S) URL'); }
  if (!['http:', 'https:'].includes(parsedUrl.protocol)) throw new Error('BSC_RPC_URL must use HTTP(S)');
  if (process.env.BSC_CHAIN_ID !== '56') throw new Error('BSC_CHAIN_ID must be explicitly configured as 56');
  let ethers;
  try { ethers = await import('ethers'); }
  catch { throw new Error('NO_TRUSTED_PRODUCTION_ADAPTER: ethers JsonRpcProvider is unavailable'); }
  const provider = new ethers.JsonRpcProvider(rpcUrl, 56);
  return createProductionExecutionService({ provider, productionConfig, finality, journal,
    contractFactory: ethers.Contract });
}

export function finalizerCandidatePlan(verified, config) {
  if (!verified || verified.status !== 'VERIFIED') throw new Error('verified candidate required');
  if (config.mode === 'PRODUCTION') requireProductionConfig(config);
  else if (config.mode !== 'TEST_ONLY') throw new Error('workflow mode must be exactly TEST_ONLY or PRODUCTION');
  if (!config.finalizer || config.finalizerStatus !== 'TEST_ONLY') throw new Error('Finalizer unresolved; no substitution permitted');
  const finalizer = addressHex(config.finalizer, 'test Finalizer', { allowZero: false });
  if (finalizer === AUTOMATION_EXECUTOR) throw new Error('Finalizer must not substitute for canonical Automation identity');
  const d = verified.dataset;
  return Object.freeze({ method: 'submitCandidate', from: finalizer, chainId: Number(d.chainId),
    candidate: { domainSeparator: d.domainSeparator, distributionId: d.distributionId, commitmentVersion: Number(d.commitmentVersion),
      windowId: d.windowId, windowStart: Number(d.window.start), windowEnd: Number(d.window.end), rewardAsset: d.rewardAsset,
      windowPool: d.profitAttribution.windowPool, finalizedTotalPayable: d.finalizedTotalPayable,
      recipientCount: Number(d.recipientCount), positiveEntryCount: Number(d.positiveRecipientCount), root: d.merkle.root,
      datasetHash: d.datasetHash, algorithmVersion: Number(d.algorithmVersion) }, broadcast: false });
}

/** Deterministic Finalizer call sequence. Each item remains an unsigned plan; no call is sent. */
export function finalizerWorkflowPlans(verified, config) {
  const submit = finalizerCandidatePlan(verified, config);
  const d = verified.dataset;
  const materialize = d.merkle.leaves.map((leaf, index) => Object.freeze({
    method: 'materializeLeaf', from: submit.from, chainId: submit.chainId, distributionId: d.distributionId,
    leaf: Object.fromEntries(['domainSeparator', 'distributionId', 'commitmentVersion', 'windowId', 'windowStart',
      'windowEnd', 'rewardAsset', 'windowPool', 'finalizedTotalPayable', 'recipientIndex', 'recipient', 'amount',
      'datasetHash', 'algorithmVersion'].map(key => [key, leaf[key]])),
    proof: [...leaf.proof], index, broadcast: false,
  }));
  return Object.freeze([submit, ...materialize, Object.freeze({ method: 'finalizeCandidate', from: submit.from,
    chainId: submit.chainId, distributionId: d.distributionId, broadcast: false })]);
}

/** Correction changes only root/version-specific fields. Immutable domain/window/pool/asset identity must match. */
export function correctionCandidatePlan(verified, config, active, reasonHash) {
  const initial = finalizerCandidatePlan(verified, config);
  const d = verified.dataset;
  demand(eq(active.distributionId, d.distributionId) && eq(active.windowId, d.windowId), 'correction cannot change distribution/window');
  demand(eq(active.rewardAsset, d.rewardAsset) && sameBig(active.windowPool, d.profitAttribution.windowPool), 'correction cannot change asset/pool');
  demand(BigInt(d.commitmentVersion) === BigInt(active.commitmentVersion) + 1n, 'correction must use exactly next version');
  bytes32Hex(reasonHash, 'correction reason hash');
  demand(!/^0x0{64}$/i.test(reasonHash), 'correction reason hash cannot be zero');
  return Object.freeze({ method: 'correctCandidate', from: initial.from, chainId: initial.chainId,
    distributionId: d.distributionId, replacement: { commitmentVersion: Number(d.commitmentVersion),
      recipientCount: Number(d.recipientCount), positiveEntryCount: Number(d.positiveRecipientCount),
      root: d.merkle.root, datasetHash: d.datasetHash, algorithmVersion: Number(d.algorithmVersion),
      correctionReasonHash: reasonHash }, broadcast: false });
}

export function correctionWorkflowPlans(verified, config, active, reasonHash) {
  const correction = correctionCandidatePlan(verified, config, active, reasonHash);
  const followup = finalizerWorkflowPlans(verified, config).slice(1);
  return Object.freeze([correction, ...followup]);
}
