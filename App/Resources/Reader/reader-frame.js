// EPUB.js queues capture this scheduler during loading. WebKit may suspend
// native frames while a reading window is occluded or a native page is turning.
// Deliver each frame once, with a bounded fallback, and retain cancellation.
(() => {
  const request = window.requestAnimationFrame.bind(window);
  const cancel = window.cancelAnimationFrame.bind(window);
  const pending = new Map();
  let sequence = 0;
  window.requestAnimationFrame = callback => {
    const id = ++sequence;
    const entry = {frame: null, timer: null};
    pending.set(id, entry);
    const complete = timestamp => {
      if (!pending.delete(id)) return;
      cancel(entry.frame); clearTimeout(entry.timer);
      callback(timestamp);
    };
    entry.timer = setTimeout(() => complete(performance.now()), 80);
    entry.frame = request(complete);
    return id;
  };
  window.cancelAnimationFrame = id => {
    const entry = pending.get(id);
    if (!entry) return;
    pending.delete(id); cancel(entry.frame); clearTimeout(entry.timer);
  };
})();
