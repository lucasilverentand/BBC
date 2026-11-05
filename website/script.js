const status = document.getElementById('copy-status');

document.querySelectorAll('[data-copy]').forEach((button) => {
  const target = document.getElementById(button.dataset.copy);
  if (!target || !status) return;
  button.hidden = false;

  button.addEventListener('click', async () => {
    // Prompt markers are aria-hidden and excluded from the copied text.
    const text = Array.from(target.childNodes)
      .filter((node) => !(node.nodeType === Node.ELEMENT_NODE && node.classList.contains('c-prompt')))
      .map((node) => node.textContent)
      .join('');
    try {
      await navigator.clipboard.writeText(text);
      button.textContent = 'Copied';
      status.textContent = button.dataset.copy === 'api-example'
        ? 'Example copied. Set your API key and operation UUID before using it.'
        : 'Copied to clipboard.';
      window.setTimeout(() => { button.textContent = 'Copy'; }, 2000);
    } catch {
      const range = document.createRange();
      range.selectNodeContents(target);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      status.textContent = 'Code selected. Use your browser’s copy command.';
    }
  });
});
