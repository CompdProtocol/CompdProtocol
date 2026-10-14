import {
  abiEncode, addressHex, bytes32Hex, canonicalJson, keccak256, sha256Hex, uint,
} from './codec.mjs';

// Pure encoders shared by the indexed unsigned proposal builder. Original production guards remain intact.
export {domainFor,windowAndDistribution,computeEntriesHash,computeDatasetHash};

export const WINDOW_SECONDS = 28_800n;
export const ELIGIBILITY_THRESHOLD = 500_000n * 10n ** 18n;
export const MAX_RECIPIENTS = 30;
export const ALGORITHM_VERSION = 1n;
export const SCHEMA_VERSION = 1n;
export const BNB_CHAIN_ID = 56n;

const typeHash = value => keccak256(value);
export const HASH_TYPES = Object.freeze({
  protocolId: typeHash('COMPD_HOLDER_REWARDS_V1'),
  domain: typeHash('CompdHolderRewardsDomain(bytes32 protocolId,uint256 chainId,address compdToken,address vault,address distributor,address rewardAsset)'),
  window: typeHash('CompdHolderRewardWindow(bytes32 domainSeparator,uint256 activationBlock,bytes32 activationBlockHash,uint64 activationTimestamp,uint64 windowStart,uint64 windowEnd)'),
  distribution: typeHash('CompdHolderRewardDistribution(bytes32 domainSeparator,bytes32 windowId)'),
  exclusionSet: typeHash('CompdHolderRewardExclusionSet(uint32 exclusionSetVersion,address[] sortedExcludedAddresses)'),
  entries: typeHash('CompdHolderRewardEntries(uint16[] recipientIndices,address[] recipients,uint256[] weights,uint256[] floorQuotients,uint256[] remainderNumerators,uint256[] finalPayouts)'),
  dataset: typeHash('CompdHolderRewardDataset(bytes32 domainSeparator,bytes32 distributionId,bytes32 windowId,uint64 windowStart,uint64 windowEnd,uint256 windowPool,uint256 finalizedTotalPayable,uint16 recipientCount,uint32 algorithmVersion,uint32 exclusionSetVersion,bytes32 exclusionSetHash,uint256 activationBlock,bytes32 activationBlockHash,uint64 activationTimestamp,uint256 sourceStartBlock,uint256 finalityBlock,bytes32 finalityBlockHash,bytes32 entriesHash)'),
  leaf: typeHash('CompdHolderRewardLeaf(bytes32 domainSeparator,bytes32 distributionId,uint32 commitmentVersion,bytes32 windowId,uint64 windowStart,uint64 windowEnd,address rewardAsset,uint256 windowPool,uint256 finalizedTotalPayable,uint16 recipientIndex,address recipient,uint256 amount,bytes32 datasetHash,uint32 algorithmVersion)'),
  padding: typeHash('CompdHolderRewardPadding(bytes32 domainSeparator,bytes32 distributionId,uint32 commitmentVersion,uint16 paddedIndex)'),
  node: typeHash('CompdHolderRewardNode(bytes32 left,bytes32 right)'),
});

const ZERO_ADDRESS = `0x${'0'.repeat(40)}`;

function required(object, key, where = 'input') {
  if (!Object.hasOwn(object ?? {}, key)) throw new TypeError(`${where}.${key} is required; no production defaults are substituted`);
  return object[key];
}

function canonicalAddressList(values, name, allowEmpty = true) {
  if (!Array.isArray(values)) throw new TypeError(`${name} must be an array`);
  if (!allowEmpty && values.length === 0) throw new RangeError(`${name} cannot be empty`);
  const normalized = values.map((entry, index) => addressHex(typeof entry === 'string' ? entry : entry.address, `${name}[${index}]`, { allowZero: false }));
  const seen = new Set();
  for (const address of normalized) {
    if (seen.has(address)) throw new Error(`${name} contains duplicate address ${address}`);
    seen.add(address);
  }
  return normalized.sort((left, right) => BigInt(left) < BigInt(right) ? -1 : BigInt(left) > BigInt(right) ? 1 : 0);
}

function normalizeBalances(values, name) {
  if (!Array.isArray(values)) throw new TypeError(`${name} must be an explicit array`);
  const balances = new Map();
  for (const [index, item] of values.entries()) {
    const address = addressHex(required(item, 'address', `${name}[${index}]`), `${name}[${index}].address`, { allowZero: false });
    if (balances.has(address)) throw new Error(`${name} contains duplicate address ${address}`);
    const amount = uint(required(item, 'balance', `${name}[${index}]`), 256, `${name}[${index}].balance`);
    if (amount !== 0n) balances.set(address, amount);
  }
  return balances;
}

function mapToBalances(map) {
  return [...map.entries()].filter(([, balance]) => balance !== 0n)
    .sort(([a], [b]) => BigInt(a) < BigInt(b) ? -1 : BigInt(a) > BigInt(b) ? 1 : 0)
    .map(([address, balance]) => ({ address, balance: balance.toString() }));
}

function normalizeHexHash(value, name) { return bytes32Hex(value, name); }

function normalizeChain(input) {
  const mode = required(input, 'mode');
  if (mode !== 'TEST_ONLY' && mode !== 'PRODUCTION') throw new Error('mode must be exactly TEST_ONLY or PRODUCTION');
  if (mode === 'PRODUCTION') {
    const unresolved = input.productionVerification;
    if (!unresolved || unresolved.status !== 'VERIFIED' || !Array.isArray(unresolved.references) || unresolved.references.length === 0) {
      throw new Error('Production mode rejected: canonical activation, BNB finality, token semantics, quote asset, exclusions, profit source, and role/deployment verification remain TBD');
    }
    throw new Error('Production mode remains disabled until an independently reviewed production verification adapter is integrated');
  }
  const finalityPolicy = required(input, 'finalityPolicy');
  if (finalityPolicy.status !== 'TEST_ONLY' || typeof finalityPolicy.label !== 'string' || !finalityPolicy.label.includes('TEST ONLY')) {
    throw new Error('Fixture finality must be explicitly marked TEST ONLY');
  }
  const eventSource = required(input, 'eventSource');
  if (typeof eventSource.kind !== 'string' || typeof eventSource.bundleSha256 !== 'string') {
    throw new Error('eventSource.kind and eventSource.bundleSha256 are required to identify normalized input provenance');
  }
  bytes32Hex(eventSource.bundleSha256, 'eventSource.bundleSha256');
  const chainId = uint(required(input, 'chainId'), 256, 'chainId');
  if (chainId !== BNB_CHAIN_ID) throw new Error('Holder Rewards V1 canonical chainId must be BNB Chain 56');
  const config = required(input, 'config');
  const compdToken = addressHex(required(config, 'compdToken', 'config'), 'config.compdToken', { allowZero: false });
  const vault = addressHex(required(config, 'vault', 'config'), 'config.vault', { allowZero: false });
  const distributor = addressHex(required(config, 'distributor', 'config'), 'config.distributor', { allowZero: false });
  const rewardAsset = addressHex(required(input, 'rewardAsset'), 'rewardAsset');
  const activation = required(input, 'activation');
  const activationBlock = uint(required(activation, 'blockNumber', 'activation'), 256, 'activation.blockNumber');
  const activationBlockHash = normalizeHexHash(required(activation, 'blockHash', 'activation'), 'activation.blockHash');
  const activationTimestamp = uint(required(activation, 'timestamp', 'activation'), 64, 'activation.timestamp');
  const window = required(input, 'window');
  const windowStart = uint(required(window, 'start', 'window'), 64, 'window.start');
  const windowEnd = uint(required(window, 'end', 'window'), 64, 'window.end');
  if (windowEnd - windowStart !== WINDOW_SECONDS || windowStart % WINDOW_SECONDS !== 0n) {
    throw new Error('Reward window must be exactly one UTC-aligned half-open 8-hour interval');
  }
  const firstEligible = nextEligibleWindowStart(activationTimestamp);
  if (windowStart < firstEligible) throw new Error('Window precedes the first complete eligible window after activation');
  const exclusion = required(input, 'exclusionRegistry');
  const exclusionVersion = uint(required(exclusion, 'version', 'exclusionRegistry'), 32, 'exclusionRegistry.version');
  const excludedAddresses = canonicalAddressList(required(exclusion, 'addresses', 'exclusionRegistry'), 'exclusionRegistry.addresses');
  const algorithmVersion = uint(required(input, 'algorithmVersion'), 32, 'algorithmVersion');
  if (algorithmVersion !== ALGORITHM_VERSION) throw new Error(`Unsupported stale algorithm version ${algorithmVersion}`);
  const commitmentVersion = uint(required(window, 'commitmentVersion', 'window'), 32, 'window.commitmentVersion');
  if (commitmentVersion === 0n) throw new Error('commitmentVersion must be nonzero');
  return {
    mode, chainId, compdToken, vault, distributor, rewardAsset, activationBlock, activationBlockHash,
    activationTimestamp, windowStart, windowEnd, firstEligibleWindowStart: firstEligible,
    exclusionVersion, excludedAddresses, algorithmVersion, commitmentVersion,
  };
}

export function nextEligibleWindowStart(activationTimestamp) {
  const timestamp = typeof activationTimestamp === 'bigint' ? activationTimestamp : uint(activationTimestamp, 64, 'activationTimestamp');
  const remainder = timestamp % WINDOW_SECONDS;
  return remainder === 0n ? timestamp : timestamp + (WINDOW_SECONDS - remainder);
}

function normalizeHeaders(input, replay) {
  const headers = required(replay, 'blockHeaders', 'replay');
  if (!Array.isArray(headers) || headers.length === 0) throw new Error('replay.blockHeaders must be a non-empty complete canonical header range');
  const normalized = headers.map((header, index) => ({
    number: uint(required(header, 'number', `blockHeaders[${index}]`), 256, 'block.number'),
    hash: normalizeHexHash(required(header, 'hash', `blockHeaders[${index}]`), 'block.hash'),
    parentHash: normalizeHexHash(required(header, 'parentHash', `blockHeaders[${index}]`), 'block.parentHash'),
    timestamp: uint(required(header, 'timestamp', `blockHeaders[${index}]`), 64, 'block.timestamp'),
  }));
  const start = uint(required(replay, 'startBlock', 'replay'), 256, 'replay.startBlock');
  const end = uint(required(replay, 'endBlock', 'replay'), 256, 'replay.endBlock');
  if (end < start || normalized[0].number !== start || normalized.at(-1).number !== end || BigInt(normalized.length) !== end - start + 1n) {
    throw new Error('Block header range must contain every canonical block from replay.startBlock through replay.endBlock');
  }
  for (let i = 1; i < normalized.length; i++) {
    if (normalized[i].number !== normalized[i - 1].number + 1n) throw new Error('Block header sequence contains a missing height');
    if (normalized[i].parentHash !== normalized[i - 1].hash) throw new Error(`Canonical parent-hash discontinuity at block ${normalized[i].number}`);
    if (normalized[i].timestamp < normalized[i - 1].timestamp) throw new Error(`Block timestamp regressed at ${normalized[i].number}`);
  }
  const checkpoint = required(input, 'checkpoint');
  const checkpointNumber = uint(required(checkpoint, 'blockNumber', 'checkpoint'), 256, 'checkpoint.blockNumber');
  const checkpointHash = normalizeHexHash(required(checkpoint, 'blockHash', 'checkpoint'), 'checkpoint.blockHash');
  const checkpointHeader = normalized.at(-1);
  if (checkpointNumber !== end || checkpointHeader.hash !== checkpointHash) throw new Error('Checkpoint number/hash does not match the final canonical header');
  if (checkpointHeader.timestamp < uint(required(input.window, 'end', 'window'), 64, 'window.end')) throw new Error('Replay checkpoint is before the target window end');
  const activationHeader = normalized.find(header => header.number === uint(input.activation.blockNumber, 256, 'activation.blockNumber'));
  if (!activationHeader || activationHeader.hash !== normalizeHexHash(input.activation.blockHash, 'activation.blockHash')
      || activationHeader.timestamp !== uint(input.activation.timestamp, 64, 'activation.timestamp')) {
    throw new Error('Activation block/hash/timestamp is not present as the stated canonical header');
  }
  const initial = required(replay, 'initialState', 'replay');
  const initialBlock = uint(required(initial, 'blockNumber', 'replay.initialState'), 256, 'initialState.blockNumber');
  const initialHash = normalizeHexHash(required(initial, 'blockHash', 'replay.initialState'), 'initialState.blockHash');
  if (start === 0n || initialBlock + 1n !== start || initialHash !== normalized[0].parentHash) {
    throw new Error('Initial balance snapshot must be pinned to the parent of replay.startBlock');
  }
  return { headers: normalized, byNumber: new Map(normalized.map(header => [header.number.toString(), header])), start, end, initial };
}

function normalizeEvents(replay, config, chain) {
  const raw = required(replay, 'transferEvents', 'replay');
  if (!Array.isArray(raw)) throw new TypeError('replay.transferEvents must be an array');
  const seen = new Set();
  const events = raw.map((event, index) => {
    const prefix = `transferEvents[${index}]`;
    const blockNumber = uint(required(event, 'blockNumber', prefix), 256, `${prefix}.blockNumber`);
    if (blockNumber < chain.start || blockNumber > chain.end) throw new Error(`${prefix} is outside replay block range`);
    const header = chain.byNumber.get(blockNumber.toString());
    const blockHash = normalizeHexHash(required(event, 'blockHash', prefix), `${prefix}.blockHash`);
    if (!header || header.hash !== blockHash) throw new Error(`${prefix} block hash does not match canonical header`);
    const token = addressHex(required(event, 'token', prefix), `${prefix}.token`, { allowZero: false });
    if (token !== config.compdToken) throw new Error(`${prefix} token does not match configured COMPD token`);
    const transactionIndex = uint(required(event, 'transactionIndex', prefix), 32, `${prefix}.transactionIndex`);
    const logIndex = uint(required(event, 'logIndex', prefix), 32, `${prefix}.logIndex`);
    const transactionHash = normalizeHexHash(required(event, 'transactionHash', prefix), `${prefix}.transactionHash`);
    const key = `${blockNumber}:${logIndex}`;
    if (seen.has(key)) throw new Error(`Duplicate Transfer event key ${key}`);
    seen.add(key);
    const from = addressHex(required(event, 'from', prefix), `${prefix}.from`);
    const to = addressHex(required(event, 'to', prefix), `${prefix}.to`);
    if (from === ZERO_ADDRESS && to === ZERO_ADDRESS) throw new Error(`${prefix} cannot mint and burn to the zero address in one event`);
    return { blockNumber, blockHash, transactionIndex, logIndex, transactionHash,
      timestamp: header.timestamp, token, from, to, value: uint(required(event, 'value', prefix), 256, `${prefix}.value`) };
  });
  events.sort((a, b) => a.blockNumber !== b.blockNumber ? (a.blockNumber < b.blockNumber ? -1 : 1)
    : a.transactionIndex !== b.transactionIndex ? (a.transactionIndex < b.transactionIndex ? -1 : 1)
      : a.logIndex !== b.logIndex ? (a.logIndex < b.logIndex ? -1 : 1) : 0);
  for (let i = 1; i < events.length; i++) {
    const current = events[i]; const previous = events[i - 1];
    if (current.blockNumber === previous.blockNumber && current.logIndex <= previous.logIndex) throw new Error('Block log indices are not strictly increasing');
    if (current.blockNumber === previous.blockNumber && current.transactionIndex < previous.transactionIndex) throw new Error('Transaction index regressed within block');
    if (current.blockNumber === previous.blockNumber && current.transactionIndex === previous.transactionIndex && current.logIndex <= previous.logIndex) throw new Error('Log index regressed within transaction');
  }
  return events;
}

function normalizeProfitAttributions(input, config, chain) {
  const raw = required(input, 'profitAttributions');
  if (!Array.isArray(raw)) throw new TypeError('profitAttributions must be an array');
  const ids = new Set();
  const records = raw.map((record, i) => {
    const prefix = `profitAttributions[${i}]`;
    if (required(record, 'sourceKind', prefix) !== 'RealizedProfitRouted') throw new Error('Holder pool input must reference canonical positive realized-profit routing, never Flap revenue');
    const blockNumber = uint(required(record, 'blockNumber', prefix), 256, `${prefix}.blockNumber`);
    const blockHash = normalizeHexHash(required(record, 'blockHash', prefix), `${prefix}.blockHash`);
    const header = chain.byNumber.get(blockNumber.toString());
    if (!header || header.hash !== blockHash) throw new Error(`${prefix} settlement block is not canonical in the replay bundle`);
    const transactionHash = normalizeHexHash(required(record, 'transactionHash', prefix), `${prefix}.transactionHash`);
    const logIndex = uint(required(record, 'logIndex', prefix), 32, `${prefix}.logIndex`);
    const id = `${blockNumber}:${logIndex}`;
    if (ids.has(id)) throw new Error(`Duplicate realized-profit attribution reference ${id}`);
    ids.add(id);
    const realizedProfit = uint(required(record, 'positiveRealizedProfit', prefix), 256, `${prefix}.positiveRealizedProfit`);
    if (realizedProfit === 0n) throw new Error(`${prefix} must represent strictly positive realized strategy profit`);
    const holderReward = uint(required(record, 'holderReward', prefix), 256, `${prefix}.holderReward`);
    if (realizedProfit * 1_000n >= (1n << 256n)) throw new RangeError(`${prefix} percentage multiplication would overflow the Vault's uint256 arithmetic`);
    const expectedHolderReward = realizedProfit * 1_000n / 10_000n;
    if (holderReward !== expectedHolderReward) throw new Error(`${prefix} Holder amount does not match the Vault's 10% floor calculation`);
    if (header.timestamp < config.windowStart || header.timestamp >= config.windowEnd) throw new Error(`${prefix} settlement is outside the target half-open UTC window`);
    return { blockNumber, blockHash, transactionHash, logIndex, timestamp: header.timestamp, positiveRealizedProfit: realizedProfit, holderReward };
  });
  records.sort((a, b) => a.blockNumber !== b.blockNumber ? (a.blockNumber < b.blockNumber ? -1 : 1)
    : a.logIndex !== b.logIndex ? (a.logIndex < b.logIndex ? -1 : 1)
      : a.transactionHash < b.transactionHash ? -1 : a.transactionHash > b.transactionHash ? 1 : 0);
  const windowPool = records.reduce((sum, record) => sum + record.holderReward, 0n);
  return { records, windowPool };
}

function validateAndReplay(input, config, chain, events) {
  const initialBalances = normalizeBalances(required(chain.initial, 'balances', 'replay.initialState'), 'replay.initialState.balances');
  const initialSupply = uint(required(chain.initial, 'totalSupply', 'replay.initialState'), 256, 'replay.initialState.totalSupply');
  const initialSum = [...initialBalances.values()].reduce((a, b) => a + b, 0n);
  if (initialSum !== initialSupply) throw new Error('Initial balances do not sum to initial total supply');
  const balances = new Map(initialBalances);
  let totalSupply = initialSupply;
  const integrals = new Map();
  const lastAccrued = new Map();
  const accrue = (address, timestamp) => {
    if (address === ZERO_ADDRESS) return;
    const previous = lastAccrued.get(address) ?? config.windowStart;
    if (timestamp < previous) throw new Error(`Nonmonotonic balance accrual for ${address}`);
    const balance = balances.get(address) ?? 0n;
    if (balance >= ELIGIBILITY_THRESHOLD) {
      const nextIntegral = (integrals.get(address) ?? 0n) + balance * (timestamp - previous);
      if (nextIntegral >= (1n << 256n)) throw new RangeError(`Eligible balance-time exceeds uint256 for ${address}`);
      integrals.set(address, nextIntegral);
    }
    lastAccrued.set(address, timestamp);
  };
  const accrueAllToEnd = () => { for (const address of balances.keys()) accrue(address, config.windowEnd); };
  const apply = event => {
    const value = event.value;
    if (event.from !== ZERO_ADDRESS && value !== 0n) {
      const before = balances.get(event.from) ?? 0n;
      if (before < value) throw new Error(`Impossible replay: negative balance for ${event.from} at block ${event.blockNumber}, log ${event.logIndex}`);
      if (event.from === event.to) return;
      const after = before - value;
      if (after === 0n) balances.delete(event.from); else balances.set(event.from, after);
    } else if (event.from === ZERO_ADDRESS) totalSupply += value;
    if (event.to !== ZERO_ADDRESS && value !== 0n && event.to !== event.from) {
      const after = (balances.get(event.to) ?? 0n) + value;
      if (after >= (1n << 256n)) throw new Error(`Impossible replay: uint256 balance overflow for ${event.to}`);
      balances.set(event.to, after);
    } else if (event.to === ZERO_ADDRESS) {
      if (event.from !== ZERO_ADDRESS) totalSupply -= value;
    }
    if (totalSupply >= (1n << 256n)) throw new Error('Impossible replay: uint256 total supply overflow');
  };

  let windowEndAccrued = false;
  for (const event of events) {
    if (event.timestamp <= config.windowStart) {
      apply(event);
      continue;
    }
    if (event.timestamp < config.windowEnd) {
      accrue(event.from, event.timestamp);
      if (event.to !== event.from) accrue(event.to, event.timestamp);
      apply(event);
      continue;
    }
    if (!windowEndAccrued) { accrueAllToEnd(); windowEndAccrued = true; }
    apply(event);
  }
  if (!windowEndAccrued) accrueAllToEnd();

  const checkpoint = required(input, 'checkpoint');
  const expectedSupply = uint(required(checkpoint, 'totalSupply'), 256, 'checkpoint.totalSupply');
  if (totalSupply !== expectedSupply) throw new Error('Replayed total supply differs from checkpoint totalSupply');
  const expectedBalances = normalizeBalances(required(checkpoint, 'balances'), 'checkpoint.balances');
  if (canonicalJson(mapToBalances(balances)) !== canonicalJson(mapToBalances(expectedBalances))) {
    throw new Error('Replayed address balances differ from the explicit checkpoint balance reconciliation');
  }
  const balanceSum = [...balances.values()].reduce((sum, value) => sum + value, 0n);
  if (balanceSum !== totalSupply) throw new Error('Replayed balances do not conserve checkpoint total supply');
  const excluded = new Set(config.excludedAddresses);
  return { balances, totalSupply, balanceTimeIntegrals: integrals, excluded };
}

function rankCompare(a, b) {
  if (a.weight !== b.weight) return a.weight > b.weight ? -1 : 1;
  const aa = BigInt(a.address); const bb = BigInt(b.address);
  return aa < bb ? -1 : aa > bb ? 1 : 0;
}

export function selectTop30(weightMap, excludedAddresses = []) {
  const excluded = new Set(canonicalAddressList(excludedAddresses, 'excludedAddresses'));
  const top = [];
  for (const [rawAddress, weight] of weightMap) {
    const address = addressHex(rawAddress, 'ranking.address', { allowZero: false });
    const parsedWeight = typeof weight === 'bigint' ? weight : uint(weight, 256, 'ranking.weight');
    if (parsedWeight >= (1n << 256n)) throw new RangeError('ranking weight exceeds canonical uint256 bound');
    if (excluded.has(address) || parsedWeight <= 0n) continue;
    const item = { address, weight: parsedWeight };
    let low = 0; let high = top.length;
    while (low < high) {
      const middle = (low + high) >>> 1;
      if (rankCompare(top[middle], item) <= 0) low = middle + 1; else high = middle;
    }
    top.splice(low, 0, item);
    if (top.length > MAX_RECIPIENTS) top.pop();
  }
  return top;
}

export function hamiltonAllocate(recipients, pool) {
  const amount = typeof pool === 'bigint' ? pool : uint(pool, 256, 'pool');
  if (amount < 0n || amount >= (1n << 256n)) throw new RangeError('pool is outside uint256');
  if (!Array.isArray(recipients)) throw new TypeError('recipients must be an array');
  if (recipients.length > MAX_RECIPIENTS) throw new RangeError('recipient count exceeds 30');
  const normalized = recipients.map((entry, index) => ({
    address: addressHex(entry.address, `recipients[${index}].address`, { allowZero: false }),
    weight: typeof entry.weight === 'bigint' ? entry.weight : uint(entry.weight, 256, `recipients[${index}].weight`),
  }));
  const seen = new Set();
  for (const entry of normalized) {
    if (entry.weight <= 0n) throw new RangeError('Hamilton weights must be positive');
    if (seen.has(entry.address)) throw new Error(`Duplicate Hamilton recipient ${entry.address}`);
    seen.add(entry.address);
  }
  if (amount === 0n || normalized.length === 0) return normalized.map(entry => ({ ...entry, quotient: 0n, remainder: 0n, payout: 0n }));
  const totalWeight = normalized.reduce((sum, entry) => sum + entry.weight, 0n);
  if (totalWeight >= (1n << 256n)) throw new RangeError('total eligible weight exceeds canonical uint256 bound');
  const allocated = normalized.map(entry => {
    const product = amount * entry.weight;
    return { ...entry, quotient: product / totalWeight, remainder: product % totalWeight, payout: product / totalWeight };
  });
  const floors = allocated.reduce((sum, entry) => sum + entry.quotient, 0n);
  const leftover = amount - floors;
  if (leftover < 0n || leftover >= BigInt(allocated.length)) throw new Error('Hamilton leftover invariant failed');
  const remainderOrder = [...allocated].sort((a, b) => a.remainder !== b.remainder
    ? (a.remainder > b.remainder ? -1 : 1)
    : (BigInt(a.address) < BigInt(b.address) ? -1 : BigInt(a.address) > BigInt(b.address) ? 1 : 0));
  for (let i = 0; i < Number(leftover); i++) remainderOrder[i].payout += 1n;
  if (allocated.reduce((sum, entry) => sum + entry.payout, 0n) !== amount) throw new Error('Hamilton conservation invariant failed');
  return allocated;
}

function domainFor(config) {
  return keccak256(abiEncode(['bytes32', 'bytes32', 'uint256', 'address', 'address', 'address', 'address'], [
    HASH_TYPES.domain, HASH_TYPES.protocolId, config.chainId, config.compdToken, config.vault, config.distributor, config.rewardAsset,
  ]));
}

function windowAndDistribution(config, domain) {
  const windowId = keccak256(abiEncode(['bytes32', 'bytes32', 'uint256', 'bytes32', 'uint64', 'uint64', 'uint64'], [
    HASH_TYPES.window, domain, config.activationBlock, config.activationBlockHash,
    config.activationTimestamp, config.windowStart, config.windowEnd,
  ]));
  const distributionId = keccak256(abiEncode(['bytes32', 'bytes32', 'bytes32'], [HASH_TYPES.distribution, domain, windowId]));
  return { windowId, distributionId };
}

function computeExclusionHash(config) {
  return keccak256(abiEncode(['bytes32', 'uint32', 'address[]'], [HASH_TYPES.exclusionSet, config.exclusionVersion, config.excludedAddresses]));
}

function computeEntriesHash(entries) {
  return keccak256(abiEncode(
    ['bytes32', 'uint16[]', 'address[]', 'uint256[]', 'uint256[]', 'uint256[]', 'uint256[]'],
    [HASH_TYPES.entries, entries.map((_, index) => BigInt(index)), entries.map(e => e.address),
      entries.map(e => e.weight), entries.map(e => e.quotient), entries.map(e => e.remainder), entries.map(e => e.payout)],
  ));
}

function computeDatasetHash(config, context, pool, totalPayable, entries, exclusionHash, checkpoint) {
  const entriesHash = computeEntriesHash(entries);
  const recipientCount = BigInt(entries.length);
  const hash = keccak256(abiEncode(
    ['bytes32', 'bytes32', 'bytes32', 'bytes32', 'uint64', 'uint64', 'uint256', 'uint256', 'uint16', 'uint32', 'uint32', 'bytes32', 'uint256', 'bytes32', 'uint64', 'uint256', 'uint256', 'bytes32', 'bytes32'],
    [HASH_TYPES.dataset, context.domainSeparator, context.distributionId, context.windowId,
      config.windowStart, config.windowEnd, pool, totalPayable, recipientCount, config.algorithmVersion,
      config.exclusionVersion, exclusionHash, config.activationBlock, config.activationBlockHash,
      config.activationTimestamp, checkpoint.startBlock, checkpoint.blockNumber, checkpoint.blockHash, entriesHash],
  ));
  return { entriesHash, datasetHash: hash };
}

export function leafHash(leaf) {
  return keccak256(abiEncode(
    ['bytes32', 'bytes32', 'bytes32', 'uint32', 'bytes32', 'uint64', 'uint64', 'address', 'uint256', 'uint256', 'uint16', 'address', 'uint256', 'bytes32', 'uint32'],
    [HASH_TYPES.leaf, leaf.domainSeparator, leaf.distributionId, leaf.commitmentVersion, leaf.windowId,
      leaf.windowStart, leaf.windowEnd, leaf.rewardAsset, leaf.windowPool, leaf.finalizedTotalPayable,
      leaf.recipientIndex, leaf.recipient, leaf.amount, leaf.datasetHash, leaf.algorithmVersion],
  ));
}

export function buildMerkle(config, context, entries, pool, totalPayable, datasetHash) {
  if (pool === 0n || entries.length === 0 || totalPayable === 0n) return { root: null, leaves: [], proofs: [] };
  const leaves = entries.map((entry, index) => ({
    domainSeparator: context.domainSeparator, distributionId: context.distributionId,
    commitmentVersion: config.commitmentVersion, windowId: context.windowId,
    windowStart: config.windowStart, windowEnd: config.windowEnd,
    rewardAsset: config.rewardAsset, windowPool: pool, finalizedTotalPayable: totalPayable,
    recipientIndex: BigInt(index), recipient: entry.address, amount: entry.payout,
    datasetHash, algorithmVersion: config.algorithmVersion,
  }));
  let width = 1;
  while (width < leaves.length) width <<= 1;
  let level = leaves.map(leafHash);
  for (let index = leaves.length; index < width; index++) {
    level.push(keccak256(abiEncode(['bytes32', 'bytes32', 'bytes32', 'uint32', 'uint16'], [
      HASH_TYPES.padding, context.domainSeparator, context.distributionId, config.commitmentVersion, BigInt(index),
    ])));
  }
  const proofs = leaves.map(() => []);
  let indices = leaves.map((_, i) => i);
  while (level.length > 1) {
    for (let i = 0; i < indices.length; i++) proofs[i].push(level[indices[i] ^ 1]);
    const next = [];
    for (let i = 0; i < level.length; i += 2) {
      next.push(keccak256(abiEncode(['bytes32', 'bytes32', 'bytes32'], [HASH_TYPES.node, level[i], level[i + 1]])));
    }
    indices = indices.map(index => Math.floor(index / 2));
    level = next;
  }
  return { root: level[0], leaves, proofs };
}

export function verifyPhase3Proof(leaf, proof, root, recipientCount) {
  if (root === null || !Array.isArray(proof)) return false;
  let width = 1;
  while (width < recipientCount) width *= 2;
  let depth = 0;
  while (width > 1) { width /= 2; depth++; }
  if (proof.length !== depth) return false;
  let value = leafHash(leaf);
  const index = Number(leaf.recipientIndex);
  for (let level = 0; level < proof.length; level++) {
    const sibling = bytes32Hex(proof[level], 'proof sibling');
    value = ((index >> level) & 1) === 0
      ? keccak256(abiEncode(['bytes32', 'bytes32', 'bytes32'], [HASH_TYPES.node, value, sibling]))
      : keccak256(abiEncode(['bytes32', 'bytes32', 'bytes32'], [HASH_TYPES.node, sibling, value]));
  }
  return value === root;
}

export function canonicalInputHash(normalizedInput) { return sha256Hex(canonicalJson(normalizedInput)); }

export function findReorg(previousHeaders, currentHeaders) {
  const current = new Map(currentHeaders.map(header => [String(header.number), bytes32Hex(header.hash)]));
  let common = null;
  for (const header of previousHeaders) {
    const height = String(header.number);
    if (current.has(height) && current.get(height) === bytes32Hex(header.hash)) common = BigInt(height);
  }
  const previousEnd = previousHeaders.reduce((max, h) => BigInt(h.number) > max ? BigInt(h.number) : max, -1n);
  const currentEnd = currentHeaders.reduce((max, h) => BigInt(h.number) > max ? BigInt(h.number) : max, -1n);
  if (common === previousEnd && currentEnd >= previousEnd) return { reorg: false, commonAncestorBlock: common.toString(), rollbackFromBlock: null };
  return { reorg: true, commonAncestorBlock: common === null ? null : common.toString(), rollbackFromBlock: common === null ? null : (common + 1n).toString() };
}

export function buildDataset(input) {
  const config = normalizeChain(input);
  const replay = required(input, 'replay');
  const chain = normalizeHeaders(input, replay);
  const events = normalizeEvents(replay, config, chain);
  const replayed = validateAndReplay(input, config, chain, events);
  const attribution = normalizeProfitAttributions(input, config, chain);
  const ranked = selectTop30(replayed.balanceTimeIntegrals, config.excludedAddresses);
  const totalEligibleWeight = ranked.reduce((sum, entry) => sum + entry.weight, 0n);
  if (totalEligibleWeight >= (1n << 256n)) throw new RangeError('Top-30 total eligible weight exceeds canonical uint256 bound');
  const allocated = hamiltonAllocate(ranked, attribution.windowPool);
  const totalPayable = ranked.length > 0 && attribution.windowPool > 0n ? attribution.windowPool : 0n;
  const domainSeparator = domainFor(config);
  const { windowId, distributionId } = windowAndDistribution(config, domainSeparator);
  const context = { domainSeparator, windowId, distributionId };
  const exclusionHash = computeExclusionHash(config);
  const checkpoint = { startBlock: chain.start, blockNumber: chain.end, blockHash: chain.headers.at(-1).hash };
  const { entriesHash, datasetHash } = computeDatasetHash(config, context, attribution.windowPool, totalPayable, allocated, exclusionHash, checkpoint);
  const merkle = buildMerkle(config, context, allocated, attribution.windowPool, totalPayable, datasetHash);
  if (merkle.root && !merkle.leaves.every((leaf, index) => verifyPhase3Proof(leaf, merkle.proofs[index], merkle.root, allocated.length))) {
    throw new Error('Internal Phase-3 Merkle proof self-check failed');
  }
  const positiveRecipientCount = BigInt(allocated.filter(entry => entry.payout > 0n).length);
  const unresolvedPool = attribution.windowPool > 0n && ranked.length === 0 ? attribution.windowPool : 0n;
  const exclusionData = {
    version: config.exclusionVersion.toString(),
    addresses: config.excludedAddresses,
    hash: exclusionHash,
  };
  const normalizedEvents = events.map(event => ({
    blockNumber: event.blockNumber.toString(), transactionIndex: event.transactionIndex.toString(), logIndex: event.logIndex.toString(),
    blockHash: event.blockHash, transactionHash: event.transactionHash, timestamp: event.timestamp.toString(),
    token: event.token, from: event.from, to: event.to, value: event.value.toString(),
  }));
  const normalizedHeaders = chain.headers.map(header => ({
    number: header.number.toString(), hash: header.hash, parentHash: header.parentHash, timestamp: header.timestamp.toString(),
  }));
  const dataset = {
    schemaVersion: SCHEMA_VERSION.toString(), algorithmVersion: config.algorithmVersion.toString(), commitmentVersion: config.commitmentVersion.toString(),
    mode: 'TEST_ONLY', chainId: config.chainId.toString(), compdToken: config.compdToken, vault: config.vault, distributor: config.distributor,
    domainSeparator, distributionId, windowId, window: { start: config.windowStart.toString(), end: config.windowEnd.toString(), semantics: '[start,end)' },
    replay: {
      startBlock: chain.start.toString(), endBlock: chain.end.toString(), checkpointBlock: chain.end.toString(),
      checkpointBlockHash: chain.headers.at(-1).hash, activation: { blockNumber: config.activationBlock.toString(), blockHash: config.activationBlockHash, timestamp: config.activationTimestamp.toString() },
      blockHeadersSha256: sha256Hex(canonicalJson(normalizedHeaders)), transferEventsSha256: sha256Hex(canonicalJson(normalizedEvents)),
      transferEventCount: String(events.length), finalityPolicy: required(input, 'finalityPolicy'),
    },
    exclusionRegistry: exclusionData,
    rewardAsset: config.rewardAsset,
    profitAttribution: {
      source: 'Vault RealizedProfitRouted / HolderPoolAccrued evidence; Flap revenue excluded',
      windowPool: attribution.windowPool.toString(),
      settlements: attribution.records.map(record => ({
        blockNumber: record.blockNumber.toString(), blockHash: record.blockHash, transactionHash: record.transactionHash,
        logIndex: record.logIndex.toString(), timestamp: record.timestamp.toString(),
        positiveRealizedProfit: record.positiveRealizedProfit.toString(), holderReward: record.holderReward.toString(),
      })),
    },
    totalEligibleTop30Weight: totalEligibleWeight.toString(),
    recipientCount: String(allocated.length), positiveRecipientCount: positiveRecipientCount.toString(),
    finalizedTotalPayable: totalPayable.toString(), unresolvedHolderPool: unresolvedPool.toString(),
    entries: allocated.map((entry, index) => ({
      index: String(index), rank: String(index + 1), address: entry.address, eligibleWeightBalanceSeconds: entry.weight.toString(),
      floorQuotient: entry.quotient.toString(), remainderNumerator: entry.remainder.toString(), payout: entry.payout.toString(),
    })),
    entriesHash, datasetHash,
    merkle: {
      root: merkle.root,
      leaves: merkle.leaves.map((leaf, index) => ({
        ...Object.fromEntries(Object.entries(leaf).map(([key, value]) => [key, typeof value === 'bigint' ? value.toString() : value])),
        leafHash: leafHash(leaf), proof: merkle.proofs[index],
      })),
    },
  };
  return { dataset, normalizedEvents, normalizedHeaders, replayed };
}

export function verifyInputBundle(input) {
  const result = buildDataset(input);
  return {
    ...result,
    datasetBytes: canonicalJson(result.dataset),
    inputBundleHash: canonicalInputHash(input),
    sourceManifest: {
      schemaVersion: '1', mode: 'TEST_ONLY', chainId: input.chainId,
      token: input.config.compdToken.toLowerCase(), replayStartBlock: input.replay.startBlock,
      replayEndBlock: input.replay.endBlock, activation: input.activation,
      checkpoint: input.checkpoint, orderedBlockHeaderHash: sha256Hex(canonicalJson(result.normalizedHeaders)),
      orderedTransferEventHash: sha256Hex(canonicalJson(result.normalizedEvents)),
      exclusionRegistry: result.dataset.exclusionRegistry, rewardAsset: input.rewardAsset.toLowerCase(),
      profitAttributions: result.dataset.profitAttribution.settlements, algorithmVersion: String(input.algorithmVersion),
      finalityPolicy: input.finalityPolicy, eventSource: input.eventSource,
      priorHeaderChain: result.normalizedHeaders,
    },
  };
}
