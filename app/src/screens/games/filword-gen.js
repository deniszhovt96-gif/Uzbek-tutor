// Генерация филворда — чистые функции без интерфейса (проверяются отдельно).
import { shuffle, tilesOf } from '../../exercises.js';

// Случайный гамильтонов путь по сетке n×n (алгоритм «backbite»)
export function randomPath(n, rnd = Math.random) {
  let path = [];
  for (let r = 0; r < n; r++) for (let c = 0; c < n; c++) path.push(r * n + (r % 2 ? n - 1 - c : c));
  const neighbors = (i) => {
    const r = Math.floor(i / n), c = i % n, out = [];
    if (r > 0) out.push(i - n);
    if (r < n - 1) out.push(i + n);
    if (c > 0) out.push(i - 1);
    if (c < n - 1) out.push(i + 1);
    return out;
  };
  const steps = n * n * 20;
  for (let s = 0; s < steps; s++) {
    const atEnd = rnd() < 0.5;
    if (!atEnd) path.reverse();
    const end = path[path.length - 1];
    const prev = path[path.length - 2];
    const cand = neighbors(end).filter((x) => x !== prev);
    const nb = cand[Math.floor(rnd() * cand.length)];
    const j = path.indexOf(nb);
    path = path.slice(0, j + 1).concat(path.slice(j + 1).reverse());
  }
  return path;
}

// Слова → длины, дающие ровно n×n клеток; затем раскладка по пути
export function buildFilword(items, n, rnd = Math.random) {
  const cand = items
    .map((it) => ({ it, cells: tilesOf(it.uz) }))
    .filter((x) => x.cells.length >= 3 && x.cells.length <= n + 2 && x.cells.every((c) => !c.space && /^[a-zA-Zʻʼ]+$/.test(c.ch)));
  const total = n * n;
  for (let attempt = 0; attempt < 300; attempt++) {
    const pool = shuffle(cand, rnd);
    const chosen = [];
    const usedUz = new Set();
    let left = total;
    for (const x of pool) {
      const len = x.cells.length;
      const key = x.it.uz.toLowerCase();
      if (usedUz.has(key) || len > left || (left - len > 0 && left - len < 3)) continue;
      chosen.push(x);
      usedUz.add(key);
      left -= len;
      if (left === 0) break;
    }
    if (left !== 0) continue;
    const path = randomPath(n, rnd);
    const grid = new Array(total);
    const words = [];
    let pos = 0;
    for (const x of chosen) {
      const seg = path.slice(pos, pos + x.cells.length);
      if (rnd() < 0.5) seg.reverse();
      seg.forEach((cell, k) => { grid[cell] = x.cells[k].ch.toLowerCase(); });
      words.push({ item: x.it, cells: seg });
      pos += x.cells.length;
    }
    return { n, grid, words };
  }
  return null;
}

