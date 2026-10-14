#!/usr/bin/env node
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { performance } from 'node:perf_hooks';
import { canonicalJson, sha256Hex } from './src/codec.mjs';
import { findReorg, verifyInputBundle } from './src/core.mjs';

function parseArgs(argv) {
  const [command, ...rest] = argv;
  const options = {};
  for (let i = 0; i < rest.length; i++) {
    const key = rest[i];
    if (!key.startsWith('--') || i + 1 >= rest.length) throw new Error(`Invalid argument near ${key}`);
    options[key.slice(2)] = rest[++i];
  }
  if (!['reproduce', 'verify-candidate'].includes(command)) throw new Error('Usage: node offchain/holder-rewards-v1/cli.mjs reproduce --input <bundle.json> --output <dataset.json> --manifest <manifest.json> [--previous-manifest <manifest.json>] | verify-candidate --input <bundle.json> --candidate <candidate.json>');
  const requiredKeys = command === 'reproduce' ? ['input', 'output', 'manifest'] : ['input', 'candidate'];
  for (const key of requiredKeys) if (!options[key]) throw new Error(`--${key} is required`);
  return { command, options };
}

async function main() {
  const { command, options } = parseArgs(process.argv.slice(2));
  const started = performance.now();
  const inputPath = resolve(options.input);
  const input = JSON.parse(await readFile(inputPath, 'utf8'));
  const result = verifyInputBundle(input);
  if (command === 'verify-candidate') {
    const candidate = JSON.parse(await readFile(resolve(options.candidate), 'utf8'));
    const expected = {
      distributionId: result.dataset.distributionId,
      datasetHash: result.dataset.datasetHash,
      root: result.dataset.merkle.root,
    };
    if (!expected.root) throw new Error('No executable Merkle root exists for this positive recipient distribution');
    for (const field of Object.keys(expected)) {
      if (typeof candidate[field] !== 'string' || candidate[field].toLowerCase() !== expected[field].toLowerCase()) {
        throw new Error(`Independent candidate verification failed: ${field} mismatch`);
      }
    }
    process.stdout.write(`${canonicalJson({ mode: 'TEST_ONLY', status: 'MATCH', candidate: expected, elapsedMilliseconds: Math.round(performance.now() - started) })}\n`);
    return;
  }
  const datasetPath = resolve(options.output);
  const manifestPath = resolve(options.manifest);
  let reorg = { reorg: false, commonAncestorBlock: null, rollbackFromBlock: null, action: 'initial replay' };
  if (options['previous-manifest']) {
    const prior = JSON.parse(await readFile(resolve(options['previous-manifest']), 'utf8'));
    if (!Array.isArray(prior.priorHeaderChain)) throw new Error('Previous manifest has no replayable header chain; full independent resync is required');
    const detected = findReorg(prior.priorHeaderChain, result.normalizedHeaders);
    reorg = { ...detected, action: detected.reorg ? 'replay all normalized events from configured start after detecting changed canonical history' : 'canonical prefix unchanged; replay supplied input bundle' };
  }
  const manifest = {
    ...result.sourceManifest,
    inputBundleHash: result.inputBundleHash,
    outputDatasetBytesSha256: sha256Hex(result.datasetBytes),
    priorHeaderChain: result.normalizedHeaders,
    reorg,
  };
  await mkdir(dirname(datasetPath), { recursive: true });
  await mkdir(dirname(manifestPath), { recursive: true });
  await writeFile(datasetPath, result.datasetBytes, { encoding: 'utf8' });
  await writeFile(manifestPath, canonicalJson(manifest), { encoding: 'utf8' });
  process.stdout.write(`${canonicalJson({
    mode: 'TEST_ONLY', datasetPath, manifestPath, recipientCount: result.dataset.recipientCount,
    pool: result.dataset.profitAttribution.windowPool, datasetHash: result.dataset.datasetHash,
    merkleRoot: result.dataset.merkle.root, reorg, elapsedMilliseconds: Math.round(performance.now() - started),
  })}\n`);
}

main().catch(error => {
  process.stderr.write(`Phase-4 replay failed closed: ${error.stack ?? error.message}\n`);
  process.exitCode = 1;
});
