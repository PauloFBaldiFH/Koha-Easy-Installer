// IPv4 / IPv6 CIDR matching for the optional staff IP allowlist.

export interface ParsedIp {
  v: 4 | 6;
  n: bigint;
}

export function parseIp(ip: string): ParsedIp | null {
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(ip)) {
    const parts = ip.split(".").map(Number);
    if (parts.some((p) => p > 255)) return null;
    return { v: 4, n: parts.reduce((acc, p) => (acc << 8n) | BigInt(p), 0n) };
  }
  if (!ip.includes(":") || !/^[0-9a-fA-F:]+$/.test(ip)) return null;
  const halves = ip.split("::");
  if (halves.length > 2) return null;
  const head = halves[0] ? halves[0].split(":") : [];
  const tail = halves.length === 2 && halves[1] ? halves[1].split(":") : [];
  const missing = 8 - head.length - tail.length;
  if (halves.length === 1 ? missing !== 0 : missing < 1) return null;
  const groups = [...head, ...Array<string>(halves.length === 2 ? missing : 0).fill("0"), ...tail];
  if (groups.length !== 8 || groups.some((g) => !/^[0-9a-fA-F]{1,4}$/.test(g))) return null;
  return { v: 6, n: groups.reduce((acc, g) => (acc << 16n) | BigInt(parseInt(g, 16)), 0n) };
}

export interface Cidr {
  v: 4 | 6;
  base: bigint;
  bits: number;
}

export function parseCidr(cidr: string): Cidr | null {
  const [addr, len, ...rest] = cidr.trim().split("/");
  if (rest.length || !addr) return null;
  const ip = parseIp(addr);
  if (!ip) return null;
  const width = ip.v === 4 ? 32 : 128;
  const bits = len === undefined ? width : /^\d{1,3}$/.test(len) ? Number(len) : NaN;
  if (!(bits >= 0 && bits <= width)) return null;
  const mask = bits === 0 ? 0n : ((1n << BigInt(bits)) - 1n) << BigInt(width - bits);
  return { v: ip.v, base: ip.n & mask, bits };
}

export function ipInCidr(ip: string, cidr: Cidr): boolean {
  const p = parseIp(ip);
  if (!p || p.v !== cidr.v) return false;
  const width = p.v === 4 ? 32 : 128;
  const mask = cidr.bits === 0 ? 0n : ((1n << BigInt(cidr.bits)) - 1n) << BigInt(width - cidr.bits);
  return (p.n & mask) === cidr.base;
}

export function ipAllowed(ip: string, cidrs: string[]): boolean {
  return cidrs.some((c) => {
    const parsed = parseCidr(c);
    return parsed !== null && ipInCidr(ip, parsed);
  });
}
