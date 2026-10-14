import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { verifyInputBundle } from '../src/core.mjs';
import {
  FileAuditJournal, MemoryAuditJournal, correctionCandidatePlan, correctionWorkflowPlans, createPhase5Candidate, finalizerCandidatePlan, finalizerWorkflowPlans, planAutomaticPayment,
  createReadOnlyChainAdapter, createProductionExecutionService, createProductionExecutionServiceFromEnvironment,
  planManualSettlement, reconcileManualSettlement, reconcileTransaction, relayAutomaticPayment, requireProductionConfig, semanticManifestIdentity,
  transitionPhase5, verifyCanonicalCandidate, recordPhase5Observation,
} from '../src/phase5.mjs';

const fixture = new URL('../fixtures/half-window-transfer.json', import.meta.url);
const loadInput = async () => JSON.parse(await (await import('node:fs/promises')).readFile(fixture, 'utf8'));
const clone = value => structuredClone(value);

function setup({ now = 2_800n, payment = {}, vaultStatus = 2, candidateStatus = 3, version = 1 } = {}) {
  const input = JSON.parse(JSON.stringify(globalThis.__phase5Input));
  input.window.commitmentVersion = String(version);
  const result = verifyInputBundle(input);
  const envelope = createPhase5Candidate(input);
  const verified = verifyCanonicalCandidate(input, envelope);
  const d = result.dataset;
  const i = d.entries.findIndex(x => BigInt(x.payout) > 0n);
  const l = d.merkle.leaves[i];
  const entry = { recipientIndex: i, recipient: d.entries[i].address, amount: d.entries[i].payout,
    rewardAsset: d.rewardAsset, distributionId: d.distributionId, version: d.commitmentVersion,
    leafHash: l.leafHash, proof: l.proof };
  let chainState = { ...payment };
  const chain = {
    async chainId() { return 56; },
    async blockTimestamp() { return now; },
    async lifecycleState() { return 1; },
    async candidate() { return { status: candidateStatus, commitmentVersion: d.commitmentVersion,
      domainSeparator: d.domainSeparator, windowId: d.windowId,
      root: d.merkle.root, datasetHash: d.datasetHash, windowStart: d.window.start, windowEnd: d.window.end,
      rewardAsset: d.rewardAsset, windowPool: d.profitAttribution.windowPool,
      finalizedTotalPayable: d.finalizedTotalPayable, recipientCount: d.recipientCount,
      positiveEntryCount: d.positiveRecipientCount, algorithmVersion: d.algorithmVersion,
      acceptedAt: '1000', executableAfter: '2800' }; },
    async materializedLeafHash() { return l.leafHash; },
    async rootByVersion() { return d.merkle.root; },
    async datasetHashByVersion() { return d.datasetHash; },
    async vaultEntry() { return { version: Number(d.commitmentVersion), status: vaultStatus,
      recipient: d.entries[i].address, amount: d.entries[i].payout, manualSettlementAvailable: Boolean(chainState.manualAvailable) }; },
    async paymentState() { return { canonical: true, paid: false, failed: false, manualAvailable: false, terminal: false, ...chainState }; },
    async readPaymentSnapshot(dataset, index, requestedVersion) {
      const [candidate, leafHash, root, datasetHash, entry, lifecycle, state, chainId] = await Promise.all([
        chain.candidate(dataset.distributionId), chain.materializedLeafHash(dataset.distributionId, requestedVersion, index),
        chain.rootByVersion(dataset.distributionId, requestedVersion), chain.datasetHashByVersion(dataset.distributionId, requestedVersion),
        chain.vaultEntry(dataset.distributionId, index), chain.lifecycleState(), chain.paymentState(dataset.distributionId, requestedVersion, index), chain.chainId(),
      ]);
      return { distributionId: dataset.distributionId, version: requestedVersion, index, blockNumber: 123,
        blockHash: `0x${'1'.repeat(64)}`, readsAt: { blockNumber: 123, blockHash: `0x${'1'.repeat(64)}` },
        canonical: true, testOnly: true, blockTimestamp: now, chainId, candidate, leafHash, root, datasetHash, entry, lifecycle,
        paymentState: { ...state, version: Number(entry.version), recipient: entry.recipient, amount: entry.amount } };
    },
    async reconcileIntent() { return { complete: true, state: 'NOT_SUBMITTED' }; },
    async reconcile() { return { status: 'UNKNOWN', receiptAvailable: false, canonical: false }; },
  };
  return { input, result, verified, entry, chain, d };
}

function strictSnapshotChain(f, requestedEntry = f.entry, mutate = snapshot => snapshot) {
  let calls = 0;
  const chain = { ...f.chain, async readPaymentSnapshot(dataset, index, version) {
    calls++;
    assert.equal(dataset.distributionId, f.d.distributionId);
    assert.equal(index, requestedEntry.recipientIndex);
    assert.equal(version, Number(f.d.commitmentVersion));
    const row = dataset.entries[index]; const leaf = dataset.merkle.leaves[index];
    const entry = { version: Number(version), status: 2, recipient: row.address, amount: row.payout };
    return mutate({ distributionId: dataset.distributionId, version: Number(version), index,
      canonical: true, testOnly: true, blockNumber: 123, blockHash: `0x${'1'.repeat(64)}`,
      readsAt: { blockNumber: 123, blockHash: `0x${'1'.repeat(64)}` }, blockTimestamp: 2800n,
      chainId: Number(dataset.chainId), lifecycle: 1, candidate: await f.chain.candidate(),
      leafHash: leaf.leafHash, root: dataset.merkle.root, datasetHash: dataset.datasetHash,
      paymentState: { canonical: true, paid: false, failed: false, manualAvailable: false, terminal: false,
        version: Number(version), recipient: row.address, amount: row.payout }, entry });
  } };
  return { chain, calls: () => calls };
}

function strictManualSnapshotChain(f, mutate = snapshot => snapshot) {
  return strictSnapshotChain(f, f.entry, snapshot => mutate({ ...snapshot, testOnly: true,
    paymentState: { ...snapshot.paymentState, failed: true, manualAvailable: true },
    entry: { ...snapshot.entry, status: 3, manualSettlementAvailable: true } }));
}

function productionRpcFixture(f, { manual = false, blockSequence } = {}) {
  const block = { number: 123, hash: `0x${'1'.repeat(64)}`, timestamp: 2800 };
  const calls = [];
  class ReadContract {
    constructor(address) {
      this.address = address;
      this.candidate = async (...args) => { calls.push({ address, method: 'candidate', args }); return f.chain.candidate(); };
      this.materializedLeafHash = async (...args) => { calls.push({ address, method: 'materializedLeafHash', args }); return f.d.merkle.leaves[f.entry.recipientIndex].leafHash; };
      this.rootByVersion = async (...args) => { calls.push({ address, method: 'rootByVersion', args }); return f.d.merkle.root; };
      this.datasetHashByVersion = async (...args) => { calls.push({ address, method: 'datasetHashByVersion', args }); return f.d.datasetHash; };
      this.holderRewardEntry = async (...args) => { calls.push({ address, method: 'holderRewardEntry', args });
        return { ...await f.chain.vaultEntry(), status: manual ? 3 : 2, manualSettlementAvailable: manual }; };
      this.lifecycle = async (...args) => { calls.push({ address, method: 'lifecycle', args }); return 1; };
    }
  }
  let blockRead = 0;
  const provider = { async getNetwork() { return { chainId: 56n }; }, async getBlock() {
    const item = blockSequence?.[blockRead++] ?? block; return item;
  } };
  const finality = { status: 'VERIFIED', async isFinalized() { return true; } };
  return { block, calls, provider, finality, contractFactory: ReadContract };
}

async function productionService(f, options = {}) {
  const rpc = productionRpcFixture(f, options);
  const service = await createProductionExecutionService({ provider: rpc.provider,
    productionConfig: productionTestConfig(), finality: rpc.finality,
    journal: new MemoryAuditJournal(), contractFactory: rpc.contractFactory });
  return { ...rpc, service };
}
const testConfig = ({ mode = 'TEST_ONLY' } = {}) => ({ mode, chainId: 56, vault: '0x0000000000000000000000000000000000000022',
  distributor: '0x0000000000000000000000000000000000000033', finalizer: '0x0000000000000000000000000000000000000044',
  settler: '0x0000000000000000000000000000000000000055', finalizerStatus: 'TEST_ONLY' });
const productionTestConfig = () => ({ ...testConfig({ mode: 'PRODUCTION' }), automationExecutor: '0xb878884a07fc84e6a1336e15ca8c6580cd7164c3',
  activation: { status: 'VERIFIED', blockHash: `0x${'1'.repeat(64)}`, blockNumber: 100, timestamp: 1000 },
  finality: { status: 'VERIFIED', reference: 'synthetic-test-finality' },
  sourceAdapter: { status: 'VERIFIED', reference: 'synthetic-test-adapter' },
  deploymentBlock: { status: 'VERIFIED', blockNumber: 1 },
  flapAttribution: { status: 'VERIFIED', reference: 'synthetic-test-attribution' },
  otherRoleAddresses: ['0x0000000000000000000000000000000000000066'] });

test.before(async () => { globalThis.__phase5Input = await loadInput(); });
test.after(() => { delete globalThis.__phase5Input; });

test('A: accepts complete independently replayed Phase 4 candidate and manifest', async () => {
  const { verified, result } = setup();
  assert.equal(verified.status, 'VERIFIED');
  assert.equal(verified.datasetHash, result.dataset.datasetHash);
  assert.equal(verified.root, result.dataset.merkle.root);
});

for (const field of ['datasetHash', 'root', 'distributionId', 'windowId', 'commitmentVersion', 'rewardAsset',
  'finalizedTotalPayable', 'recipientCount', 'totalEligibleTop30Weight', 'algorithmVersion', 'schemaVersion', 'windowStart', 'checkpoint']) {
  test(`B-I: rejects mutated candidate ${field}`, async () => {
    const { input, result } = setup(); const candidate = clone(result.dataset);
    if (field === 'root') candidate.merkle.root = `0x${'f'.repeat(64)}`;
    else if (field === 'rewardAsset') candidate[field] = '0x0000000000000000000000000000000000000042';
    else if (field === 'totalEligibleTop30Weight') candidate[field] = '0';
    else if (field === 'windowStart') candidate.window.start = '1';
    else if (field === 'checkpoint') candidate.replay.checkpointBlockHash = `0x${'f'.repeat(64)}`;
    else candidate[field] = typeof candidate[field] === 'string' ? `${candidate[field]}x` : 'mutated';
    assert.throws(() => verifyCanonicalCandidate(input, candidate, createPhase5Candidate(input).manifest), /differs from independent Phase 4 replay/);
  });
}

test('J/K: unresolved production config fails closed and test Finalizer is conspicuously test-only', async () => {
  const { verified } = setup();
  assert.throws(() => requireProductionConfig({ mode: 'PRODUCTION' }), /unresolved/);
  assert.throws(() => finalizerCandidatePlan(verified, { mode: 'PRODUCTION' }), /unresolved/);
  const plan = finalizerCandidatePlan(verified, testConfig());
  assert.equal(plan.broadcast, false);
  assert.equal(plan.from, testConfig().finalizer);
  assert.throws(() => finalizerCandidatePlan(verified, { ...testConfig(), finalizer: '0xb878884a07fc84e6a1336e15ca8c6580cd7164c3' }), /must not substitute/);
  const workflow = finalizerWorkflowPlans(verified, testConfig());
  assert.equal(workflow[0].method, 'submitCandidate');
  assert.equal(workflow.at(-1).method, 'finalizeCandidate');
  assert.ok(workflow.slice(1, -1).every(x => x.method === 'materializeLeaf' && x.broadcast === false));
  const nextInput = clone(globalThis.__phase5Input); nextInput.window.commitmentVersion = '2';
  const nextResult = verifyInputBundle(nextInput); const next = verifyCanonicalCandidate(nextInput, createPhase5Candidate(nextInput));
  const active = { distributionId: verified.distributionId, windowId: verified.windowId, commitmentVersion: 1,
    rewardAsset: verified.rewardAsset, windowPool: verified.pool };
  assert.equal(correctionCandidatePlan(next, testConfig(), active, `0x${'a'.repeat(64)}`).method, 'correctCandidate');
  assert.equal(correctionWorkflowPlans(next, testConfig(), active, `0x${'a'.repeat(64)}`).at(-1).method, 'finalizeCandidate');
  assert.throws(() => correctionCandidatePlan(next, testConfig(), { ...active, commitmentVersion: 3 }, `0x${'a'.repeat(64)}`), /exactly next version/);
});

test('manifest identity normalizes only casing and balance-list ordering without changing Phase 4 consensus output', async () => {
  const inputA = await loadInput(); const inputB = clone(inputA);
  inputB.config.compdToken = `0x${inputB.config.compdToken.slice(2).toUpperCase()}`;
  inputB.replay.initialState.balances.reverse(); inputB.checkpoint.balances.reverse();
  const a = verifyInputBundle(inputA); const b = verifyInputBundle(inputB);
  assert.equal(a.datasetBytes, b.datasetBytes);
  assert.equal(semanticManifestIdentity(inputA, a), semanticManifestIdentity(inputB, b));
  const envelopeB = createPhase5Candidate(inputB);
  assert.equal(verifyCanonicalCandidate(inputA, envelopeB).status, 'VERIFIED');
  assert.throws(() => verifyCanonicalCandidate(inputA, envelopeB.dataset), /manifest is required/);
  const badManifest = clone(envelopeB); badManifest.manifest.semanticIdentity = `0x${'f'.repeat(64)}`;
  assert.throws(() => verifyCanonicalCandidate(inputB, badManifest), /manifest identity mismatch/);
  inputB.replay.transferEvents[0].transactionHash = `0x${'b'.repeat(64)}`;
  assert.notEqual(semanticManifestIdentity(inputA, a), semanticManifestIdentity(inputB, verifyInputBundle(inputB)));
});

test('L: review is enforced from canonical acceptedAt: one second before fails, exact boundary passes', async () => {
  const before = setup({ now: 2_799n });
  await assert.rejects(planAutomaticPayment({ ...before, config: testConfig(), journal: new MemoryAuditJournal() }), /review has not elapsed/);
  const exact = setup({ now: 2_800n });
  const plan = await planAutomaticPayment({ ...exact, config: testConfig(), journal: new MemoryAuditJournal() });
  assert.equal(plan.broadcast, false); assert.equal(plan.method, 'executeProof');
  const after = setup({ now: 2_801n });
  assert.equal((await planAutomaticPayment({ ...after, config: testConfig(), journal: new MemoryAuditJournal() })).method, 'executeProof');
});

test('snapshot preflight regression: strict adapter receives the canonical payment identity', async () => {
  const f = setup();
  const snapshot = strictSnapshotChain(f);
  const plan = await planAutomaticPayment({ ...f, chain: snapshot.chain, config: testConfig(), journal: new MemoryAuditJournal() });
  assert.equal(plan.method, 'executeProof');
  assert.equal(plan.leaf.recipientIndex, String(f.entry.recipientIndex));
  assert.equal(snapshot.calls(), 1);
});

test('remediation #2 regression: production preflight rejects a chain adapter without a snapshot', async () => {
  const f = setup();
  const chain = { ...f.chain, readPaymentSnapshot: undefined };
  await assert.rejects(planAutomaticPayment({ ...f, chain, config: productionTestConfig(), journal: new MemoryAuditJournal() }), /application-owned execution service/);
});

test('production preflight rejects direct planner injection before synthetic TEST_ONLY snapshots', async () => {
  const f = setup();
  await assert.rejects(planAutomaticPayment({ ...f, config: productionTestConfig(), journal: new MemoryAuditJournal() }), /application-owned execution service/);
});

test('production preflight requires an explicit non-test adapter mode marker', async () => {
  const f = setup(); const snapshot = strictSnapshotChain(f, f.entry, s => { const { testOnly, ...rest } = s; return rest; });
  await assert.rejects(planAutomaticPayment({ ...f, chain: snapshot.chain, config: productionTestConfig(), journal: new MemoryAuditJournal() }), /application-owned execution service/);
});

test('remediation #4: synthetic chain plus PRODUCTION is rejected before any supplied chain read', async () => {
  const f = setup(); let reads = 0;
  const synthetic = { ...f.chain, async readPaymentSnapshot() { reads++; return {}; } };
  await assert.rejects(planAutomaticPayment({ ...f, chain: synthetic, config: productionTestConfig(), journal: new MemoryAuditJournal() }), /application-owned execution service/);
  await assert.rejects(planManualSettlement({ ...f, chain: synthetic, config: productionTestConfig() }), /application-owned execution service/);
  assert.equal(reads, 0);
});

test('remediation #4: absent production startup authority fails closed without a fallback', async () => {
  await assert.rejects(createProductionExecutionService({}), /NO_TRUSTED_PRODUCTION_ADAPTER/);
  await assert.rejects(createProductionExecutionService({ provider: {}, productionConfig: testConfig(),
    finality: { status: 'VERIFIED', async isFinalized() { return true; } }, journal: new MemoryAuditJournal() }), /NO_TRUSTED_PRODUCTION_ADAPTER/);
});

test('remediation #4: application-owned automatic plan uses its RPC adapter and mandatory block snapshot', async () => {
  const f = setup(); const { service, calls } = await productionService(f);
  const plan = await service.planAutomaticPayment({ verified: f.verified, entry: f.entry });
  assert.equal(plan.method, 'executeProof'); assert.equal(plan.broadcast, false);
  const reads = calls.filter(call => ['candidate', 'materializedLeafHash', 'rootByVersion', 'datasetHashByVersion', 'holderRewardEntry', 'lifecycle'].includes(call.method));
  assert.equal(reads.length, 6); assert.ok(reads.every(call => call.args.at(-1).blockTag === 123));
});

test('remediation #4: application-owned manual plan preserves exact failed-liability state', async () => {
  const f = setup({ payment: { failed: true, manualAvailable: true }, vaultStatus: 3 });
  const { service } = await productionService(f, { manual: true });
  const plan = await service.planManualSettlement({ verified: f.verified, entry: f.entry });
  assert.equal(plan.method, 'settleFailedHolderEntry'); assert.equal(plan.broadcast, false);
  assert.equal(plan.recipient, f.entry.recipient); assert.equal(plan.amount, f.entry.amount);
});

test('remediation #4: planning payload cannot replace chain, provider, configuration, finality, or journal', async () => {
  const f = setup(); const { service } = await productionService(f);
  for (const key of ['chain', 'adapter', 'provider', 'config', 'mode', 'finality', 'journal', 'contractFactory']) {
    await assert.rejects(service.planAutomaticPayment({ verified: f.verified, entry: f.entry, [key]: {} }), new RegExp(`cannot override ${key}`));
  }
});

test('remediation #4: caller-supplied synthetic block identity and historical state cannot establish authority', async () => {
  const f = setup(); const synthetic = { ...f.chain, async readPaymentSnapshot() { return {
    canonical: true, testOnly: false, blockNumber: 123, blockHash: `0x${'1'.repeat(64)}`,
    readsAt: { blockNumber: 123, blockHash: `0x${'1'.repeat(64)}` }, candidate: await f.chain.candidate(),
  }; } };
  await assert.rejects(planAutomaticPayment({ ...f, chain: synthetic, config: productionTestConfig(), journal: new MemoryAuditJournal() }), /application-owned execution service/);
});

test('remediation #4: production service rejects RPC block hash changes around pinned historical reads', async () => {
  const f = setup(); const blocks = [
    { number: 123, hash: `0x${'1'.repeat(64)}`, timestamp: 2800 },
    { number: 123, hash: `0x${'2'.repeat(64)}`, timestamp: 2800 },
  ];
  const { service } = await productionService(f, { blockSequence: blocks });
  await assert.rejects(service.planAutomaticPayment({ verified: f.verified, entry: f.entry }), /block hash changed|hash mismatch/);
});

test('remediation #4: production planning service exposes no relay and direct production relay is unavailable', async () => {
  const f = setup(); const { service } = await productionService(f);
  assert.equal(Object.hasOwn(service, 'relayAutomaticPayment'), false);
  await assert.rejects(relayAutomaticPayment({ verified: f.verified, entry: f.entry, config: productionTestConfig(),
    chain: f.chain, journal: new MemoryAuditJournal(), relay: { address: '0xb878884a07fc84e6a1336e15ca8c6580cd7164c3', executeProof() {} } }), /unavailable outside the application-owned execution boundary/);
});

test('remediation #4: production configuration is copied at startup and cannot be changed through its source object', async () => {
  const f = setup(); const rpc = productionRpcFixture(f); const config = productionTestConfig();
  const service = await createProductionExecutionService({ provider: rpc.provider, productionConfig: config,
    finality: rpc.finality, journal: new MemoryAuditJournal(), contractFactory: rpc.contractFactory });
  config.distributor = '0x0000000000000000000000000000000000000001';
  const plan = await service.planAutomaticPayment({ verified: f.verified, entry: f.entry });
  assert.equal(plan.method, 'executeProof');
  await assert.rejects(service.planAutomaticPayment({ verified: f.verified, entry: f.entry, config }), /cannot override config/);
});

test('remediation #4: environment bootstrap fails closed when BSC RPC configuration is absent', async () => {
  const oldUrl = process.env.BSC_RPC_URL; const oldChain = process.env.BSC_CHAIN_ID;
  try {
    delete process.env.BSC_RPC_URL; process.env.BSC_CHAIN_ID = '56';
    await assert.rejects(createProductionExecutionServiceFromEnvironment({ productionConfig: productionTestConfig(),
      finality: { status: 'VERIFIED', async isFinalized() { return true; } }, journal: new MemoryAuditJournal() }), /NO_TRUSTED_PRODUCTION_ADAPTER: BSC_RPC_URL is not configured/);
  } finally {
    if (oldUrl === undefined) delete process.env.BSC_RPC_URL; else process.env.BSC_RPC_URL = oldUrl;
    if (oldChain === undefined) delete process.env.BSC_CHAIN_ID; else process.env.BSC_CHAIN_ID = oldChain;
  }
});

test('snapshot identity requires valid block number, block hash, and matching read anchor', async () => {
  const invalid = [
    ['missing block number', s => { const { blockNumber, ...rest } = s; return rest; }, /blockNumber/],
    ['malformed block number', s => ({ ...s, blockNumber: 1.5 }), /blockNumber/],
    ['negative block number', s => ({ ...s, blockNumber: -1 }), /blockNumber/],
    ['missing block hash', s => { const { blockHash, ...rest } = s; return rest; }, /blockHash/],
    ['malformed block hash', s => ({ ...s, blockHash: '0x1234' }), /blockHash/],
    ['read number mismatch', s => ({ ...s, readsAt: { ...s.readsAt, blockNumber: 124 } }), /not anchored/],
    ['read hash mismatch', s => ({ ...s, readsAt: { ...s.readsAt, blockHash: `0x${'2'.repeat(64)}` } }), /not anchored/],
    ['noncanonical snapshot', s => ({ ...s, canonical: false }), /not canonical/],
  ];
  for (const [label, mutate, error] of invalid) {
    const f = setup(); const snapshot = strictSnapshotChain(f, f.entry, mutate);
    await assert.rejects(planAutomaticPayment({ ...f, chain: snapshot.chain, config: testConfig(), journal: new MemoryAuditJournal() }), error, label);
  }
});

test('snapshot must match exact payment distribution/version and cannot authorize a substituted payment', async () => {
  const changes = [
    s => ({ ...s, distributionId: `0x${'f'.repeat(64)}` }),
    s => ({ ...s, version: s.version + 1 }),
    s => ({ ...s, entry: { ...s.entry, amount: String(BigInt(s.entry.amount) + 1n) } }),
    s => ({ ...s, entry: { ...s.entry, recipient: '0x00000000000000000000000000000000000000ff' } }),
  ];
  for (const mutate of changes) {
    const f = setup(); const snapshot = strictSnapshotChain(f, f.entry, mutate);
    await assert.rejects(planAutomaticPayment({ ...f, chain: snapshot.chain, config: testConfig(), journal: new MemoryAuditJournal() }));
  }
});

test('snapshot with unavailable canonical block identity fails closed without stale-state fallback', async () => {
  const f = setup(); const snapshot = strictSnapshotChain(f, f.entry, s => ({ ...s, canonical: false }));
  await assert.rejects(planAutomaticPayment({ ...f, chain: snapshot.chain, config: testConfig(), journal: new MemoryAuditJournal() }), /not canonical/);
});

test('payment preflight does not use unanchored per-method fallback reads', async () => {
  const f = setup(); const snapshot = strictSnapshotChain(f);
  const chain = { ...snapshot.chain };
  for (const method of ['chainId', 'blockTimestamp', 'lifecycleState', 'candidate', 'materializedLeafHash',
    'rootByVersion', 'datasetHashByVersion', 'vaultEntry', 'paymentState']) {
    chain[method] = async () => { throw new Error(`unanchored fallback used: ${method}`); };
  }
  const plan = await planAutomaticPayment({ ...f, chain, config: testConfig(), journal: new MemoryAuditJournal() });
  assert.equal(plan.method, 'executeProof');
});

test('snapshot preflight rejects independently changed payment index before reading the adapter', async () => {
  const f = setup(); const journal = new MemoryAuditJournal(); const snapshot = strictSnapshotChain(f);
  await assert.rejects(planAutomaticPayment({ ...f, entry: { ...f.entry, recipientIndex: f.entry.recipientIndex + 1 },
    chain: snapshot.chain, config: testConfig(), journal }), /recipient\/index/);
  assert.equal(snapshot.calls(), 0);
  assert.equal((await journal.all()).length, 0);
});

test('snapshot preflight rejects a snapshot entry for a different recipient', async () => {
  const f = setup(); const snapshot = strictSnapshotChain(f, f.entry, s => ({ ...s,
    entry: { ...s.entry, recipient: '0x00000000000000000000000000000000000000ff' } }));
  await assert.rejects(planAutomaticPayment({ ...f, chain: snapshot.chain, config: testConfig(), journal: new MemoryAuditJournal() }), /Vault exact unpaid liability/);
});

test('snapshot preflight rejects stale distribution version', async () => {
  const f = setup(); const snapshot = strictSnapshotChain(f, f.entry, s => ({ ...s,
    candidate: { ...s.candidate, commitmentVersion: Number(s.candidate.commitmentVersion) + 1 } }));
  await assert.rejects(planAutomaticPayment({ ...f, chain: snapshot.chain, config: testConfig(), journal: new MemoryAuditJournal() }), /stale\/superseded/);
});

test('snapshot preflight rejects a superseded or non-executable candidate', async () => {
  const f = setup(); const snapshot = strictSnapshotChain(f, f.entry, s => ({ ...s,
    candidate: { ...s.candidate, status: 2 } }));
  await assert.rejects(planAutomaticPayment({ ...f, chain: snapshot.chain, config: testConfig(), journal: new MemoryAuditJournal() }), /not EXECUTABLE/);
});

test('snapshot preflight rejects an already-paid liability', async () => {
  const f = setup(); const snapshot = strictSnapshotChain(f, f.entry, s => ({ ...s,
    paymentState: { ...s.paymentState, paid: true } }));
  await assert.rejects(planAutomaticPayment({ ...f, chain: snapshot.chain, config: testConfig(), journal: new MemoryAuditJournal() }), /already paid/);
});

test('snapshot preflight rejects confirmed FAILED_PENDING_MANUAL liability', async () => {
  const f = setup(); const snapshot = strictSnapshotChain(f, f.entry, s => ({ ...s,
    paymentState: { ...s.paymentState, failed: true, manualAvailable: true } }));
  await assert.rejects(planAutomaticPayment({ ...f, chain: snapshot.chain, config: testConfig(), journal: new MemoryAuditJournal() }), /already paid/);
});

test('snapshot preflight rejects missing or malformed canonical index without defaulting', async () => {
  const f = setup(); const snapshot = strictSnapshotChain(f);
  for (const value of [undefined, null, '0', NaN, 0.5]) {
    const entry = { ...f.entry, recipientIndex: value };
    await assert.rejects(planAutomaticPayment({ ...f, entry, chain: snapshot.chain, config: testConfig(), journal: new MemoryAuditJournal() }), /explicit canonical recipient index/);
  }
  assert.equal(snapshot.calls(), 0);
});

test('snapshot adapter error stops preflight before journal claim or relay action', async () => {
  const f = setup(); const journal = new MemoryAuditJournal(); let relayCalls = 0;
  const chain = { ...f.chain, async readPaymentSnapshot() { throw new Error('snapshot RPC unavailable'); } };
  await assert.rejects(relayAutomaticPayment({ ...f, chain, config: testConfig(), journal,
    relay: { address: '0xb878884a07fc84e6a1336e15ca8c6580cd7164c3', chainId: 56, mode: 'TEST_ONLY', testOnly: true,
      async executeProof() { relayCalls++; return { hash: `0x${'a'.repeat(64)}` }; } } }), /snapshot RPC unavailable/);
  assert.equal(relayCalls, 0);
  assert.equal((await journal.all()).length, 0);
});

test('snapshot preflight rejects candidate window, asset, pool, payout, or algorithm mismatch', async () => {
  const fields = [
    ['windowId', `0x${'f'.repeat(64)}`], ['rewardAsset', '0x0000000000000000000000000000000000000042'],
    ['windowPool', '101'], ['finalizedTotalPayable', '101'], ['algorithmVersion', 9],
  ];
  for (const [field, value] of fields) {
    const f = setup(); const snapshot = strictSnapshotChain(f, f.entry, s => ({ ...s,
      candidate: { ...s.candidate, [field]: value } }));
    await assert.rejects(planAutomaticPayment({ ...f, chain: snapshot.chain, config: testConfig(), journal: new MemoryAuditJournal() }), /candidate context|stale\/superseded/);
  }
});

test('snapshot identity must match the planned payment and cannot be reused cross-index', async () => {
  const f = setup(); const snapshot = strictSnapshotChain(f, f.entry, s => ({ ...s, index: s.index + 1 }));
  await assert.rejects(planAutomaticPayment({ ...f, chain: snapshot.chain, config: testConfig(), journal: new MemoryAuditJournal() }), /snapshot identity/);
});

test('M/N: corrected candidate requires sequential version and a fresh full review', () => {
  assert.equal(transitionPhase5('REVIEW_PENDING', 'CORRECTED', { oldVersion: 1, newVersion: 2,
    acceptedAt: 9000, executableAfter: 10800, canonical: true }), 'REVIEW_PENDING');
  assert.throws(() => transitionPhase5('REVIEW_PENDING', 'CORRECTED', { oldVersion: 1, newVersion: 3,
    acceptedAt: 9000, executableAfter: 10800, canonical: true }), /increase exactly once/);
  assert.throws(() => transitionPhase5('REVIEW_PENDING', 'REVIEW_ELAPSED', { blockTimestamp: 10799,
    executableAfter: 10800, canonical: true }), /review has not elapsed/);
  assert.equal(transitionPhase5('REVIEW_PENDING', 'REVIEW_ELAPSED', { blockTimestamp: 10800,
    executableAfter: 10800, canonical: true }), 'EXECUTABLE');
  assert.throws(() => transitionPhase5('SUPERSEDED', 'EXECUTING'), /invalid Phase 5 transition/);
});

test('O: superseded version/root cannot execute', async () => {
  const stale = setup({ version: 1 }); stale.chain.candidate = async () => ({ status: 3, commitmentVersion: 2,
    root: `0x${'f'.repeat(64)}`, datasetHash: stale.d.datasetHash, windowStart: stale.d.window.start,
    windowEnd: stale.d.window.end, rewardAsset: stale.d.rewardAsset, windowPool: stale.d.profitAttribution.windowPool,
    acceptedAt: '1000', executableAfter: '2800' });
  await assert.rejects(planAutomaticPayment({ ...stale, config: testConfig(), journal: new MemoryAuditJournal() }), /stale\/superseded/);
});

test('P: exact automatic payout plan is read-only and bound to automation identity', async () => {
  const f = setup(); const plan = await planAutomaticPayment({ ...f, config: testConfig(), journal: new MemoryAuditJournal() });
  assert.equal(plan.from, '0xb878884a07fc84e6a1336e15ca8c6580cd7164c3');
  assert.equal(plan.broadcast, false); assert.equal(plan.leaf.recipient, f.entry.recipient);
});

test('Automation relay accepts only exact typed proof call and records submitted, never paid', async () => {
  const f = setup(); const journal = new MemoryAuditJournal(); const calls = [];
  const result = await relayAutomaticPayment({ ...f, config: testConfig(), journal,
    relay: { address: '0xb878884a07fc84e6a1336e15ca8c6580cd7164c3', chainId: 56, mode: 'TEST_ONLY', testOnly: true,
      async executeProof(call) { calls.push(call); return { hash: `0x${'e'.repeat(64)}` }; } },
  });
  assert.equal(calls.length, 1); assert.equal(calls[0].to, f.d.distributor);
  assert.equal(result.state, 'SUBMITTED'); assert.equal(result.canonical, false);
  assert.equal((await journal.get(result.id)).state, 'SUBMITTED');
  await assert.rejects(relayAutomaticPayment({ ...setup(), config: testConfig(), journal: new MemoryAuditJournal(),
    relay: { address: testConfig().finalizer, chainId: 56, mode: 'TEST_ONLY', testOnly: true, async executeProof() {} } }), /canonical AUTOMATION_EXECUTOR/);
});

for (const change of [
  { recipient: '0x00000000000000000000000000000000000000c1' }, { amount: '1' },
  { proof: ['0x' + '0'.repeat(64)] }, { rewardAsset: '0x00000000000000000000000000000000000000c2' },
  { version: '9' },
]) {
  test('Q-S: rejects a recipient, amount, proof, asset, or version mutation', async () => {
    const f = setup(); await assert.rejects(planAutomaticPayment({ ...f, entry: { ...f.entry, ...change },
      config: testConfig(), journal: new MemoryAuditJournal() }));
  });
}

test('T/U: deterministic idempotency blocks duplicate job and concurrent duplicate plans', async () => {
  const f = setup(); const journal = new MemoryAuditJournal();
  const outcomes = await Promise.allSettled([1, 2].map(() => planAutomaticPayment({ ...f, config: testConfig(), journal })));
  assert.equal(outcomes.filter(x => x.status === 'fulfilled').length, 1);
  assert.equal(outcomes.filter(x => x.status === 'rejected').length, 1);
  const restart = await planAutomaticPayment({ ...f, config: testConfig(), journal });
  assert.equal(restart.id, outcomes.find(x => x.status === 'fulfilled').value.id);
});

test('V: uncertain transaction reconciliation never enables resubmission', async () => {
  const f = setup(); const result = await reconcileTransaction({ chain: f.chain,
    txHash: `0x${'a'.repeat(64)}`, distributionId: f.d.distributionId, version: 1, index: 0 });
  assert.equal(result.state, 'UNCERTAIN'); assert.equal(result.resubmit, false);
});

test('W/X: canonical failed automatic payment is terminal and automatic retries stop', async () => {
  const f = setup({ payment: { failed: true } });
  await assert.rejects(planAutomaticPayment({ ...f, config: testConfig(), journal: new MemoryAuditJournal() }), /already paid, failed/);
  const next = transitionPhase5('EXECUTING', 'FAILED', { canonical: true, failed: true });
  assert.equal(next, 'FAILED_PENDING_MANUAL');
  assert.throws(() => transitionPhase5(next, 'EXECUTING'), /invalid Phase 5 transition/);
});

test('Y-AB: manual settlement plan accepts only exact failed liability and rejects changed recipient/amount', async () => {
  const f = setup(); f.chain.paymentState = async () => ({ canonical: true, failed: true, manualAvailable: true, paid: false });
  f.chain.vaultEntry = async () => ({ version: 1, status: 3, recipient: f.entry.recipient, amount: f.entry.amount, manualSettlementAvailable: true });
  const plan = await planManualSettlement({ ...f, config: testConfig(), entry: f.entry });
  assert.equal(plan.method, 'settleFailedHolderEntry'); assert.equal(plan.broadcast, false);
  await assert.rejects(planManualSettlement({ ...f, config: testConfig(), entry: { ...f.entry, recipient: '0x0000000000000000000000000000000000000001' } }), /recipient changed/);
  await assert.rejects(planManualSettlement({ ...f, config: testConfig(), entry: { ...f.entry, amount: '1' } }), /amount\/asset changed/);
});

test('remediation #3 regression: production manual settlement rejects before any read when snapshot is absent', async () => {
  const f = setup({ payment: { failed: true, manualAvailable: true }, vaultStatus: 3 });
  const reads = [];
  const chain = { ...f.chain,
    async candidate(...args) { reads.push({ method: 'candidate', args }); return f.chain.candidate(...args); },
    async paymentState(...args) { reads.push({ method: 'paymentState', args }); return f.chain.paymentState(...args); },
    async vaultEntry(...args) { reads.push({ method: 'vaultEntry', args }); return f.chain.vaultEntry(...args); },
    readPaymentSnapshot: undefined,
  };
  await assert.rejects(planManualSettlement({ ...f, chain, config: productionTestConfig(), entry: f.entry }), /application-owned execution service/);
  assert.deepEqual(reads, []);
});

test('production manual settlement consumes the application-owned RPC snapshot and returns exact failed liability', async () => {
  const f = setup({ payment: { failed: true, manualAvailable: true }, vaultStatus: 3 });
  const { service, calls } = await productionService(f, { manual: true });
  const plan = await service.planManualSettlement({ verified: f.verified, entry: f.entry });
  assert.equal(plan.method, 'settleFailedHolderEntry');
  assert.equal(plan.recipient, f.entry.recipient);
  assert.equal(plan.amount, f.entry.amount);
  assert.equal(plan.recipientIndex, f.entry.recipientIndex);
  assert.equal(calls.filter(call => call.method === 'candidate').length, 1);
});

test('production manual settlement reads every authorization field through the app-owned block-tagged RPC adapter', async () => {
  const f = setup({ payment: { failed: true, manualAvailable: true }, vaultStatus: 3 });
  const { service, calls } = await productionService(f, { manual: true });
  const plan = await service.planManualSettlement({ verified: f.verified, entry: f.entry });
  assert.equal(plan.method, 'settleFailedHolderEntry');
  assert.equal(calls.length, 6);
  assert.ok(calls.every(call => call.args.at(-1).blockTag === 123));
});

test('manual settlement rejects missing, malformed, or mismatched snapshot block identity', async () => {
  const cases = [
    ['missing number', s => { const { blockNumber, ...rest } = s; return rest; }],
    ['missing hash', s => { const { blockHash, ...rest } = s; return rest; }],
    ['fractional number', s => ({ ...s, blockNumber: 12.5 })],
    ['negative number', s => ({ ...s, blockNumber: -1 })],
    ['malformed hash', s => ({ ...s, blockHash: 'placeholder' })],
    ['wrong block number', s => ({ ...s, blockNumber: 124 })],
    ['wrong block hash', s => ({ ...s, blockHash: `0x${'2'.repeat(64)}` })],
    ['wrong read number', s => ({ ...s, readsAt: { ...s.readsAt, blockNumber: 124 } })],
    ['wrong read hash', s => ({ ...s, readsAt: { ...s.readsAt, blockHash: `0x${'2'.repeat(64)}` } })],
    ['noncanonical', s => ({ ...s, canonical: false })],
  ];
  for (const [_label, mutate] of cases) {
    const f = setup({ payment: { failed: true, manualAvailable: true }, vaultStatus: 3 });
    const snapshot = strictManualSnapshotChain(f, mutate);
    await assert.rejects(planManualSettlement({ ...f, chain: snapshot.chain, config: testConfig(), entry: f.entry }));
  }
});

test('manual settlement rejects unavailable, paid, wrong-state, terminal, or superseded liability', async () => {
  const cases = [
    s => ({ ...s, paymentState: { ...s.paymentState, canonical: false } }),
    s => ({ ...s, paymentState: { ...s.paymentState, paid: true } }),
    s => ({ ...s, paymentState: { ...s.paymentState, failed: false } }),
    s => ({ ...s, paymentState: { ...s.paymentState, manualAvailable: false } }),
    s => ({ ...s, paymentState: { ...s.paymentState, terminal: true } }),
    s => ({ ...s, entry: { ...s.entry, status: 6, manualSettlementAvailable: false } }),
    s => ({ ...s, entry: { ...s.entry, status: 4, manualSettlementAvailable: true } }),
    s => ({ ...s, candidate: { ...s.candidate, status: 2 } }),
    s => ({ ...s, candidate: { ...s.candidate, commitmentVersion: Number(s.candidate.commitmentVersion) + 1 } }),
    s => ({ ...s, candidate: { ...s.candidate, root: `0x${'f'.repeat(64)}` } }),
    s => ({ ...s, lifecycle: 9 }),
  ];
  for (const mutate of cases) {
    const f = setup({ payment: { failed: true, manualAvailable: true }, vaultStatus: 3 });
    const snapshot = strictManualSnapshotChain(f, mutate);
    await assert.rejects(planManualSettlement({ ...f, chain: snapshot.chain, config: testConfig(), entry: f.entry }));
  }
});

test('manual settlement binds snapshot and liability to the exact recipient amount asset distribution and version', async () => {
  const f = setup({ payment: { failed: true, manualAvailable: true }, vaultStatus: 3 });
  const invalidEntries = [
    { recipient: '0x00000000000000000000000000000000000000ff' },
    { amount: String(BigInt(f.entry.amount) + 1n) },
    { rewardAsset: '0x0000000000000000000000000000000000000042' },
    { distributionId: `0x${'f'.repeat(64)}` },
    { version: Number(f.entry.version) + 1 },
  ];
  for (const changes of invalidEntries) {
    await assert.rejects(planManualSettlement({ ...f, config: testConfig(), entry: { ...f.entry, ...changes } }));
  }
  const wrongSnapshot = strictManualSnapshotChain(f, s => ({ ...s, distributionId: `0x${'f'.repeat(64)}` }));
  await assert.rejects(planManualSettlement({ ...f, chain: wrongSnapshot.chain, config: testConfig(), entry: f.entry }), /snapshot identity/);
  const wrongCandidateWindow = strictManualSnapshotChain(f, s => ({ ...s,
    candidate: { ...s.candidate, windowId: `0x${'f'.repeat(64)}` } }));
  await assert.rejects(planManualSettlement({ ...f, chain: wrongCandidateWindow.chain, config: testConfig(), entry: f.entry }), /stale or superseded/);
  const wrongLiability = strictManualSnapshotChain(f, s => ({ ...s,
    entry: { ...s.entry, recipient: '0x00000000000000000000000000000000000000ff' } }));
  await assert.rejects(planManualSettlement({ ...f, chain: wrongLiability.chain, config: testConfig(), entry: f.entry }));
});

test('AC: paid, duplicate manual settlement and non-manual chain state are blocked', async () => {
  const f = setup(); f.chain.paymentState = async () => ({ canonical: true, failed: false, manualAvailable: false, paid: true });
  await assert.rejects(planManualSettlement({ ...f, config: testConfig(), entry: f.entry }), /FAILED_PENDING_MANUAL/);
  await assert.rejects(planAutomaticPayment({ ...f, config: testConfig(), journal: new MemoryAuditJournal() }), /already paid, failed/);
});

test('AD-AF: wrong chain fails and accepted lifecycle labels do not alter the frozen contract gate', async () => {
  const f = setup(); f.chain.chainId = async () => 97;
  await assert.rejects(planAutomaticPayment({ ...f, config: testConfig(), journal: new MemoryAuditJournal() }), /wrong chain/);
  assert.equal(transitionPhase5('VERIFIED', 'FINALIZER_READY'), 'FINALIZER_READY');
});

test('lifecycle and stale RPC observations fail closed', async () => {
  const f = setup(); f.chain.lifecycleState = async () => 8;
  await assert.rejects(planAutomaticPayment({ ...f, config: testConfig(), journal: new MemoryAuditJournal() }), /unknown lifecycle/);
  const g = setup(); g.chain.paymentState = async () => ({ canonical: false });
  await assert.rejects(planAutomaticPayment({ ...g, config: testConfig(), journal: new MemoryAuditJournal() }), /uncanonical\/stale/);
});

test('AG: API exposes only exact Finalizer/Automation/Settler methods; no generic withdrawal selector', async () => {
  const f = setup(); const plan = finalizerCandidatePlan(f.verified, testConfig());
  assert.equal(plan.method, 'submitCandidate'); assert.equal(plan.broadcast, false);
  assert.throws(() => transitionPhase5('EXECUTABLE', 'WITHDRAW'), /invalid Phase 5 transition/);
});

test('review acceptance uses canonical observed timestamp and rejects locally selected time', () => {
  assert.equal(transitionPhase5('COMMIT_SUBMITTED', 'ACCEPTED', { acceptedAt: '7000', executableAfter: '8800', canonical: true }), 'REVIEW_PENDING');
  assert.throws(() => transitionPhase5('COMMIT_SUBMITTED', 'ACCEPTED', { acceptedAt: '7000', executableAfter: '8799', canonical: true }), /interval mismatch/);
  assert.throws(() => transitionPhase5('COMMIT_SUBMITTED', 'ACCEPTED', { acceptedAt: '7000', executableAfter: '8800', canonical: false }), /canonical on-chain/);
});

test('receipt reconciliation needs canonical receipt plus authoritative on-chain paid state', async () => {
  const f = setup(); f.chain.reconcile = async () => ({ status: 'SUCCESS', receiptAvailable: true, canonical: true, blockNumber: 22, confirmations: 5 });
  f.chain.paymentState = async () => ({ canonical: true, paid: true });
  f.chain.paymentEvent = async () => ({ exact: true, state: 'PAID' });
  const result = await reconcileTransaction({ chain: f.chain, txHash: `0x${'a'.repeat(64)}`,
    distributionId: f.d.distributionId, version: 1, index: 0 });
  assert.equal(result.state, 'PAID'); assert.equal(result.resubmit, false);
  f.chain.paymentState = async () => ({ canonical: true, paid: false, failed: true });
  f.chain.paymentEvent = async () => ({ exact: true, state: 'FAILED_PENDING_MANUAL' });
  f.chain.reconcile = async () => ({ status: 'SUCCESS', receiptAvailable: true, canonical: true, blockNumber: 22 });
  const failed = await reconcileTransaction({ chain: f.chain, txHash: `0x${'b'.repeat(64)}`,
    distributionId: f.d.distributionId, version: 1, index: 0 });
  assert.equal(failed.state, 'FAILED_PENDING_MANUAL'); assert.equal(failed.resubmit, false);
});

test('manual settlement success requires its exact canonical manual Vault event and paid state', async () => {
  const f = setup();
  f.chain.reconcile = async () => ({ status: 'SUCCESS', receiptAvailable: true, canonical: true, blockNumber: 33 });
  f.chain.paymentState = async () => ({ canonical: true, paid: true });
  f.chain.paymentEvent = async (_hash, expected) => ({ exact: expected.kind === 'MANUAL'
    && expected.recipient === f.entry.recipient && expected.amount === f.entry.amount, state: 'PAID_MANUALLY' });
  const result = await reconcileManualSettlement({ chain: f.chain, txHash: `0x${'c'.repeat(64)}`,
    distributionId: f.d.distributionId, version: 1, index: f.entry.recipientIndex,
    recipient: f.entry.recipient, amount: f.entry.amount });
  assert.equal(result.state, 'PAID_MANUALLY');
  f.chain.paymentEvent = async () => ({ exact: false, state: 'UNKNOWN' });
  assert.equal((await reconcileManualSettlement({ chain: f.chain, txHash: `0x${'c'.repeat(64)}`,
    distributionId: f.d.distributionId, version: 1, index: f.entry.recipientIndex,
    recipient: f.entry.recipient, amount: f.entry.amount })).state, 'UNCERTAIN');
});

test('durable journal survives reopening and enforces atomic duplicate claims', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'compd-phase5-')); const path = join(dir, 'audit.ndjson');
  try {
    const first = await FileAuditJournal.open(path);
    const record = { state: 'PLANNED', distributionId: 'd', version: '1', recipient: 'r', amount: '2', rewardAsset: 'a' };
    const second = await FileAuditJournal.open(path);
    const concurrentClaims = await Promise.all([first.claim('id', record), second.claim('id', record)]);
    assert.equal(concurrentClaims.filter(Boolean).length, 1);
    assert.equal(concurrentClaims.filter(x => !x).length, 1);
    assert.equal((await second.get('id')).state, 'PLANNED');
    await first.put('id', { ...record, state: 'FAILED_PENDING_MANUAL' });
    await assert.rejects(first.put('id', { ...record, state: 'PLANNED' }), /terminal/);
    await first.put('id', { ...record, state: 'PAID_MANUALLY' });
    await assert.rejects(first.put('id', { ...record, state: 'PAID_MANUALLY' }), /terminal/);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('audit observations reject credential-shaped fields', async () => {
  const journal = new MemoryAuditJournal();
  await assert.rejects(recordPhase5Observation(journal, 'candidate', { state: 'VERIFIED', privateKey: 'never accepted' }), /not permitted/);
  await recordPhase5Observation(journal, 'candidate', { state: 'REVIEW_PENDING', datasetHash: `0x${'a'.repeat(64)}` });
  assert.equal((await journal.get('candidate')).state, 'REVIEW_PENDING');
});

test('read-only RPC adapter pins all contract reads to one canonical block and requires explicit finality verifier', async () => {
  const block = { number: 123, hash: `0x${'1'.repeat(64)}`, timestamp: 999 };
  const calls = [];
  class FakeContract {
    constructor(address) {
      this.address = address;
      this.interface = { parseLog(log) { return { name: log.name, args: log.args }; } };
      for (const method of ['candidate', 'rootByVersion', 'datasetHashByVersion', 'materializedLeafHash', 'holderRewardEntry', 'lifecycle']) {
        this[method] = async (...args) => { calls.push({ address, method, args });
          if (method === 'candidate') return { status: 3 };
          if (method === 'rootByVersion') return `0x${'2'.repeat(64)}`;
          if (method === 'datasetHashByVersion') return `0x${'3'.repeat(64)}`;
          if (method === 'materializedLeafHash') return `0x${'4'.repeat(64)}`;
          if (method === 'lifecycle') return 1;
          return { status: 2, version: 1, recipient: '0x00000000000000000000000000000000000000b2', amount: 100, manualSettlementAvailable: false };
        };
      }
    }
  }
  const provider = { async getNetwork() { return { chainId: 56n }; }, async getBlock() { return block; } };
  await assert.rejects(createReadOnlyChainAdapter({ provider, distributorAddress: 'd', vaultAddress: 'v', deploymentBlock: 1 }), /finality verifier required/);
  const adapter = await createReadOnlyChainAdapter({ provider, distributorAddress: 'd', vaultAddress: 'v', deploymentBlock: 1,
    finality: { status: 'TEST_ONLY', async isFinalized() { return true; } }, contractFactory: FakeContract });
  const snapshot = await adapter.readPaymentSnapshot({ distributionId: 'id' }, 0, 1);
  assert.equal(snapshot.chainId, 56); assert.equal(snapshot.canonical, true);
  assert.equal(snapshot.distributionId, 'id'); assert.equal(snapshot.version, 1); assert.equal(snapshot.index, 0);
  assert.equal(snapshot.blockNumber, 123); assert.equal(snapshot.blockHash, block.hash);
  assert.equal(snapshot.testOnly, true);
  assert.deepEqual(snapshot.readsAt, { blockNumber: 123, blockHash: block.hash });
  assert.ok(calls.every(call => call.args.at(-1).blockTag === 123));
  assert.equal(calls.length, 6);
  const receipt = { blockNumber: 123, blockHash: block.hash, status: 1, logs: [
    { address: 'd', name: 'AutomaticPayoutSucceeded', args: { distributionId: 'dist', version: 1,
      recipientIndex: 0, recipient: '0x00000000000000000000000000000000000000b2', amount: '100' } },
    { address: 'v', name: 'HolderPayoutSucceeded', args: { distributionId: 'dist', version: 1,
      recipientIndex: 0, recipient: '0x00000000000000000000000000000000000000b2', amount: '100', manual: false } },
  ] };
  provider.getTransactionReceipt = async () => receipt;
  const event = await adapter.paymentEvent(`0x${'a'.repeat(64)}`, { distributionId: 'dist', version: 1,
    index: 0, kind: 'AUTOMATIC' });
  assert.equal(event.exact, true); assert.equal(event.state, 'PAID');
  receipt.logs[1].args.amount = '101';
  assert.equal((await adapter.paymentEvent(`0x${'a'.repeat(64)}`, { distributionId: 'dist', version: 1,
    index: 0, kind: 'AUTOMATIC' })).exact, false);
});

test('read-only RPC adapter rejects a block-number/hash reorg mismatch during snapshot creation', async () => {
  const canonical = { number: 123, hash: `0x${'1'.repeat(64)}`, timestamp: 999 };
  let reads = 0;
  const provider = { async getNetwork() { return { chainId: 56n }; }, async getBlock() {
    reads++;
    return reads === 2 ? { ...canonical, hash: `0x${'2'.repeat(64)}` } : canonical;
  } };
  class Contract { constructor() { for (const method of ['candidate', 'rootByVersion', 'datasetHashByVersion', 'materializedLeafHash', 'holderRewardEntry', 'lifecycle']) this[method] = async () => ({}); } }
  const adapter = await createReadOnlyChainAdapter({ provider, distributorAddress: 'd', vaultAddress: 'v', deploymentBlock: 1,
    finality: { status: 'TEST_ONLY', async isFinalized() { return true; } }, contractFactory: Contract });
  await assert.rejects(adapter.readPaymentSnapshot({ distributionId: 'id' }, 0, 1), /hash changed/);
});

test('read-only RPC adapter verifies the initial lookup returns the requested block number and hash', async () => {
  const canonical = { number: 123, hash: `0x${'1'.repeat(64)}`, timestamp: 999 };
  let reads = 0;
  const provider = { async getNetwork() { return { chainId: 56n }; }, async getBlock() {
    reads++;
    return reads === 2 ? { ...canonical, number: 122 } : canonical;
  } };
  class Contract { constructor() { for (const method of ['candidate', 'rootByVersion', 'datasetHashByVersion', 'materializedLeafHash', 'holderRewardEntry', 'lifecycle']) this[method] = async () => ({}); } }
  const adapter = await createReadOnlyChainAdapter({ provider, distributorAddress: 'd', vaultAddress: 'v', deploymentBlock: 1,
    finality: { status: 'TEST_ONLY', async isFinalized() { return true; } }, contractFactory: Contract });
  await assert.rejects(adapter.readPaymentSnapshot({ distributionId: 'id' }, 0, 1), /block hash changed/);
});

test('read-only RPC adapter rechecks block hash after all pinned state reads complete', async () => {
  const canonical = { number: 123, hash: `0x${'1'.repeat(64)}`, timestamp: 999 };
  let reads = 0;
  const provider = { async getNetwork() { return { chainId: 56n }; }, async getBlock() {
    reads++;
    return reads === 3 ? { ...canonical, hash: `0x${'2'.repeat(64)}` } : canonical;
  } };
  class Contract { constructor() { for (const method of ['candidate', 'rootByVersion', 'datasetHashByVersion', 'materializedLeafHash', 'holderRewardEntry', 'lifecycle']) this[method] = async () => ({}); } }
  const adapter = await createReadOnlyChainAdapter({ provider, distributorAddress: 'd', vaultAddress: 'v', deploymentBlock: 1,
    finality: { status: 'TEST_ONLY', async isFinalized() { return true; } }, contractFactory: Contract });
  await assert.rejects(adapter.readPaymentSnapshot({ distributionId: 'id' }, 0, 1), /hash mismatch after block-pinned reads/);
});

