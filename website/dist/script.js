const copy = document.querySelector('.copy');
const copyStatus = document.querySelector('.copy-status');
copy?.addEventListener('click', async () => {
  try {
    await navigator.clipboard.writeText('xattr -dr com.apple.quarantine "/Applications/Pisya.app"');
    copy.textContent = 'Скопировано';
    if (copyStatus) copyStatus.textContent = 'Команда скопирована';
    window.setTimeout(() => { copy.textContent = 'Копировать'; }, 2200);
  } catch {
    copy.textContent = 'Выделите команду';
    if (copyStatus) copyStatus.textContent = 'Не удалось скопировать. Выделите команду вручную';
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

const mood = document.querySelector('#brand-mood');
if (mood) {
  const moods = ['приподнятая ✨', 'в хорошем настроении ☀️', 'в полный рост 🌱', 'радует глаз 👀', 'держится бодро 💪', 'на высоте 🚀', 'в прекрасной форме ✨', 'готова к разговору 💬', 'вся во внимании 👂', 'с огоньком 🔥', 'с характером 😌', 'рада тебя видеть 👋'];
  let previous = -1;
  const updateMood = () => {
    let next = Math.floor(Math.random() * moods.length);
    if (next === previous) next = (next + 1) % moods.length;
    previous = next;
    mood.textContent = moods[next];
    window.setTimeout(updateMood, 60000 + Math.random() * 60000);
  };
  updateMood();
}
