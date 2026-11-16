// Bounded, SSRF-guarded download of an ICS feed (spec/mcp.md 9.4).
// Error messages never contain the URL: they end up in lastStats and logs, and feed URLs are secrets.
import { IcsError } from './types';

export const FETCH_TIMEOUT_MS = 30_000;
export const MAX_ICS_BYTES = 8 * 1024 * 1024;
export const MAX_REDIRECTS = 3;

const REDIRECT_STATUSES = new Set([301, 302, 303, 307, 308]);

/**
 * Parses ICS_ALLOW_INSECURE_HOSTS (comma separated hostnames, e.g. `127.0.0.1`). Only honored in
 * development builds so that production can never be talked into fetching internal hosts.
 */
export function parseInsecureHosts(
  raw: string | undefined,
  isDev: boolean = import.meta.env.DEV,
): string[] {
  if (!import.meta.env.DEV || !isDev || !raw) return [];
  return raw
    .split(',')
    .map((h) => normalizeHost(h))
    .filter((h) => h.length > 0);
}

function normalizeHost(host: string): string {
  let h = host.trim().toLowerCase();
  if (h.startsWith('[') && h.endsWith(']')) h = h.slice(1, -1);
  if (h.endsWith('.')) h = h.slice(0, -1);
  return h;
}

function blockedIpv4(a: number, b: number): boolean {
  return (
    a === 0 || // 0.0.0.0/8
    a === 10 ||
    (a === 100 && b >= 64 && b <= 127) || // CGNAT
    a === 127 ||
    (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168) ||
    a >= 224 // multicast and reserved
  );
}

/** Expands a normalized IPv6 literal (URL parsing already turned embedded IPv4 into hex) to 8 groups. */
function parseIpv6(host: string): number[] | null {
  const halves = host.split('::');
  if (halves.length > 2) return null;
  const toGroups = (s: string): number[] | null => {
    if (s === '') return [];
    const groups = s.split(':').map((g) => (/^[0-9a-f]{1,4}$/.test(g) ? parseInt(g, 16) : NaN));
    return groups.some(Number.isNaN) ? null : groups;
  };
  const head = toGroups(halves[0] ?? '');
  if (!head) return null;
  if (halves.length === 1) return head.length === 8 ? head : null;
  const tail = toGroups(halves[1] ?? '');
  if (!tail || head.length + tail.length > 7) return null;
  return [...head, ...Array.from({ length: 8 - head.length - tail.length }, () => 0), ...tail];
}

function blockedIpv6(host: string): boolean {
  const g = parseIpv6(host);
  if (!g) return true;
  const [g0, g1, g2, g3, g4, g5, g6] = g as [number, number, number, number, number, number, number, number];
  // The first IPv4 octets live in the high group; only they decide the range.
  const embedded = (hi: number) => blockedIpv4(hi >> 8, hi & 0xff);
  if (g0 === 0 && g1 === 0 && g2 === 0 && g3 === 0 && g4 === 0) {
    // ::/96 (unspecified, loopback, IPv4-compatible) and ::ffff:0:0/96 (IPv4-mapped).
    if (g5 === 0) return true;
    if (g5 === 0xffff) return embedded(g6);
  }
  if (g0 === 0x64 && g1 === 0xff9b && g2 === 0 && g3 === 0 && g4 === 0 && g5 === 0) {
    return embedded(g6); // NAT64
  }
  if (g0 === 0x2002) return embedded(g1); // 6to4
  if ((g0 & 0xfe00) === 0xfc00) return true; // fc00::/7 unique local
  if ((g0 & 0xffc0) === 0xfe80 || (g0 & 0xffc0) === 0xfec0) return true; // link-local, site-local
  if ((g0 & 0xff00) === 0xff00) return true; // multicast
  return false;
}

function hostBlocked(host: string): boolean {
  if (host === 'localhost' || host.endsWith('.localhost')) return true;
  if (host.endsWith('.local') || host.endsWith('.internal')) return true;
  if (host.includes(':')) return blockedIpv6(host);
  const v4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host);
  if (v4) return blockedIpv4(Number(v4[1]), Number(v4[2]));
  return false;
}

/**
 * Validates a feed URL and returns the URL to fetch (`webcal:` becomes `https:`). Checks the parsed
 * hostname, so `127.1`, `0x7f.1` and `2130706433` are seen as the loopback address they are.
 * Hosts in `insecureHosts` skip the https and address checks (development only, see parseInsecureHosts).
 */
export function assertFetchableUrl(raw: string, insecureHosts: readonly string[] = []): URL {
  let url: URL;
  try {
    url = new URL(raw.trim().replace(/^webcal:/i, 'https:'));
  } catch {
    throw new IcsError('ICS URL is not a valid URL');
  }
  const host = normalizeHost(url.hostname);
  if (insecureHosts.includes(host) && (url.protocol === 'http:' || url.protocol === 'https:')) return url;
  if (url.protocol !== 'https:') throw new IcsError('ICS URL must use https');
  if (host === '' || hostBlocked(host)) throw new IcsError('ICS URL host is not allowed');
  return url;
}

export interface FetchIcsOptions {
  insecureHosts?: readonly string[];
  timeoutMs?: number;
  /** Injected in tests. */
  fetch?: typeof fetch;
}

/**
 * Fetches raw ICS text. Redirects are followed by hand (at most MAX_REDIRECTS) and every hop is
 * validated again; one timeout covers the whole chain including the body read.
 */
export async function fetchIcs(rawUrl: string, options: FetchIcsOptions = {}): Promise<string> {
  const insecureHosts = options.insecureHosts ?? [];
  const doFetch = options.fetch ?? fetch;
  let url = assertFetchableUrl(rawUrl, insecureHosts);
  const signal = AbortSignal.timeout(options.timeoutMs ?? FETCH_TIMEOUT_MS);
  try {
    for (let hops = 0; ; hops++) {
      const resp = await doFetch(url.toString(), {
        redirect: 'manual',
        signal,
        headers: { 'User-Agent': 'DayDo-ICS-Sync/1.0', Accept: 'text/calendar, */*' },
      });
      if (REDIRECT_STATUSES.has(resp.status)) {
        await resp.body?.cancel();
        const location = resp.headers.get('Location');
        if (!location) throw new IcsError(`Failed to fetch ICS: HTTP ${resp.status} without Location`);
        if (hops >= MAX_REDIRECTS) throw new IcsError('Failed to fetch ICS: too many redirects');
        let next: string;
        try {
          next = new URL(location, url).toString();
        } catch {
          throw new IcsError('Failed to fetch ICS: invalid redirect location');
        }
        url = assertFetchableUrl(next, insecureHosts);
        continue;
      }
      if (!resp.ok) {
        await resp.body?.cancel();
        throw new IcsError(`Failed to fetch ICS: HTTP ${resp.status}`);
      }
      const contentLength = resp.headers.get('Content-Length');
      if (contentLength && Number(contentLength) > MAX_ICS_BYTES) {
        await resp.body?.cancel();
        throw new IcsError(`ICS feed too large (${contentLength} bytes)`);
      }
      const text = await readCapped(resp);
      if (text.trim() === '') throw new IcsError('Empty ICS body');
      return text;
    }
  } catch (e) {
    if (e instanceof IcsError) throw e;
    if (signal.aborted) throw new IcsError('Failed to fetch ICS: timed out');
    throw new IcsError('Failed to fetch ICS');
  }
}

/** Reads the body, aborting as soon as it exceeds MAX_ICS_BYTES instead of buffering it all. */
async function readCapped(resp: Response): Promise<string> {
  const reader = resp.body?.getReader();
  if (!reader) return '';
  const decoder = new TextDecoder();
  let text = '';
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_ICS_BYTES) {
      await reader.cancel();
      throw new IcsError('ICS feed too large');
    }
    text += decoder.decode(value, { stream: true });
  }
  return text + decoder.decode();
}
