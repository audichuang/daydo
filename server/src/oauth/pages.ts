// HTML pages for /authorize (spec/mcp.md 4.4). Every value is escaped; every page forbids
// framing and caching. No CORS headers: /authorize* is browser-only.

const SECURITY_HEADERS: Record<string, string> = {
  'Content-Type': 'text/html; charset=utf-8',
  'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'",
  'X-Frame-Options': 'DENY',
  'Cache-Control': 'no-store',
  'Referrer-Policy': 'no-referrer',
};

export function esc(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

const STYLE = `
  :root { color-scheme: light dark; }
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
         max-width: 460px; margin: 3rem auto; padding: 0 1rem; line-height: 1.5; }
  h1 { font-size: 1.25rem; margin-bottom: 0.5rem; }
  .muted { color: #666; font-size: 0.9rem; }
  .box { background: #f4f4f4; padding: 0.75rem; border-radius: 8px; margin: 1rem 0; word-break: break-all; }
  @media (prefers-color-scheme: dark) { .box { background: #222; color: #ddd; } }
  .button { display: block; box-sizing: border-box; width: 100%; margin-top: 0.75rem; padding: 0.75rem;
            font-size: 1rem; text-align: center; text-decoration: none; border: none; border-radius: 8px;
            background: #2563eb; color: white; cursor: pointer; }
  .button.secondary { background: #e5e7eb; color: #111; }
  .button.disabled { background: #e5e7eb; color: #888; cursor: default; }
  ul { padding-left: 1.25rem; }
`;

function page(status: number, title: string, body: string, headers: Record<string, string> = {}): Response {
  const html = `<!doctype html>
<html lang="zh-Hant">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title>
<style>${STYLE}</style>
</head>
<body>
${body}
</body>
</html>`;
  return new Response(html, { status, headers: { ...SECURITY_HEADERS, ...headers } });
}

export function errorPage(message: string, status = 400): Response {
  return page(status, '授權錯誤', `<h1>無法完成授權</h1>\n<p>${esc(message)}</p>`);
}

export interface ProviderButton {
  label: string;
  /** Null when the provider is not configured; the button is shown disabled. */
  href: string | null;
}

export function loginPage(params: { clientName: string; buttons: ProviderButton[]; setCookie: string }): Response {
  const buttons = params.buttons
    .map((b) =>
      b.href
        ? `<a class="button" href="${esc(b.href)}">${esc(b.label)}</a>`
        : `<span class="button disabled">${esc(b.label)}（未設定）</span>`,
    )
    .join('\n');
  return page(
    200,
    '登入 DayDo',
    `<h1>登入 DayDo</h1>
<p class="muted">「${esc(params.clientName)}」要求存取你的 DayDo。請用你在 DayDo App 登入的帳號繼續：</p>
${buttons}`,
    { 'Set-Cookie': params.setCookie },
  );
}

export function consentPage(params: {
  userName: string;
  clientName: string;
  redirectHost: string;
  pendingId: string;
  consentToken: string;
}): Response {
  return page(
    200,
    '授權 DayDo',
    `<h1>授權存取 DayDo</h1>
<p>你目前以 <strong>${esc(params.userName)}</strong> 登入。</p>
<div class="box">
  <div><strong>應用程式：</strong>${esc(params.clientName)}</div>
  <div><strong>完成後導向：</strong>${esc(params.redirectHost)}</div>
</div>
<p>同意後，這個應用程式可以：</p>
<ul>
  <li>讀取與修改你的任務</li>
  <li>讀取與修改你的清單與標籤</li>
  <li>管理你的 ICS 行事曆訂閱</li>
</ul>
<form method="post" action="/authorize">
  <input type="hidden" name="pending" value="${esc(params.pendingId)}">
  <input type="hidden" name="ct" value="${esc(params.consentToken)}">
  <button class="button" type="submit" name="decision" value="approve">同意</button>
  <button class="button secondary" type="submit" name="decision" value="deny">拒絕</button>
</form>`,
  );
}
