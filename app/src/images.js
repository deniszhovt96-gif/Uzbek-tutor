// Иллюстрации к темам курсов: img/manifest.json собирается при деплое (scripts/fetch_images.py)
// из свободных изображений Wikimedia Commons — с автором и лицензией.
let manifest = null;

async function load() {
  if (manifest) return manifest;
  try {
    const res = await fetch('./img/manifest.json', { cache: 'no-cache' });
    manifest = res.ok ? await res.json() : {};
  } catch {
    manifest = {};
  }
  return manifest;
}

export async function topicImage(course, n) {
  const m = await load();
  if (!course) return null;
  const e = m[`${course}-${n}`];
  return e ? { ...e, src: e.file ? `./img/${e.file}` : e.remote } : null;
}
