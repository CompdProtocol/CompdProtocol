import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { performance } from 'node:perf_hooks';
import { buildDataset } from './src/core.mjs';

const fixture = JSON.parse(await readFile(new URL('./fixtures/half-window-transfer.json', import.meta.url), 'utf8'));
const balance = '500000000000000000000000';
const addressFor = index => `0x${BigInt(index).toString(16).padStart(40, '0')}`;
const txHash = index => `0x${(BigInt(index) + 1n).toString(16).padStart(64, '0')}`;
const results = [];

for (const eventCount of [1_000, 10_000, 100_000]) {
  const input = structuredClone(fixture);
  const addresses = Array.from({ length: eventCount }, (_, index) => addressFor(index + 1));
  input.replay.initialState.balances = addresses.map(address => ({ address, balance }));
  input.replay.initialState.totalSupply = (BigInt(eventCount) * BigInt(balance)).toString();
  input.checkpoint.balances = addresses.map(address => ({ address, balance }));
  input.checkpoint.totalSupply = input.replay.initialState.totalSupply;
  input.replay.transferEvents = addresses.map((address, index) => ({
    blockNumber: '2', transactionIndex: String(index), logIndex: String(index),
    blockHash: input.replay.blockHeaders[1].hash, transactionHash: txHash(index),
    token: input.config.compdToken, from: address, to: address, value: '0',
  }));
  const before = process.memoryUsage();
  const started = performance.now();
  const result = buildDataset(input);
  const elapsedMs = Math.round(performance.now() - started);
  const after = process.memoryUsage();
  results.push({
    eventCount, elapsedMs, rssDeltaBytes: after.rss - before.rss,
    heapUsedDeltaBytes: after.heapUsed - before.heapUsed,
    datasetHash: result.dataset.datasetHash,
  });
}

process.stdout.write(`${JSON.stringify({ mode: 'TEST_ONLY benchmark; one address and zero-value self-transfer per row', node: process.version, results }, null, 2)}\n`);
