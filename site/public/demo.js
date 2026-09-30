const scenes = {
  reminder: { eyebrow: 'A LITTLE LESS TO REMEMBER', title: 'Good things\nto get done.', request: '“Add buy flowers to my reminders.”', result: 'Added. A small thing, off your mind.', items: ['Make a little space','Pick up coffee','Plan the weekend','Buy flowers 🌷'], direction: 'ltr', footer: '⊕ New Reminder' },
  settings: { eyebrow: 'A LITTLE EASIER TO FIND', title: 'A quieter\nkind of day.', request: '“Find the Focus settings for me.”', result: 'Found Focus. Ready when you are.', items: ['Wi-Fi','Bluetooth','Notifications','Focus'], direction: 'ltr', footer: 'Settings, within reach' },
  hebrew: { eyebrow: 'YOUR WORDS. YOUR LANGUAGE.', title: 'A little note.\nIn your words.', request: '“Write hello in Hebrew, with a smile.”', result: 'Text entered. שלום עולם 👋', items: ['A note to a friend','English, Hebrew, emoji','One clipboard, every character','שלום עולם 👋'], direction: 'ltr', footer: 'Your keyboard can stay as it is' }
};
for (const button of document.querySelectorAll('[data-demo]')) {
  button.addEventListener('click', () => {
    const key = button.dataset.demo;
    const scene = scenes[key];
    if (!scene) return;
    for (const other of document.querySelectorAll('[data-demo]')) other.setAttribute('aria-pressed', String(other === button));
    document.querySelector('#phone-eyebrow').textContent = scene.eyebrow;
    document.querySelector('#phone-title').replaceChildren(...scene.title.split('\n').flatMap((line,index) => index ? [document.createElement('br'), document.createTextNode(line)] : [document.createTextNode(line)]));
    document.querySelector('#demo-request').textContent = scene.request;
    document.querySelector('#demo-result').textContent = scene.result;
    const items = scene.items.map((label, index) => {
      const row = document.createElement('div'); row.className = 'phone-item' + (index === 3 ? ' demo-added' : '');
      const icon = document.createElement('span'); icon.className = 'check-circle' + (index === 0 && key === 'reminder' ? ' checked' : '');
      const text = document.createElement('span'); text.textContent = label;
      if (index === 0 && key === 'reminder') text.className = 'item-done';
      if (index === 3 && key === 'hebrew') { text.lang = 'he'; text.dir = 'rtl'; }
      row.append(icon, text); return row;
    });
    document.querySelector('#phone-items').replaceChildren(...items);
    document.querySelector('.phone-footer span').textContent = scene.footer;
    const pointer = document.querySelector('.pointer');
    pointer.style.left = key === 'settings' ? '68%' : key === 'hebrew' ? '57%' : '65%';
    pointer.style.top = key === 'settings' ? '46%' : '53%';
  });
}
