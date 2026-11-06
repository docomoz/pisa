const waterFilter = document.querySelector('#water-filter');
const waterMotion = document.querySelector('#water-motion');
if (waterFilter && waterMotion && window.matchMedia) {
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  let running = false;
  const updateWater = () => {
    if (reducedMotion.matches) {
      if (running) waterMotion.endElement();
      running = false;
    } else if (!running) {
      waterMotion.beginElement();
      running = true;
    }
    if (document.hidden) waterFilter.pauseAnimations();
    else waterFilter.unpauseAnimations();
  };
  reducedMotion.addEventListener('change', updateWater);
  document.addEventListener('visibilitychange', updateWater);
  updateWater();
}

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

const mood = document.querySelector('#brand-mood');
if (mood) {
  // Keep the independent phrases, emoji, colours and timing in sync with Pisya.
  const phrases = [
    'приподнятая', 'в хорошем настроении', 'в полный рост', 'радует глаз',
    'держится бодро', 'на высоте', 'в своей стихии', 'в прекрасной форме',
    'довольна собой', 'ловит момент', 'готова к разговору', 'вся во внимании',
    'знает своё дело', 'сегодня в ударе', 'на позитиве', 'с огоньком',
    'не унывает', 'держит марку', 'выглядит отлично', 'полна энтузиазма',
    'заряжена на день', 'в центре внимания', 'с характером', 'во всей красе',
    'рада тебя видеть', 'настроена серьёзно', 'дышит полной грудью', 'просто прелесть',
    'полна сил', 'всегда на связи', 'излучает оптимизм', 'готова к важному',
  ];
  const emojis = ['🙂', '😊', '😄', '😁', '😎', '🥳', '🤩', '😌', '😉', '🙃', '✨', '🌟', '☀️', '💚', '💛', '🎉', '🚀'];
  const colors = ['rgb(56 89 161)', 'rgb(102 74 150)', 'rgb(143 64 94)', 'rgb(61 107 82)', 'rgb(130 84 46)', 'rgb(46 102 110)', 'rgb(130 71 56)'];
  const randomIndex = count => Math.floor(Math.random() * count);
  const nextIndex = (current, count) => {
    const candidate = randomIndex(count - 1);
    return candidate >= current ? candidate + 1 : candidate;
  };
  let phrase = randomIndex(phrases.length);
  let emoji = randomIndex(emojis.length);
  let color = randomIndex(colors.length);
  const renderMood = () => {
    mood.querySelector('.brand-mood-phrase').textContent = phrases[phrase];
    mood.querySelector('.brand-mood-emoji').textContent = emojis[emoji];
    mood.style.color = colors[color];
    mood.title = `Pisya ${phrases[phrase]} ${emojis[emoji]}`;
  };
  const scheduleMood = () => {
    const seconds = 60 + randomIndex(61);
    window.setTimeout(() => {
      phrase = nextIndex(phrase, phrases.length);
      emoji = nextIndex(emoji, emojis.length);
      color = nextIndex(color, colors.length);
      renderMood();
      scheduleMood();
    }, seconds * 1000);
  };
  renderMood();
  scheduleMood();
}
