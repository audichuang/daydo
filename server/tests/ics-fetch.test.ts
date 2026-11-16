import { describe, expect, it, vi } from 'vitest';
import {
  assertFetchableUrl,
  fetchIcs,
  FETCH_TIMEOUT_MS,
  MAX_ICS_BYTES,
  MAX_REDIRECTS,
  parseInsecureHosts,
} from '../src/ics/fetch';
import { IcsError } from '../src/ics/types';

const ICS = 'BEGIN:VCALENDAR\r\nEND:VCALENDAR';

function mockFetch(...responses: Array<Response | Error>) {
  const queue = [...responses];
  const calls: Array<{ url: string; init: RequestInit }> = [];
  const impl = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(url), init: init ?? {} });
    const next = queue.shift();
    if (!next) throw new Error('unexpected fetch');
    if (next instanceof Error) throw next;
    return next;
  }) as unknown as typeof fetch;
  return { impl, calls };
}

const redirect = (location: string | null, status = 302) =>
  new Response(null, { status, headers: location === null ? {} : { Location: location } });

describe('assertFetchableUrl', () => {
  const blocked = [
    'https://127.0.0.1/a.ics',
    'https://127.1/a.ics',
    'https://0x7f.0.0.1/a.ics',
    'https://2130706433/a.ics',
    'https://10.0.0.5/a.ics',
    'https://172.16.0.1/a.ics',
    'https://172.31.255.255/a.ics',
    'https://192.168.1.1/a.ics',
    'https://169.254.169.254/latest/meta-data',
    'https://100.64.0.1/a.ics',
    'https://100.127.255.255/a.ics',
    'https://0.0.0.0/a.ics',
    'https://0.1.2.3/a.ics',
    'https://[::1]/a.ics',
    'https://[::]/a.ics',
    'https://[fc00::1]/a.ics',
    'https://[fd12:3456::1]/a.ics',
    'https://[fe80::1]/a.ics',
    'https://[::ffff:127.0.0.1]/a.ics',
    'https://[::ffff:10.0.0.1]/a.ics',
    'https://[64:ff9b::7f00:1]/a.ics',
    'https://[2002:7f00:1::]/a.ics',
    'https://localhost/a.ics',
    'https://LOCALHOST/a.ics',
    'https://localhost./a.ics',
    'https://printer.local/a.ics',
    'https://db.corp.internal/a.ics',
    'https://app.localhost/a.ics',
  ];
  it.each(blocked)('rejects %s', (url) => {
    expect(() => assertFetchableUrl(url)).toThrow(IcsError);
    expect(() => assertFetchableUrl(url)).toThrow(/not allowed/);
  });

  const allowed = [
    'https://cal.example.com/a.ics',
    'https://8.8.8.8/a.ics',
    'https://1.2.3.4/a.ics',
    'https://100.63.255.255/a.ics',
    'https://100.128.0.1/a.ics',
    'https://172.15.0.1/a.ics',
    'https://172.32.0.1/a.ics',
    'https://[2606:4700::1111]/a.ics',
    'https://[::ffff:8.8.8.8]/a.ics',
  ];
  it.each(allowed)('accepts %s', (url) => {
    expect(assertFetchableUrl(url).protocol).toBe('https:');
  });

  it('rejects non-https schemes', () => {
    for (const url of ['http://cal.example.com/a.ics', 'ftp://cal.example.com/a.ics', 'file:///etc/passwd']) {
      expect(() => assertFetchableUrl(url)).toThrow(/must use https/);
    }
  });

  it('turns webcal into https and still checks the host', () => {
    expect(assertFetchableUrl('webcal://cal.example.com/a.ics?k=1').toString()).toBe(
      'https://cal.example.com/a.ics?k=1',
    );
    expect(assertFetchableUrl('WEBCAL://cal.example.com/a.ics').protocol).toBe('https:');
    expect(() => assertFetchableUrl('webcal://127.0.0.1/a.ics')).toThrow(/not allowed/);
  });

  it('rejects text that is not a URL without echoing it', () => {
    expect(() => assertFetchableUrl('not a url secret-token')).toThrow(/not a valid URL/);
    try {
      assertFetchableUrl('not a url secret-token');
    } catch (e) {
      expect((e as Error).message).not.toContain('secret-token');
    }
  });

  it('lets insecure hosts through on http and on private addresses', () => {
    expect(assertFetchableUrl('http://127.0.0.1:8123/a.ics', ['127.0.0.1']).hostname).toBe('127.0.0.1');
    expect(() => assertFetchableUrl('http://127.0.0.2:8123/a.ics', ['127.0.0.1'])).toThrow(/must use https/);
    expect(() => assertFetchableUrl('https://10.0.0.1/a.ics', ['127.0.0.1'])).toThrow(/not allowed/);
  });
});

describe('parseInsecureHosts', () => {
  it('splits, trims and lowercases in development builds', () => {
    expect(parseInsecureHosts(' 127.0.0.1 , Localhost,, [::1] ', true)).toEqual(['127.0.0.1', 'localhost', '::1']);
  });

  it('is ignored when the build is not a development build', () => {
    expect(parseInsecureHosts('127.0.0.1', false)).toEqual([]);
  });

  it('returns nothing without a value', () => {
    expect(parseInsecureHosts(undefined, true)).toEqual([]);
    expect(parseInsecureHosts('', true)).toEqual([]);
  });
});

describe('fetchIcs', () => {
  it('returns the body and sends manual redirect, a signal and a user agent', async () => {
    const { impl, calls } = mockFetch(new Response(ICS, { status: 200 }));
    expect(await fetchIcs('https://cal.example.com/a.ics', { fetch: impl })).toBe(ICS);
    expect(calls).toHaveLength(1);
    expect(calls[0]!.url).toBe('https://cal.example.com/a.ics');
    expect(calls[0]!.init.redirect).toBe('manual');
    expect(calls[0]!.init.signal).toBeInstanceOf(AbortSignal);
    expect((calls[0]!.init.headers as Record<string, string>)['User-Agent']).toMatch(/DayDo/);
  });

  it('fetches webcal feeds over https', async () => {
    const { impl, calls } = mockFetch(new Response(ICS));
    await fetchIcs('webcal://cal.example.com/a.ics', { fetch: impl });
    expect(calls[0]!.url).toBe('https://cal.example.com/a.ics');
  });

  it('never calls fetch for a rejected URL', async () => {
    const { impl } = mockFetch(new Response(ICS));
    await expect(fetchIcs('http://cal.example.com/a.ics', { fetch: impl })).rejects.toThrow(/must use https/);
    await expect(fetchIcs('https://169.254.169.254/x', { fetch: impl })).rejects.toThrow(/not allowed/);
    expect(impl).not.toHaveBeenCalled();
  });

  it('follows relative and absolute redirects and re-checks each hop', async () => {
    const { impl, calls } = mockFetch(
      redirect('/b.ics', 301),
      redirect('https://other.example.com/c.ics', 307),
      new Response(ICS),
    );
    expect(await fetchIcs('https://cal.example.com/a.ics', { fetch: impl })).toBe(ICS);
    expect(calls.map((c) => c.url)).toEqual([
      'https://cal.example.com/a.ics',
      'https://cal.example.com/b.ics',
      'https://other.example.com/c.ics',
    ]);
    expect(calls.every((c) => c.init.redirect === 'manual')).toBe(true);
  });

  it('follows exactly MAX_REDIRECTS redirects and rejects one more', async () => {
    expect(MAX_REDIRECTS).toBe(3);
    const ok = mockFetch(redirect('/1'), redirect('/2'), redirect('/3'), new Response(ICS));
    expect(await fetchIcs('https://cal.example.com/a.ics', { fetch: ok.impl })).toBe(ICS);

    const tooMany = mockFetch(redirect('/1'), redirect('/2'), redirect('/3'), redirect('/4'), new Response(ICS));
    await expect(fetchIcs('https://cal.example.com/a.ics', { fetch: tooMany.impl })).rejects.toThrow(
      /too many redirects/,
    );
    expect(tooMany.calls).toHaveLength(4);
  });

  it.each([
    ['private IPv4', 'https://10.0.0.1/a.ics', /not allowed/],
    ['metadata address', 'http://169.254.169.254/latest', /must use https/],
    ['localhost', 'https://localhost/a.ics', /not allowed/],
    ['IPv6 loopback', 'https://[::1]/a.ics', /not allowed/],
    ['downgrade to http', 'http://cal.example.com/a.ics', /must use https/],
  ])('rejects a redirect to %s without following it', async (_name, target, message) => {
    const { impl, calls } = mockFetch(redirect(target), new Response(ICS));
    await expect(fetchIcs('https://cal.example.com/a.ics', { fetch: impl })).rejects.toThrow(message);
    expect(calls).toHaveLength(1);
  });

  it('rejects a redirect without Location', async () => {
    const { impl } = mockFetch(redirect(null));
    await expect(fetchIcs('https://cal.example.com/a.ics', { fetch: impl })).rejects.toThrow(/without Location/);
  });

  it('applies the insecure host list to redirect hops too', async () => {
    const insecureHosts = ['127.0.0.1'];
    const ok = mockFetch(redirect('http://127.0.0.1:9000/b.ics'), new Response(ICS));
    expect(await fetchIcs('http://127.0.0.1:9000/a.ics', { fetch: ok.impl, insecureHosts })).toBe(ICS);

    const bad = mockFetch(redirect('http://10.0.0.1/b.ics'), new Response(ICS));
    await expect(fetchIcs('http://127.0.0.1:9000/a.ics', { fetch: bad.impl, insecureHosts })).rejects.toThrow(
      /must use https/,
    );
    expect(bad.calls).toHaveLength(1);
  });

  it('reports non-OK statuses and empty bodies', async () => {
    const notFound = mockFetch(new Response('nope', { status: 404 }));
    await expect(fetchIcs('https://cal.example.com/a.ics', { fetch: notFound.impl })).rejects.toThrow(/HTTP 404/);
    const empty = mockFetch(new Response('   '));
    await expect(fetchIcs('https://cal.example.com/a.ics', { fetch: empty.impl })).rejects.toThrow(/Empty ICS body/);
  });

  it('times out a request that never answers', async () => {
    const hang = vi.fn(
      (_url: string | URL | Request, init?: RequestInit) =>
        new Promise<Response>((_resolve, reject) => {
          init?.signal?.addEventListener('abort', () => reject(init.signal?.reason));
        }),
    ) as unknown as typeof fetch;
    await expect(fetchIcs('https://cal.example.com/a.ics', { fetch: hang, timeoutMs: 20 })).rejects.toThrow(
      /timed out/,
    );
  });

  it('uses a 30 second timeout by default', async () => {
    expect(FETCH_TIMEOUT_MS).toBe(30_000);
    const timeout = vi.spyOn(AbortSignal, 'timeout');
    try {
      const { impl } = mockFetch(new Response(ICS));
      await fetchIcs('https://cal.example.com/a.ics', { fetch: impl });
      expect(timeout).toHaveBeenCalledWith(30_000);
    } finally {
      timeout.mockRestore();
    }
  });

  it('rejects a Content-Length above 8 MiB', async () => {
    expect(MAX_ICS_BYTES).toBe(8 * 1024 * 1024);
    const { impl } = mockFetch(
      new Response(ICS, { headers: { 'Content-Length': String(MAX_ICS_BYTES + 1) } }),
    );
    await expect(fetchIcs('https://cal.example.com/a.ics', { fetch: impl })).rejects.toThrow(/too large/);
  });

  it('stops reading a stream that lies about its size', async () => {
    const chunk = new Uint8Array(1024 * 1024).fill(65);
    let pulled = 0;
    let cancelled = false;
    const body = new ReadableStream<Uint8Array>({
      pull(controller) {
        pulled++;
        controller.enqueue(chunk);
      },
      cancel() {
        cancelled = true;
      },
    });
    const { impl } = mockFetch(new Response(body));
    await expect(fetchIcs('https://cal.example.com/a.ics', { fetch: impl })).rejects.toThrow(/too large/);
    expect(cancelled).toBe(true);
    expect(pulled).toBeLessThan(12);
  });

  it('accepts a body of exactly 8 MiB', async () => {
    const { impl } = mockFetch(new Response(new Uint8Array(MAX_ICS_BYTES).fill(65)));
    expect((await fetchIcs('https://cal.example.com/a.ics', { fetch: impl })).length).toBe(MAX_ICS_BYTES);
  });

  it('keeps the URL out of every error message', async () => {
    const url = 'https://cal.example.com/private/secret-token.ics?key=secret-token';
    const cases: Array<Response | Error> = [
      new Response('x', { status: 500 }),
      new Response('   '),
      new Response(ICS, { headers: { 'Content-Length': String(MAX_ICS_BYTES + 1) } }),
      redirect('https://10.0.0.1/secret-token'),
      new TypeError(`fetch failed for ${url}`),
    ];
    for (const next of cases) {
      const { impl } = mockFetch(next);
      const error = await fetchIcs(url, { fetch: impl }).then(
        () => null,
        (e: unknown) => e as Error,
      );
      expect(error).toBeInstanceOf(IcsError);
      expect(error?.message).not.toContain('secret-token');
      expect(error?.message).not.toContain('cal.example.com');
    }
  });
});
