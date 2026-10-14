import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { abiEncode, canonicalJson, keccak256, sha256Hex } from '../src/codec.mjs';
import {
  ALGORITHM_VERSION, ELIGIBILITY_THRESHOLD, HASH_TYPES, WINDOW_SECONDS,
  buildDataset, findReorg, hamiltonAllocate, leafHash, nextEligibleWindowStart,
  selectTop30, verifyInputBundle, verifyPhase3Proof,
} from '../src/core.mjs';

const fixturePath = new URL('../fixtures/half-window-transfer.json', import.meta.url);
const fixture = JSON.parse(await readFile(fixturePath, 'utf8'));
const start = 2_880_000n;
const end = start + WINDOW_SECONDS;
const A = '0x00000000000000000000000000000000000000a1';
const B = '0x00000000000000000000000000000000000000b2';
const C = '0x00000000000000000000000000000000000000c3';
const TOKEN = fixture.config.compdToken;
const ZERO = `0x${'0'.repeat(40)}`;
const HASH0 = `0x${'0'.repeat(64)}`;
const amount = n => BigInt(n).toString();
const blockHash = number => `0x${BigInt(number).toString(16).padStart(64, '0')}`;
const txHash = number => `0x${(0xa000n + BigInt(number)).toString(16).padStart(64, '0')}`;

function clone(value) { return JSON.parse(JSON.stringify(value)); }

function makeBundle({
  activationTimestamp = start - 1n,
  initialBalances = new Map([[A, ELIGIBILITY_THRESHOLD]]),
  transfers = [],
  profitAttributions = [{ timestamp: start + 1n, profit: 1000n }],
  exclusions = [],
  exclusionVersion = 1n,
  checkpointBalances: checkpointOverride,
  checkpointHashOverride,
  eventOrder,
  rewardAsset = fixture.rewardAsset,
} = {}) {
  const timestamps = new Set([activationTimestamp.toString(), end.toString(), ...transfers.map(e => BigInt(e.timestamp).toString()), ...profitAttributions.map(e => BigInt(e.timestamp).toString())]);
  const orderedTimestamps = [...timestamps].map(BigInt).sort((x, y) => x < y ? -1 : x > y ? 1 : 0);
  const headers = orderedTimestamps.map((timestamp, index) => ({
    number: BigInt(index + 1), hash: blockHash(index + 1), parentHash: index === 0 ? HASH0 : blockHash(index), timestamp,
  }));
  const headerByTimestamp = new Map(headers.map(h => [h.timestamp.toString(), h]));
  const events = transfers.map((event, index) => {
    const header = headerByTimestamp.get(BigInt(event.timestamp).toString());
    return {
      blockNumber: header.number.toString(), transactionIndex: String(event.transactionIndex ?? 0),
      logIndex: String(event.logIndex ?? index), blockHash: header.hash,
      transactionHash: event.transactionHash ?? txHash(index + 1), token: event.token ?? TOKEN,
      from: event.from, to: event.to, value: amount(event.value),
    };
  });
  const initial = new Map([...initialBalances].map(([key, value]) => [key.toLowerCase(), BigInt(value)]));
  const supplyBefore = [...initial.values()].reduce((sum, value) => sum + value, 0n);
  const state = new Map(initial);
  let supplyAfter = supplyBefore;
  const orderedEvents = eventOrder ? eventOrder(events) : [...events];
  for (const event of [...events].sort((x, y) => BigInt(x.blockNumber) !== BigInt(y.blockNumber)
    ? (BigInt(x.blockNumber) < BigInt(y.blockNumber) ? -1 : 1)
    : BigInt(x.transactionIndex) !== BigInt(y.transactionIndex)
      ? (BigInt(x.transactionIndex) < BigInt(y.transactionIndex) ? -1 : 1)
      : BigInt(x.logIndex) < BigInt(y.logIndex) ? -1 : 1)) {
    const value = BigInt(event.value);
    const from = event.from.toLowerCase(); const to = event.to.toLowerCase();
    if (from === ZERO) supplyAfter += value;
    else if (from !== to && value > 0n) {
      const before = state.get(from) ?? 0n; assert.ok(before >= value);
      if (before === value) state.delete(from); else state.set(from, before - value);
    }
    if (to === ZERO) supplyAfter -= value;
    else if (from !== to && value > 0n) state.set(to, (state.get(to) ?? 0n) + value);
  }
  const checkpointBalances = checkpointOverride ?? [...state.entries()]
    .filter(([, balance]) => balance !== 0n).map(([address, balance]) => ({ address, balance: balance.toString() }));
  const checkpoint = headers.at(-1);
  const canonicalProfit = profitAttributions.map((record, index) => {
    const header = headerByTimestamp.get(BigInt(record.timestamp).toString());
    const profit = BigInt(record.profit);
    return {
      sourceKind: record.sourceKind ?? 'RealizedProfitRouted', blockNumber: header.number.toString(),
      blockHash: header.hash, transactionHash: record.transactionHash ?? txHash(100 + index),
      logIndex: String(record.logIndex ?? 1000 + index), positiveRealizedProfit: profit.toString(),
      holderReward: (profit * 1000n / 10000n).toString(),
    };
  });
  return {
    mode: 'TEST_ONLY', chainId: '56', config: clone(fixture.config),
    activation: { blockNumber: '1', blockHash: headers[0].hash, timestamp: activationTimestamp.toString() },
    replay: {
      startBlock: '1', endBlock: checkpoint.number.toString(),
      initialState: { blockNumber: '0', blockHash: HASH0, totalSupply: supplyBefore.toString(), balances: [...initial.entries()].map(([address, balance]) => ({ address, balance: balance.toString() })) },
      blockHeaders: headers.map(h => ({ number: h.number.toString(), hash: h.hash, parentHash: h.parentHash, timestamp: h.timestamp.toString() })),
      transferEvents: orderedEvents,
    },
    checkpoint: {
      blockNumber: checkpoint.number.toString(), blockHash: checkpointHashOverride ?? checkpoint.hash,
      totalSupply: supplyAfter.toString(), balances: checkpointBalances,
    },
    window: { commitmentVersion: '1', start: start.toString(), end: end.toString() },
    exclusionRegistry: { version: exclusionVersion.toString(), addresses: exclusions }, rewardAsset,
    profitAttributions: canonicalProfit, algorithmVersion: String(ALGORITHM_VERSION),
    eventSource: { kind: 'normalized-test-fixture', bundleSha256: `0x${'ee'.repeat(32)}` },
    finalityPolicy: { status: 'TEST_ONLY', label: 'SIMULATED FINALITY — TEST ONLY' },
  };
}

function addr(i) { return `0x${BigInt(i).toString(16).padStart(40, '0')}`; }

test('Ethereum Keccak-256 and ABI encoder use legacy Keccak and Solidity ABI conventions', () => {
  assert.equal(keccak256(''), '0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470');
  assert.equal(keccak256('abc'), '0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45');
  assert.equal(keccak256(abiEncode(['uint256'], [1n])), '0xb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6');
});

test('activation boundaries select no backpay and handle day/month/year rollovers', () => {
  assert.equal(nextEligibleWindowStart(start - 1n), start);
  assert.equal(nextEligibleWindowStart(start), start);
  assert.equal(nextEligibleWindowStart(start + 1n), start + WINDOW_SECONDS);
  const boundaries = [
    Date.UTC(2026, 0, 1, 0, 0, 0) / 1000,
    Date.UTC(2026, 0, 31, 16, 0, 0) / 1000,
    Date.UTC(2026, 11, 31, 16, 0, 0) / 1000,
  ].map(BigInt);
  for (const boundary of boundaries) {
    assert.equal(nextEligibleWindowStart(boundary - 1n), boundary);
    assert.equal(nextEligibleWindowStart(boundary), boundary);
    assert.equal(nextEligibleWindowStart(boundary + 1n), boundary + WINDOW_SECONDS);
  }
  assert.throws(() => buildDataset({ ...clone(fixture), window: { ...fixture.window, start: amount(start - WINDOW_SECONDS), end: amount(start) } }), /precedes the first complete eligible window/);
});

test('half-window transfer gives each address exactly its own 4-hour token time', () => {
  const output = buildDataset(clone(fixture)).dataset;
  assert.equal(output.entries.length, 2);
  assert.deepEqual(output.entries.map(e => e.eligibleWeightBalanceSeconds), [
    (2n * ELIGIBILITY_THRESHOLD * 14_400n).toString(), (2n * ELIGIBILITY_THRESHOLD * 14_400n).toString(),
  ]);
  assert.deepEqual(output.entries.map(e => e.payout), ['50', '50']);
  assert.equal(output.merkle.root, '0x5ee84d858c56051214d41e42dbb2d7db441a07fb7b410b21dd8c44462dc6f463');
});

test('threshold is applied per segment, including exact, upward/downward, final-second, and first-second crossings', () => {
  const t = ELIGIBILITY_THRESHOLD;
  const midpoint = start + WINDOW_SECONDS / 2n;
  const heldExact = buildDataset(makeBundle({ initialBalances: new Map([[A, t]]) })).dataset;
  assert.equal(heldExact.entries[0].eligibleWeightBalanceSeconds, (t * WINDOW_SECONDS).toString());
  const below = buildDataset(makeBundle({ initialBalances: new Map([[A, t - 1n]]) })).dataset;
  assert.equal(below.entries.length, 0);
  const up = buildDataset(makeBundle({ initialBalances: new Map(), transfers: [{ timestamp: midpoint, from: ZERO, to: A, value: t }] })).dataset;
  assert.equal(up.entries[0].eligibleWeightBalanceSeconds, (t * (WINDOW_SECONDS / 2n)).toString());
  const down = buildDataset(makeBundle({ initialBalances: new Map([[A, t]]), transfers: [{ timestamp: midpoint, from: A, to: B, value: 1n }] })).dataset;
  assert.equal(down.entries.find(e => e.address === A).eligibleWeightBalanceSeconds, (t * (WINDOW_SECONDS / 2n)).toString());
  assert.equal(down.entries.some(e => e.address === B), false);
  const enterLastSecond = buildDataset(makeBundle({ initialBalances: new Map(), transfers: [{ timestamp: end - 1n, from: ZERO, to: A, value: t }] })).dataset;
  assert.equal(enterLastSecond.entries[0].eligibleWeightBalanceSeconds, t.toString());
  const exitAfterFirst = buildDataset(makeBundle({ initialBalances: new Map([[A, t]]), transfers: [{ timestamp: start + 1n, from: A, to: B, value: t }] })).dataset;
  assert.equal(exitAfterFirst.entries.find(e => e.address === A).eligibleWeightBalanceSeconds, t.toString());
});

test('multiple same-window threshold crossings accrue only the above-threshold intervals', () => {
  const t = ELIGIBILITY_THRESHOLD;
  const output = buildDataset(makeBundle({
    initialBalances: new Map(),
    transfers: [
      { timestamp: start + 1n, from: ZERO, to: A, value: t },
      { timestamp: start + 2n, from: A, to: ZERO, value: t },
      { timestamp: start + 3n, from: ZERO, to: A, value: t },
    ],
  })).dataset;
  assert.equal(output.entries.length, 1);
  assert.equal(output.entries[0].eligibleWeightBalanceSeconds, (t * (WINDOW_SECONDS - 2n)).toString());
});

test('exact window boundary is half-open: start transfer counts immediately; end transfer counts next window', () => {
  const output = buildDataset(makeBundle({
    initialBalances: new Map([[A, ELIGIBILITY_THRESHOLD]]),
    transfers: [
      { timestamp: start, from: A, to: B, value: ELIGIBILITY_THRESHOLD },
      { timestamp: end, from: B, to: A, value: ELIGIBILITY_THRESHOLD },
    ],
  })).dataset;
  assert.equal(output.entries.length, 1);
  assert.equal(output.entries[0].address, B);
  assert.equal(output.entries[0].eligibleWeightBalanceSeconds, (ELIGIBILITY_THRESHOLD * WINDOW_SECONDS).toString());
});

test('rapid same-block transfer chain does not double-count token-time', () => {
  const midpoint = start + WINDOW_SECONDS / 2n;
  const output = buildDataset(makeBundle({
    initialBalances: new Map([[A, ELIGIBILITY_THRESHOLD]]),
    transfers: [
      { timestamp: midpoint, from: A, to: B, value: ELIGIBILITY_THRESHOLD, logIndex: 1 },
      { timestamp: midpoint, from: B, to: C, value: ELIGIBILITY_THRESHOLD, logIndex: 2 },
    ],
  })).dataset;
  const weights = Object.fromEntries(output.entries.map(e => [e.address, e.eligibleWeightBalanceSeconds]));
  assert.equal(weights[A], (ELIGIBILITY_THRESHOLD * WINDOW_SECONDS / 2n).toString());
  assert.equal(weights[B], undefined);
  assert.equal(weights[C], (ELIGIBILITY_THRESHOLD * WINDOW_SECONDS / 2n).toString());
});

test('mint, burn, self transfer, zero transfer, and excluded-system address handling are explicit', () => {
  const midpoint = start + WINDOW_SECONDS / 2n;
  const output = buildDataset(makeBundle({
    initialBalances: new Map(),
    transfers: [
      { timestamp: start, from: ZERO, to: A, value: ELIGIBILITY_THRESHOLD },
      { timestamp: start + 1n, from: A, to: A, value: ELIGIBILITY_THRESHOLD },
      { timestamp: start + 2n, from: B, to: C, value: 0n },
      { timestamp: midpoint, from: A, to: ZERO, value: ELIGIBILITY_THRESHOLD },
    ],
  })).dataset;
  assert.equal(output.entries.length, 1);
  assert.equal(output.entries[0].address, A);
  assert.equal(output.entries[0].eligibleWeightBalanceSeconds, (ELIGIBILITY_THRESHOLD * (WINDOW_SECONDS / 2n)).toString());
  const excluded = buildDataset(makeBundle({ initialBalances: new Map([[A, ELIGIBILITY_THRESHOLD]]), exclusions: [A.toUpperCase().replace('0X', '0x')] })).dataset;
  assert.equal(excluded.entries.length, 0);
  assert.equal(excluded.merkle.root, null);
});

test('canonical ordering normalizes shuffled raw events and rejects duplicate/missing/inconsistent logs', () => {
  const transferTime = start + 100n;
  const transfers = [
    { timestamp: transferTime, from: A, to: B, value: 20n, transactionIndex: 1, logIndex: 2 },
    { timestamp: transferTime, from: A, to: C, value: 10n, transactionIndex: 0, logIndex: 1 },
  ];
  const sorted = makeBundle({ initialBalances: new Map([[A, ELIGIBILITY_THRESHOLD]]) , transfers });
  const shuffled = makeBundle({ initialBalances: new Map([[A, ELIGIBILITY_THRESHOLD]]), transfers, eventOrder: rows => rows.reverse() });
  assert.equal(buildDataset(sorted).dataset.datasetHash, buildDataset(shuffled).dataset.datasetHash);
  const duplicate = clone(sorted); duplicate.replay.transferEvents.push(clone(duplicate.replay.transferEvents[0]));
  assert.throws(() => buildDataset(duplicate), /Duplicate Transfer event/);
  const missing = clone(fixture); missing.replay.transferEvents = [];
  assert.throws(() => buildDataset(missing), /checkpoint balance reconciliation/);
  const badCheckpoint = clone(fixture); badCheckpoint.checkpoint.balances[0].balance = '1';
  assert.throws(() => buildDataset(badCheckpoint), /checkpoint balance reconciliation/);
});

test('block continuity, activation/checkpoint hashes, wrong token, and impossible negative replay fail closed', () => {
  const badParent = clone(fixture); badParent.replay.blockHeaders[2].parentHash = HASH0;
  assert.throws(() => buildDataset(badParent), /parent-hash discontinuity/);
  const badCheckpointHash = clone(fixture); badCheckpointHash.checkpoint.blockHash = blockHash(99);
  assert.throws(() => buildDataset(badCheckpointHash), /Checkpoint number\/hash/);
  const badActivation = clone(fixture); badActivation.activation.timestamp = '2880000';
  assert.throws(() => buildDataset(badActivation), /Activation block\/hash\/timestamp/);
  const wrongToken = clone(fixture); wrongToken.replay.transferEvents[0].token = fixture.config.vault;
  assert.throws(() => buildDataset(wrongToken), /does not match configured COMPD/);
  const impossible = clone(fixture);
  impossible.replay.transferEvents[0].value = '1000000000000000000000001';
  assert.throws(() => buildDataset(impossible), /negative balance/);
});

test('Top 30 uses numeric address ties and bounded deterministic selection', () => {
  for (const count of [0, 1, 29, 30, 31]) {
    assert.equal(selectTop30(new Map(Array.from({ length: count }, (_, index) => [addr(index + 1), 1n]))).length, Math.min(count, 30));
  }
  const weights = new Map(Array.from({ length: 31 }, (_, index) => [addr(31 - index), 7n]));
  const top = selectTop30(weights);
  assert.equal(top.length, 30);
  assert.deepEqual(top.map(item => item.address), Array.from({ length: 30 }, (_, i) => addr(i + 1)));
  const large = selectTop30(new Map(Array.from({ length: 1_000 }, (_, i) => [addr(i + 1), BigInt((i * 97) % 13 + 1)])));
  assert.equal(large.length, 30);
  for (let i = 1; i < large.length; i++) assert.ok(large[i - 1].weight > large[i].weight || (large[i - 1].weight === large[i].weight && BigInt(large[i - 1].address) < BigInt(large[i].address)));
});

test('Hamilton covers tiny pools, equal remainder tie, extreme integers and exact conservation', () => {
  const holders = [{ address: addr(1), weight: 1n }, { address: addr(2), weight: 1n }, { address: addr(3), weight: 1n }];
  for (const pool of [1n, 2n, 3n]) {
    const outputs = hamiltonAllocate(holders, pool);
    assert.equal(outputs.reduce((sum, item) => sum + item.payout, 0n), pool);
    assert.deepEqual(outputs.map(item => item.payout), pool === 1n ? [1n, 0n, 0n] : pool === 2n ? [1n, 1n, 0n] : [1n, 1n, 1n]);
  }
  const extreme = hamiltonAllocate([{ address: addr(1), weight: 1n << 200n }, { address: addr(2), weight: 1n << 200n }], (1n << 100n) + 1n);
  assert.equal(extreme.reduce((sum, item) => sum + item.payout, 0n), (1n << 100n) + 1n);
  assert.deepEqual(extreme.map(item => item.payout), [(1n << 99n) + 1n, 1n << 99n]);
  assert.throws(() => hamiltonAllocate([{ address: addr(1), weight: 0n }], 1n), /must be positive/);
});

test('deterministic 256-case Hamilton property campaign conserves every pool exactly', () => {
  let state = 0x5eed1234n;
  const next = max => {
    state = (state * 1_103_515_245n + 12_345n) & 0x7fffffffn;
    return state % max;
  };
  for (let trial = 0; trial < 256; trial++) {
    const count = Number(next(30n)) + 1;
    const recipients = Array.from({ length: count }, (_, index) => ({ address: addr(index + 1), weight: next(1_000_000n) + 1n }));
    const pool = next(1_000_000_000_000n) + 1n;
    const allocations = hamiltonAllocate(recipients, pool);
    assert.equal(allocations.reduce((sum, entry) => sum + entry.payout, 0n), pool, `trial ${trial}`);
    assert.equal(allocations.every(entry => entry.payout >= 0n && entry.payout <= pool), true, `trial ${trial}`);
    assert.deepEqual(allocations.map(entry => entry.payout), hamiltonAllocate(recipients, pool).map(entry => entry.payout), `trial ${trial} deterministic`);
  }
});

test('zero pool, zero recipients, and positive unresolved pool never invent a recipient', () => {
  const zeroPool = buildDataset(makeBundle({ initialBalances: new Map([[A, ELIGIBILITY_THRESHOLD]]), profitAttributions: [{ timestamp: start + 1n, profit: 9n }] })).dataset;
  assert.equal(zeroPool.profitAttribution.windowPool, '0');
  assert.equal(zeroPool.merkle.root, null);
  const noRecipients = buildDataset(makeBundle({ initialBalances: new Map(), profitAttributions: [{ timestamp: start + 1n, profit: 1000n }] })).dataset;
  assert.equal(noRecipients.entries.length, 0);
  assert.equal(noRecipients.merkle.root, null);
  assert.equal(noRecipients.unresolvedHolderPool, '100');
});

test('dataset identity changes with checkpoint, exclusion, asset, domain, versioned algorithm inputs', () => {
  const baseline = buildDataset(clone(fixture)).dataset.datasetHash;
  const changedAsset = clone(fixture); changedAsset.rewardAsset = '0x0000000000000000000000000000000000000098';
  const changedExclusions = clone(fixture); changedExclusions.exclusionRegistry.version = '2';
  const changedCheckpoint = clone(fixture);
  changedCheckpoint.replay.blockHeaders.at(-1).hash = `0x${'ff'.repeat(32)}`;
  changedCheckpoint.checkpoint.blockHash = `0x${'ff'.repeat(32)}`;
  for (const changed of [changedAsset, changedExclusions, changedCheckpoint]) assert.notEqual(buildDataset(changed).dataset.datasetHash, baseline);
  const changedChain = clone(fixture); changedChain.chainId = '97';
  assert.throws(() => buildDataset(changedChain), /canonical chainId must be BNB Chain 56/);
  const staleAlgorithm = clone(fixture); staleAlgorithm.algorithmVersion = '2';
  assert.throws(() => buildDataset(staleAlgorithm), /Unsupported stale algorithm version/);
  const wrongProfit = clone(fixture); wrongProfit.profitAttributions[0].sourceKind = 'FlapRevenue';
  assert.throws(() => buildDataset(wrongProfit), /never Flap revenue/);
  const production = clone(fixture); production.mode = 'PRODUCTION';
  assert.throws(() => buildDataset(production), /Production mode rejected/);
});

test('Phase-3-compatible domain, dataset, leaf, padding, and positional Merkle proofs reproduce exactly', () => {
  const first = verifyInputBundle(clone(fixture));
  const second = verifyInputBundle(clone(fixture));
  assert.equal(first.datasetBytes, second.datasetBytes);
  assert.equal(first.dataset.datasetHash, '0xd2df877525f8769656bd1695ad2a3119abddc2daf19fd0b6591dfc6ce537a736');
  const result = buildDataset(clone(fixture)).dataset;
  for (const leaf of result.merkle.leaves) assert.ok(verifyPhase3Proof(leaf, leaf.proof, result.merkle.root, Number(result.recipientCount)));
  const mutated = { ...result.merkle.leaves[0], amount: '51' };
  assert.equal(verifyPhase3Proof(mutated, result.merkle.leaves[0].proof, result.merkle.root, 2), false);
  assert.equal(HASH_TYPES.domain, keccak256('CompdHolderRewardsDomain(bytes32 protocolId,uint256 chainId,address compdToken,address vault,address distributor,address rewardAsset)'));
});

test('three-recipient tree uses the Phase-3 indexed padding leaf and verifies every positional proof', () => {
  const input = clone(fixture);
  input.replay.transferEvents = [];
  input.replay.initialState.balances = [A, B, C].map(address => ({ address, balance: ELIGIBILITY_THRESHOLD.toString() }));
  input.replay.initialState.totalSupply = (3n * ELIGIBILITY_THRESHOLD).toString();
  input.checkpoint.balances = clone(input.replay.initialState.balances);
  input.checkpoint.totalSupply = input.replay.initialState.totalSupply;
  const result = buildDataset(input).dataset;
  assert.equal(result.merkle.root, '0x40b2d39f6423024e53258ee2ae24b0a950acb83b045106dff7037ef526b016bb');
  const padding = keccak256(abiEncode(['bytes32', 'bytes32', 'bytes32', 'uint32', 'uint16'], [
    HASH_TYPES.padding, result.domainSeparator, result.distributionId, 1n, 3n,
  ]));
  assert.equal(padding, '0xae1b268e149bd79793687eab3654409447aa4ee2dd1b6b2a8aded9b543230a82');
  assert.equal(result.merkle.leaves.every(leaf => verifyPhase3Proof(leaf, leaf.proof, result.merkle.root, 3)), true);
});

test('reorg detector finds common ancestor and requires rollback from first changed height', () => {
  const previous = [1, 2, 3].map(n => ({ number: String(n), hash: blockHash(n) }));
  const current = [1, 2, 3, 4].map(n => ({ number: String(n), hash: n === 3 ? blockHash(30) : blockHash(n) }));
  assert.deepEqual(findReorg(previous, current), { reorg: true, commonAncestorBlock: '2', rollbackFromBlock: '3' });
  assert.deepEqual(findReorg(previous, [...previous, { number: '4', hash: blockHash(4) }]), { reorg: false, commonAncestorBlock: '3', rollbackFromBlock: null });
});

test('independent CLI processes reproduce byte-identical canonical dataset and manifest', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'compd-holder-replay-'));
  try {
    const input = fileURLToPath(new URL('../fixtures/half-window-transfer.json', import.meta.url));
    const cli = fileURLToPath(new URL('../cli.mjs', import.meta.url));
    const outputs = [];
    for (let run = 0; run < 2; run++) {
      const dataset = join(directory, `dataset-${run}.json`); const manifest = join(directory, `manifest-${run}.json`);
      const child = spawnSync(process.execPath, [cli, 'reproduce', '--input', input, '--output', dataset, '--manifest', manifest], { encoding: 'utf8' });
      assert.equal(child.status, 0, child.stderr);
      outputs.push([await readFile(dataset), await readFile(manifest)]);
    }
    assert.deepEqual(outputs[0][0], outputs[1][0]);
    const parsedA = JSON.parse(outputs[0][1]); const parsedB = JSON.parse(outputs[1][1]);
    delete parsedA.reorg; delete parsedB.reorg;
    assert.equal(canonicalJson(parsedA), canonicalJson(parsedB));
    assert.equal(parsedA.outputDatasetBytesSha256, sha256Hex(outputs[0][0].toString('utf8')));
    const candidatePath = join(directory, 'candidate.json');
    const datasetResult = JSON.parse(outputs[0][0].toString('utf8'));
    const candidate = { distributionId: datasetResult.distributionId, datasetHash: datasetResult.datasetHash, root: datasetResult.merkle.root };
    await writeFile(candidatePath, JSON.stringify(candidate));
    const match = spawnSync(process.execPath, [cli, 'verify-candidate', '--input', input, '--candidate', candidatePath], { encoding: 'utf8' });
    assert.equal(match.status, 0, match.stderr);
    assert.match(match.stdout, /"status":"MATCH"/);
    candidate.root = `0x${'ff'.repeat(32)}`;
    await writeFile(candidatePath, JSON.stringify(candidate));
    const mismatch = spawnSync(process.execPath, [cli, 'verify-candidate', '--input', input, '--candidate', candidatePath], { encoding: 'utf8' });
    assert.equal(mismatch.status, 1);
    assert.match(mismatch.stderr, /root mismatch/);
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test('dataset encoding constants and core zero-pool invariants are frozen', () => {
  assert.equal(HASH_TYPES.leaf, keccak256('CompdHolderRewardLeaf(bytes32 domainSeparator,bytes32 distributionId,uint32 commitmentVersion,bytes32 windowId,uint64 windowStart,uint64 windowEnd,address rewardAsset,uint256 windowPool,uint256 finalizedTotalPayable,uint16 recipientIndex,address recipient,uint256 amount,bytes32 datasetHash,uint32 algorithmVersion)'));
  assert.equal(ALGORITHM_VERSION, 1n);
  assert.equal(WINDOW_SECONDS, 28_800n);
  assert.equal(ELIGIBILITY_THRESHOLD, 500_000n * 10n ** 18n);
  assert.equal(leafHash(buildDataset(clone(fixture)).dataset.merkle.leaves[0]), buildDataset(clone(fixture)).dataset.merkle.leaves[0].leafHash);
});
