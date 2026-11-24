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
