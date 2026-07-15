(function () {
  const root = document.documentElement;
  const btn = document.getElementById('dm-toggle');
  const stored = localStorage.getItem('pp-theme');
  const prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
  function setTheme(dark) {
    if (dark) {
      root.setAttribute('data-theme', 'dark');
    } else {
      root.removeAttribute('data-theme');
    }
    localStorage.setItem('pp-theme', dark ? 'dark' : 'light');
  }
  setTheme(stored ? stored === 'dark' : prefersDark);
  btn.addEventListener('click', function () {
    setTheme(root.getAttribute('data-theme') !== 'dark');
  });
})();
