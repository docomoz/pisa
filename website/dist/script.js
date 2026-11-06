const copy = document.querySelector('.copy');
copy?.addEventListener('click', async () => {
  try {
    await navigator.clipboard.writeText('xattr -dr com.apple.quarantine "/Applications/Pisya.app"');
    copy.textContent = 'Скопировано';
    window.setTimeout(() => { copy.textContent = 'Копировать'; }, 2200);
  } catch {
    copy.textContent = 'Выделите команду';
  }
});

// Keep the download pointed at the latest published DMG; the release page remains a usable fallback.
fetch('https://api.github.com/repos/docomoz/pisya/releases/latest')
  .then(response => response.ok ? response.json() : Promise.reject())
  .then(release => {
    const dmg = release.assets?.find(asset => /^Pisya-.*-arm64\.dmg$/.test(asset.name));
    if (dmg && /^https:\/\/github\.com\/docomoz\/pisya\/releases\/download\//.test(dmg.browser_download_url)) {
      document.querySelectorAll('.download-link').forEach(link => { link.href = dmg.browser_download_url; });
    }
  }).catch(() => {});
