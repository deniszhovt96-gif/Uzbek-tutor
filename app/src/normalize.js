// Нормализация ответов — те же правила, что в базе (public.key_uz / public.key_ru)
// и в scripts/build_vocab.py. См. docs/normalization.md.
const APOS = /[‘’'ʻʼ`´ʹ]/g;

export function keyUz(s) {
  return String(s ?? '')
    .normalize('NFC')
    .toLowerCase()
    .replace(APOS, "'")
    .replace(/[^a-z' \-]/g, ' ')
    .replace(/-/g, ' ')
    .replace(/\s+/g, ' ')
    .replace(/^[ ']+|[ ']+$/g, '');
}

export function keyRu(s) {
  return String(s ?? '')
    .replace(/\([^)]*\)/g, ' ')
    .normalize('NFC')
    .toLowerCase()
    .replace(/ё/g, 'е')
    .replace(/[^0-9a-zа-я \-]/g, ' ')
    .replace(/-/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

// Узбекский текст с ввода пользователя приводим к виду для показа (oʻ gʻ, ʼ)
export function displayUz(s) {
  const str = String(s ?? '').normalize('NFC');
  let out = '';
  for (let i = 0; i < str.length; i++) {
    const ch = str[i];
    if (/[‘’'ʻʼ`´ʹ]/.test(ch)) out += /[oOgG]/.test(str[i - 1] || '') ? 'ʻ' : 'ʼ';
    else out += ch;
  }
  return out;
}

// Посимвольное сравнение для подсветки ошибки: [{ch, kind: 'same'|'wrong'|'missing'|'extra'}]
export function diffChars(answer, correct) {
  const a = [...String(answer ?? '')];
  const b = [...String(correct ?? '')];
  const n = (c) => c.toLowerCase().replace(APOS, "'").replace('ё', 'е');
  const eq = (x, y) => n(x) === n(y);
  const dp = Array.from({ length: a.length + 1 }, () => new Array(b.length + 1).fill(0));
  for (let i = 0; i <= a.length; i++) dp[i][0] = i;
  for (let j = 0; j <= b.length; j++) dp[0][j] = j;
  for (let i = 1; i <= a.length; i++)
    for (let j = 1; j <= b.length; j++)
      dp[i][j] = Math.min(dp[i - 1][j] + 1, dp[i][j - 1] + 1, dp[i - 1][j - 1] + (eq(a[i - 1], b[j - 1]) ? 0 : 1));
  const out = [];
  let i = a.length, j = b.length;
  while (i > 0 || j > 0) {
    if (i > 0 && j > 0 && dp[i][j] === dp[i - 1][j - 1] + (eq(a[i - 1], b[j - 1]) ? 0 : 1)) {
      out.push({ ch: b[j - 1], kind: eq(a[i - 1], b[j - 1]) ? 'same' : 'wrong' });
      i--; j--;
    } else if (j > 0 && dp[i][j] === dp[i][j - 1] + 1) {
      out.push({ ch: b[j - 1], kind: 'missing' });
      j--;
    } else {
      out.push({ ch: a[i - 1], kind: 'extra' });
      i--;
    }
  }
  return out.reverse();
}
