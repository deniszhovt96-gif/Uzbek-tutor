import { AUDIO_BASE } from './config.js';

// Цикл из трёх нажатий: 1-е — обычная скорость, 2-е и 3-е — медленно (0,75), затем всё сначала.
const plays = new Map();
let current = null;

export function wordAudio(id) { return `${AUDIO_BASE}word_${id}.mp3`; }
export function exampleAudio(wordId, n) { return `${AUDIO_BASE}word_${wordId}_ex${n}.mp3`; }

export function play(url) {
  if (!url) return Promise.resolve();
  const count = (plays.get(url) || 0) + 1;
  plays.set(url, count);
  if (current) { current.pause(); current = null; }
  const audio = new Audio(url);
  audio.playbackRate = (count - 1) % 3 === 0 ? 1 : 0.75;   // 1, 0.75, 0.75, 1, 0.75, 0.75, …
  current = audio;
  return audio.play().catch((err) => console.warn('[audio]', url, err));
}

export function preload(urls) {
  for (const url of urls) {
    const a = new Audio();
    a.preload = 'auto';
    a.src = url;
  }
}
