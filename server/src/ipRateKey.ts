/** Parses an IPv6 address into its eight 16-bit groups, or null when it is not one. */
function ipv6Groups(ip: string): number[] | null {
  const halves = ip.split('::');
  if (halves.length > 2) return null;
  const parse = (part: string): number[] | null => {
    if (part === '') return [];
    const out: number[] = [];
    const pieces = part.split(':');
    for (const [i, piece] of pieces.entries()) {
      // An embedded IPv4 tail (e.g. ::ffff:1.2.3.4) fills the last two groups.
      if (i === pieces.length - 1 && piece.includes('.')) {
        const octets = piece.split('.').map(Number);
        if (octets.length !== 4 || octets.some((o) => !Number.isInteger(o) || o < 0 || o > 255)) return null;
        out.push((octets[0] << 8) | octets[1], (octets[2] << 8) | octets[3]);
      } else if (/^[0-9a-f]{1,4}$/.test(piece)) {
        out.push(parseInt(piece, 16));
      } else {
        return null;
      }
    }
    return out;
  };
  const head = parse(halves[0]);
  const tail = halves.length === 2 ? parse(halves[1]) : [];
  if (!head || !tail) return null;
  if (halves.length === 1) return head.length === 8 ? head : null;
  const fill = 8 - head.length - tail.length;
  return fill >= 1 ? [...head, ...Array<number>(fill).fill(0), ...tail] : null;
}

/**
 * Rate-limit key for a client address (CF-Connecting-IP): IPv4 as is, IPv6 reduced to its /64
 * (one host usually owns a whole /64), `local` without the header (dev builds).
 */
export function ipRateKey(ip: string | null): string {
  if (!ip) return 'local';
  if (!ip.includes(':')) return ip;
  const lower = ip.toLowerCase();
  const groups = ipv6Groups(lower);
  if (!groups) return lower;
  return `${groups
    .slice(0, 4)
    .map((g) => g.toString(16))
    .join(':')}::/64`;
}
