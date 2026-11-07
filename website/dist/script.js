const copy = document.querySelector('.copy');
const copyStatus = document.querySelector('.copy-status');
copy?.addEventListener('click', async () => {
  try {
    await navigator.clipboard.writeText('xattr -dr com.apple.quarantine "/Applications/Pisya.app"');
    window.pisyaTrack?.('copy_install_command');
    copy.textContent = 'Скопировано';
    if (copyStatus) copyStatus.textContent = 'Команда скопирована';
    window.setTimeout(() => { copy.textContent = 'Копировать'; }, 2200);
  } catch {
    copy.textContent = 'Выделите команду';
    if (copyStatus) copyStatus.textContent = 'Не удалось скопировать. Выделите команду вручную';
  }
});

// The numbers stay visible without JavaScript; motion is added only as they enter view.
const featureNumbers = document.querySelectorAll('.feature-number');
const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
if ('IntersectionObserver' in window && !reduceMotion.matches) {
  const observer = new IntersectionObserver(entries => {
    for (const entry of entries) {
      if (entry.isIntersecting) {
        entry.target.classList.add('number-animate');
        observer.unobserve(entry.target);
      }
    }
  }, { threshold: 0.5 });
  featureNumbers.forEach(number => observer.observe(number));
}
