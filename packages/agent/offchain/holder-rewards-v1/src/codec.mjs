import { createHash } from 'node:crypto';

const MASK_64 = (1n << 64n) - 1n;
const RATE = 136;
const ROTATION = [
  0, 1, 62, 28, 27,
  36, 44, 6, 55, 20,
  3, 10, 43, 25, 39,
  41, 45, 15, 21, 8,
  18, 2, 61, 56, 14,
];
const ROUND_CONSTANTS = [
  0x0000000000000001n, 0x0000000000008082n, 0x800000000000808an, 0x8000000080008000n,
  0x000000000000808bn, 0x0000000080000001n, 0x8000000080008081n, 0x8000000000008009n,
  0x000000000000008an, 0x0000000000000088n, 0x0000000080008009n, 0x000000008000000an,
  0x000000008000808bn, 0x800000000000008bn, 0x8000000000008089n, 0x8000000000008003n,
  0x8000000000008002n, 0x8000000000000080n, 0x000000000000800an, 0x800000008000000an,
  0x8000000080008081n, 0x8000000000008080n, 0x0000000080000001n, 0x8000000080008008n,
];

function rotateLeft64(value, shift) {
  if (shift === 0) return value & MASK_64;
  const n = BigInt(shift);
  return ((value << n) | (value >> (64n - n))) & MASK_64;
}

function permutation(state) {
  for (const roundConstant of ROUND_CONSTANTS) {
    const c = new Array(5);
    const d = new Array(5);
    for (let x = 0; x < 5; x++) c[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20];
    for (let x = 0; x < 5; x++) d[x] = c[(x + 4) % 5] ^ rotateLeft64(c[(x + 1) % 5], 1);
    for (let y = 0; y < 5; y++) for (let x = 0; x < 5; x++) state[x + 5 * y] = (state[x + 5 * y] ^ d[x]) & MASK_64;

    const b = new Array(25).fill(0n);
    for (let y = 0; y < 5; y++) {
      for (let x = 0; x < 5; x++) {
        const destination = y + 5 * ((2 * x + 3 * y) % 5);
        b[destination] = rotateLeft64(state[x + 5 * y], ROTATION[x + 5 * y]);
      }
    }
    for (let y = 0; y < 5; y++) {
      for (let x = 0; x < 5; x++) {
        state[x + 5 * y] = (b[x + 5 * y] ^ ((~b[(x + 1) % 5 + 5 * y]) & b[(x + 2) % 5 + 5 * y])) & MASK_64;
      }
    }
    state[0] ^= roundConstant;
  }
}

function asBytes(value) {
  if (value instanceof Uint8Array) return value;
  if (typeof value === 'string') return new TextEncoder().encode(value);
  throw new TypeError('Expected bytes or string');
}

function absorbBlock(state, block) {
  for (let i = 0; i < RATE; i++) {
    const lane = Math.floor(i / 8);
    const shift = BigInt(i % 8) * 8n;
    state[lane] ^= BigInt(block[i]) << shift;
  }
  permutation(state);
}

/** Ethereum Keccak-256 (legacy Keccak padding, not NIST SHA3-256). */
export function keccak256(value) {
  const bytes = asBytes(value);
  const state = new Array(25).fill(0n);
  let offset = 0;
  while (offset + RATE <= bytes.length) {
    absorbBlock(state, bytes.subarray(offset, offset + RATE));
    offset += RATE;
  }
  const last = new Uint8Array(RATE);
  last.set(bytes.subarray(offset));
  last[bytes.length - offset] ^= 0x01;
  last[RATE - 1] ^= 0x80;
  absorbBlock(state, last);

  const output = new Uint8Array(32);
  for (let i = 0; i < output.length; i++) output[i] = Number((state[Math.floor(i / 8)] >> (BigInt(i % 8) * 8n)) & 0xffn);
  return `0x${Buffer.from(output).toString('hex')}`;
}

export function sha256Hex(value) {
  return `0x${createHash('sha256').update(asBytes(value)).digest('hex')}`;
}

export function bytes32Hex(value, name = 'bytes32') {
  if (typeof value !== 'string' || !/^0x[0-9a-fA-F]{64}$/.test(value)) throw new TypeError(`${name} must be 32-byte hex`);
  return value.toLowerCase();
}

export function addressHex(value, name = 'address', { allowZero = true } = {}) {
  if (typeof value !== 'string' || !/^0x[0-9a-fA-F]{40}$/.test(value)) throw new TypeError(`${name} must be a 20-byte hex address`);
  const normalized = value.toLowerCase();
  if (!allowZero && normalized === `0x${'0'.repeat(40)}`) throw new RangeError(`${name} cannot be zero`);
  return normalized;
}

export function uint(value, bits = 256, name = `uint${bits}`) {
  if (typeof value !== 'string' && typeof value !== 'bigint' && typeof value !== 'number') throw new TypeError(`${name} must be an integer`);
  if (typeof value === 'number' && !Number.isSafeInteger(value)) throw new RangeError(`${name} numeric value is not safe; use a decimal string`);
  if (typeof value === 'string' && !/^(0|[1-9][0-9]*)$/.test(value)) throw new TypeError(`${name} must be a canonical unsigned decimal integer`);
  const parsed = BigInt(value);
  if (parsed < 0n || parsed >= (1n << BigInt(bits))) throw new RangeError(`${name} is outside uint${bits}`);
  return parsed;
}

function wordFromBigInt(value) {
  let hex = value.toString(16);
  if (hex.length > 64) throw new RangeError('ABI integer exceeds 32 bytes');
  hex = hex.padStart(64, '0');
  return Buffer.from(hex, 'hex');
}

function encodeStatic(type, value) {
  if (type === 'bytes32') return Buffer.from(bytes32Hex(value).slice(2), 'hex');
  if (type === 'address') return wordFromBigInt(BigInt(addressHex(value)));
  const match = /^uint(8|16|32|64|128|256)$/.exec(type);
  if (match) return wordFromBigInt(uint(value, Number(match[1]), type));
  throw new TypeError(`Unsupported ABI type: ${type}`);
}

/** Narrow-scope ABI encoder for static values and dynamic arrays of static values. */
export function abiEncode(types, values) {
  if (!Array.isArray(types) || !Array.isArray(values) || types.length !== values.length) throw new TypeError('ABI types/values length mismatch');
  const heads = [];
  const tails = [];
  let tailOffset = 32 * types.length;
  for (let i = 0; i < types.length; i++) {
    const arrayType = /^(bytes32|address|uint8|uint16|uint32|uint64|uint128|uint256)\[\]$/.exec(types[i]);
    if (!arrayType) {
      heads.push(encodeStatic(types[i], values[i]));
      continue;
    }
    const items = values[i];
    if (!Array.isArray(items)) throw new TypeError(`${types[i]} value must be an array`);
    const elementType = arrayType[1];
    const encodedArray = Buffer.concat([wordFromBigInt(BigInt(items.length)), ...items.map(item => encodeStatic(elementType, item))]);
    heads.push(wordFromBigInt(BigInt(tailOffset)));
    tails.push(encodedArray);
    tailOffset += encodedArray.length;
  }
  return Buffer.concat([...heads, ...tails]);
}

export function canonicalJson(value) {
  const normalize = input => {
    if (Array.isArray(input)) return input.map(normalize);
    if (input && typeof input === 'object') {
      const output = {};
      for (const key of Object.keys(input).sort()) output[key] = normalize(input[key]);
      return output;
    }
    if (typeof input === 'number' && !Number.isSafeInteger(input)) throw new RangeError('Canonical JSON forbids floating point or unsafe numbers');
    if (typeof input === 'bigint') throw new TypeError('Canonical JSON requires integers to be decimal strings');
    return input;
  };
  return JSON.stringify(normalize(value));
}
