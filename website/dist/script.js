document.querySelectorAll('.code').forEach(block => {
  const copy = block.querySelector('.copy');
  const command = block.querySelector('code');
  const status = block.querySelector('.copy-status');
  copy?.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(command.textContent);
      if (/^(xattr|brew) /.test(command.textContent)) window.pisaTrack?.('copy_install_command');
      copy.textContent = 'Скопировано';
      if (status) status.textContent = 'Команда скопирована';
      window.setTimeout(() => { copy.textContent = 'Копировать'; }, 2200);
    } catch {
      copy.textContent = 'Выделите команду';
      if (status) status.textContent = 'Не удалось скопировать. Выделите команду вручную';
    }
  });
});

// Screenshots open in place over a lightened page. Without <dialog> support the
// links still lead to the image files.
const lightbox = document.querySelector('.lightbox');
if (lightbox && typeof lightbox.showModal === 'function') {
  const image = lightbox.querySelector('img');
  let opener = null;
  document.querySelectorAll('a[data-lightbox]').forEach(link => {
    link.addEventListener('click', event => {
      if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      event.preventDefault();
      opener = link;
      image.src = link.href;
      image.alt = link.querySelector('img')?.alt ?? '';
      document.documentElement.classList.add('lightbox-open');
      lightbox.showModal();
    });
  });
  // Any click closes it: on the picture, around it or on the close button. Escape is handled by <dialog>.
  lightbox.addEventListener('click', () => lightbox.close());
  lightbox.addEventListener('close', () => {
    document.documentElement.classList.remove('lightbox-open');
    opener?.focus({ preventScroll: true });
  });
}
