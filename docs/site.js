// The hero readout: tracks change, the output follows. Static (and accurate)
// without JavaScript or with reduced motion; paused while the tab is hidden.
(() => {
  const readout = document.querySelector(".readout");
  if (!readout) return;

  const tracks = JSON.parse(readout.dataset.tracks);
  const labels = { sync: readout.dataset.sync, switching: readout.dataset.switching };
  const $ = (selector) => readout.querySelector(selector);
  const title = $(".readout-track b");
  const artist = $(".readout-track span");
  const source = $(".side.src .num");
  const output = $(".side.out .num");
  const format = $(".format .what");
  const pill = $(".pill");
  const keys = [...readout.querySelectorAll(".keys li")];

  const show = (rate, cls) => keys.forEach((key) => key.classList.toggle(cls, key.dataset.rate === rate));

  const copy = document.querySelectorAll(".copy");
  copy.forEach((button) => button.addEventListener("click", async () => {
    const text = button.parentElement.querySelector("code").textContent;
    try {
      await navigator.clipboard.writeText(text);
      button.textContent = button.dataset.copied;
      button.setAttribute("data-done", "");
      setTimeout(() => { button.textContent = button.dataset.label; button.removeAttribute("data-done"); }, 1600);
    } catch { /* clipboard unavailable: the command stays selectable */ }
  }));

  if (matchMedia("(prefers-reduced-motion: reduce)").matches) return;

  let index = 0;
  let timers = [];
  const later = (fn, ms) => timers.push(setTimeout(fn, ms));

  function step() {
    index = (index + 1) % tracks.length;
    const track = tracks[index];
    title.textContent = track.title;
    artist.textContent = track.artist;
    format.textContent = track.format;
    source.textContent = track.rate;
    show(track.rate, "src");
    readout.dataset.state = "switching";
    pill.lastChild.textContent = labels.switching;
    later(() => {
      output.textContent = track.rate;
      show(track.rate, "out");
      readout.dataset.state = "sync";
      pill.lastChild.textContent = labels.sync;
    }, 900);
    later(step, 3600);
  }

  function start() { if (!timers.length) later(step, 2600); }
  function stop() { timers.forEach(clearTimeout); timers = []; }

  document.addEventListener("visibilitychange", () => (document.hidden ? stop() : start()));
  start();
})();
