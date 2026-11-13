const APPCAST_URL = 'https://github.com/docomoz/pisa/releases/latest/download/pisa-appcast.xml';
const RELEASE_PAGE = 'https://github.com/docomoz/pisa/releases/latest';

export function downloadFromAppcast(xml) {
  // The feed is created with each release. Use the first item only, and never
  // redirect to a different project, host, file type, or mismatched version.
  const firstItem = xml.match(/<item\b[^>]*>([\s\S]*?)<\/item\s*>/i)?.[1];
  const url = firstItem?.match(/<enclosure\b[^>]*\burl\s*=\s*["']([^"']+)["']/i)?.[1];
  const pattern = /^https:\/\/github\.com\/docomoz\/pisa\/releases\/download\/v(\d+\.\d+\.\d+)\/Pisa-\1-arm64\.dmg$/;
  return url && pattern.test(url) ? url : null;
}

export async function handleRequest(request, fetchFeed = fetch) {
  const { pathname } = new URL(request.url);
  if (request.method !== 'GET' && request.method !== 'HEAD') return new Response('Method not allowed', { status: 405, headers: { Allow: 'GET, HEAD' } });
  if (pathname === '/download') {
    try {
      const upstream = await fetchFeed(APPCAST_URL, { redirect: 'follow', signal: AbortSignal.timeout(10000) });
      if (!upstream.ok) throw new Error('Feed unavailable');
      const length = Number(upstream.headers.get('content-length') || 0);
      if (length > 262144) throw new Error('Feed too large');
      const xml = await upstream.text();
      if (xml.length > 262144) throw new Error('Feed too large');
      const url = downloadFromAppcast(xml);
      if (!url) throw new Error('Feed does not contain a valid Pisa DMG');
      return new Response(null, { status: 302, headers: { Location: url, 'Cache-Control': 'no-store' } });
    } catch {
      const body = `<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Не удалось получить установщик</title><body style="font:16px/1.5 -apple-system,sans-serif;padding:2rem;max-width:38rem"><h1>Не удалось получить установщик</h1><p>Попробуйте ещё раз или скачайте DMG на <a href="${RELEASE_PAGE}">странице последнего релиза</a>.</p></body></html>`;
      return new Response(request.method === 'HEAD' ? null : body, { status: 503, headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store', 'Retry-After': '60' } });
    }
  }
  const asset = ASSETS[pathname === '/' ? '/index.html' : pathname === '/migration' ? '/migration.html' : pathname];
  if (!asset) return new Response('Not found', { status: 404 });
  const bytes = Uint8Array.from(atob(asset.data), character => character.charCodeAt(0));
  return new Response(request.method === 'HEAD' ? null : bytes, {
    headers: { 'Content-Type': asset.type, 'Cache-Control': 'no-cache', 'X-Content-Type-Options': 'nosniff' },
  });
}

export default { fetch(request) { return handleRequest(request); } };
