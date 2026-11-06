const measurementId = document.querySelector('meta[name="pisya-ga-measurement-id"]')?.content;

if (measurementId && /^G-[A-Z0-9]+$/.test(measurementId)) {
  const script = document.createElement('script');
  script.async = true;
  script.src = `https://www.googletagmanager.com/gtag/js?id=${encodeURIComponent(measurementId)}`;
  document.head.appendChild(script);

  window.dataLayer = window.dataLayer || [];
  function gtag() { window.dataLayer.push(arguments); }
  gtag('js', new Date());
  const pageLocation = window.location.origin + window.location.pathname;
  let pageReferrer = '';
  try { if (document.referrer) pageReferrer = new URL(document.referrer).origin; } catch {}
  gtag('config', measurementId, {
    page_location: pageLocation,
    page_referrer: pageReferrer,
    page_title: 'Pisya',
    allow_google_signals: false,
    allow_ad_personalization_signals: false,
  });

  // Only fixed event names are sent: no link text, search terms or user input.
  window.pisyaTrack = (name, params = {}) => gtag('event', name, params);
  document.addEventListener('click', event => {
    const link = event.target.closest?.('a');
    if (!link) return;
    const href = link.getAttribute('href');
    if (href === '#install-guide') {
      window.pisyaTrack('install_guide_click');
    } else if (href === '/download') {
      // Let the event leave the page before a same-tab download redirect.
      if (!event.defaultPrevented && event.button === 0 && !event.metaKey && !event.ctrlKey && !event.shiftKey && !event.altKey && !link.hasAttribute('download') && (!link.target || link.target === '_self')) {
        event.preventDefault();
        let navigated = false;
        const navigate = () => {
          if (!navigated) { navigated = true; window.location.assign(link.href); }
        };
        window.pisyaTrack('download_click', { event_callback: navigate, event_timeout: 700 });
        window.setTimeout(navigate, 700);
      } else {
        window.pisyaTrack('download_click');
      }
    } else if (href?.startsWith('https://github.com/docomoz/pisya')) {
      window.pisyaTrack('github_click');
    }
  });
}
