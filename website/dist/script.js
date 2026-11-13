document.querySelectorAll('.code').forEach(block => {
  const copy = block.querySelector('.copy');
  const command = block.querySelector('code');
  const status = block.querySelector('.copy-status');
  copy?.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(command.textContent);
      if (command.textContent.startsWith('xattr ')) window.pisaTrack?.('copy_install_command');
      copy.textContent = 'Скопировано';
      if (status) status.textContent = 'Команда скопирована';
      window.setTimeout(() => { copy.textContent = 'Копировать'; }, 2200);
    } catch {
      copy.textContent = 'Выделите команду';
      if (status) status.textContent = 'Не удалось скопировать. Выделите команду вручную';
    }
  });
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
