const APPCAST_URL = 'https://github.com/docomoz/pisa/releases/latest/download/pisa-updates.xml';
const RELEASE_PAGE = 'https://github.com/docomoz/pisa/releases/latest';

export function downloadFromAppcast(xml) {
  // The feed is created with each release. Use the first item only, and never
  // redirect to a different project, host, file type, or mismatched version.
  const firstItem = xml.match(/<item\b[^>]*>([\s\S]*?)<\/item\s*>/i)?.[1];
  const url = firstItem?.match(/<enclosure\b[^>]*\burl\s*=\s*["']([^"']+)["']/i)?.[1];
  const pattern = /^https:\/\/github\.com\/docomoz\/pisa\/releases\/download\/v(\d+\.\d+\.\d+)\/Pisa-\1-arm64\.dmg$/;
  return url && pattern.test(url) ? url : null;
}

export function versionFromAppcast(xml) {
  return downloadFromAppcast(xml)?.match(/\/v(\d+\.\d+\.\d+)\//)?.[1] ?? null;
}

async function fetchAppcast(fetchFeed, timeout) {
  let upstream = await fetchFeed(APPCAST_URL, { redirect: 'follow', cache: 'no-store', signal: AbortSignal.timeout(timeout) });
  // Some GitHub edges briefly cache the old latest-release redirect after publishing.
  if (upstream.status === 404) {
    const retryUrl = new URL(APPCAST_URL);
    retryUrl.searchParams.set('site_retry', crypto.randomUUID());
    upstream = await fetchFeed(retryUrl.href, { redirect: 'follow', cache: 'no-store', signal: AbortSignal.timeout(timeout) });
  }
  if (!upstream.ok) throw new Error('Feed unavailable');
  const length = Number(upstream.headers.get('content-length') || 0);
  if (length > 262144) throw new Error('Feed too large');
  const xml = await upstream.text();
  if (xml.length > 262144) throw new Error('Feed too large');
  return xml;
}

// The page shows the latest released version. It is read from the same feed as
// /download, kept for a few minutes, and never delays the page for long: a cold
// cache waits briefly, a stale one is refreshed in the background, and without
// a version the badge keeps its static «Релиз» label.
const VERSION_TTL = 10 * 60 * 1000;
const release = { version: null, checkedAt: 0, pending: null };

export function resetReleaseCache() {
  release.version = null;
  release.checkedAt = 0;
  release.pending = null;
}

function refreshVersion(fetchFeed) {
  release.pending ??= fetchAppcast(fetchFeed, 5000)
    .then(xml => { release.version = versionFromAppcast(xml) ?? release.version; })
    .catch(() => {})
    .finally(() => { release.checkedAt = Date.now(); release.pending = null; });
  return release.pending;
}

async function latestVersion(fetchFeed) {
  if (Date.now() - release.checkedAt < VERSION_TTL) return release.version;
  const refresh = refreshVersion(fetchFeed);
  if (release.checkedAt === 0) {
    let timer;
    await Promise.race([refresh, new Promise(resolve => { timer = setTimeout(resolve, 1500); })]);
    clearTimeout(timer);
  }
  return release.version;
}

const BADGE = '<span class="pill-badge" data-release-version>Релиз</span>';
let pageTemplate = null;

async function renderPage(asset, fetchFeed) {
  pageTemplate ??= new TextDecoder().decode(Uint8Array.from(atob(asset.data), character => character.charCodeAt(0)));
  const version = await latestVersion(fetchFeed);
  const page = version ? pageTemplate.replace(BADGE, `<span class="pill-badge" data-release-version>v${version}</span>`) : pageTemplate;
  return new TextEncoder().encode(page);
}

export async function handleRequest(request, fetchFeed = fetch) {
  const { pathname } = new URL(request.url);
  if (request.method !== 'GET' && request.method !== 'HEAD') return new Response('Method not allowed', { status: 405, headers: { Allow: 'GET, HEAD' } });
  if (pathname === '/download') {
    try {
      const xml = await fetchAppcast(fetchFeed, 10000);
      const url = downloadFromAppcast(xml);
      if (!url) throw new Error('Feed does not contain a valid Pisa DMG');
      return new Response(null, { status: 302, headers: { Location: url, 'Cache-Control': 'no-store' } });
    } catch {
      const body = `<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Не удалось получить установщик</title><body style="font:16px/1.5 -apple-system,sans-serif;padding:2rem;max-width:38rem"><h1>Не удалось получить установщик</h1><p>Попробуйте ещё раз или скачайте DMG на <a href="${RELEASE_PAGE}">странице последнего релиза</a>.</p></body></html>`;
      return new Response(request.method === 'HEAD' ? null : body, { status: 503, headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store', 'Retry-After': '60' } });
    }
  }
  const asset = ASSETS[pathname === '/' ? '/index.html' : pathname];
  if (!asset) return new Response('Not found', { status: 404 });
  const isPage = pathname === '/' || pathname === '/index.html';
  const bytes = isPage ? await renderPage(asset, fetchFeed) : Uint8Array.from(atob(asset.data), character => character.charCodeAt(0));
  return new Response(request.method === 'HEAD' ? null : bytes, {
    headers: { 'Content-Type': asset.type, 'Cache-Control': 'no-cache', 'X-Content-Type-Options': 'nosniff' },
  });
}

export default { fetch(request) { return handleRequest(request); } };
