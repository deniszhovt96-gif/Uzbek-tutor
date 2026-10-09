// Узбекская морфология по правилам литературного языка: спряжение глаголов и склонение имён.
// Формы строятся из инфинитива (-moq) и основы слова; составные глаголы («yordam bermoq», «olib kelmoq»)
// спрягаются по последнему слову. Разговорные варианты и редкие исключения здесь не учитываются.

const PERSONS = ['men', 'sen', 'u', 'biz', 'siz', 'ular'];
export { PERSONS };

const endsVowel = (s) => /[aeiou]$/i.test(s) || /oʻ$/i.test(s);
// согласный на конце основы для ассимиляции аффиксов на г-/к-: k → -kan/-kin/-kach, q → -qan/-qin/-qach
const lastCons = (s) => {
  const m = s.match(/(gʻ|ng|sh|ch|[bdfghjklmnpqrstvxyz])$/i);
  return m ? m[1].toLowerCase() : '';
};
const gAffix = (stem, base) => {                  // base: 'gan' | 'gin' | 'gach' | 'guncha'
  const c = lastCons(stem);
  if (c === 'k') return 'k' + base.slice(1);
  if (c === 'q') return 'q' + base.slice(1);
  return base;
};

// личные окончания
const P_PRES = ['man', 'san', 'di', 'miz', 'siz', 'di'];          // настояще-будущее: boraman … boradi
const P_PRED = ['man', 'san', '', 'miz', 'siz', ''];              // сказуемостные: borganman … borgan
const P_POSS = ['m', 'ng', '', 'k', 'ngiz', ''];                  // притяжательного типа: bordim … bordi
const P_PROG = ['man', 'san', 'ti', 'miz', 'siz', 'ti'];          // -yap: boryapman … boryapti
const EDI = ['edim', 'eding', 'edi', 'edik', 'edingiz', 'edi'];   // вспомогательный edi
const BOLARDI = ['boʻlardim', 'boʻlarding', 'boʻlardi', 'boʻlardik', 'boʻlardingiz', 'boʻlardi'];
const pl = (forms) => forms.map((f, i) => (i === 5 ? `${f}(lar)` : f));   // 3 л. мн. ч.: «boradi(lar)»

// Разбор инфинитива: «yordam bermoq» → { prefix: 'yordam ', stem: 'ber', inf }
export function verbStem(infinitive) {
  const s = String(infinitive || '').trim();
  const m = s.match(/^(.*?)(\S+?)(moq|mak)$/i);
  if (!m || m[2].length < 1) return null;
  return { prefix: m[1], stem: m[2], inf: s };
}
export const isVerb = (uz) => Boolean(verbStem(uz)) && /(moq|mak)$/i.test(String(uz).trim());

// Все формы глагола: группы → времена → { pos: [6 форм], neg: [6 форм] } (или одна форма для неличных)
export function conjugate(infinitive) {
  const v = verbStem(infinitive);
  if (!v) return null;
  const { prefix, stem } = v;
  const V = endsVowel(stem);
  const p = (f) => f.split(' / ').map((x) => prefix + x).join(' / ');   // приставка — к каждому варианту
  const six = (fn) => PERSONS.map((_, i) => p(fn(i)));

  const aY = V ? 'y' : 'a';                       // соединительный гласный: bor-a-man / oʻqi-y-man
  const gan = gAffix(stem, 'gan');
  const ar = V ? 'r' : 'ar';

  const tenses = [
    // ---------------------------------------------------------------- изъявительное наклонение
    { group: 'indicative', id: 'pres_fut', uz: 'Hozirgi-kelasi zamon', ru: 'Настояще-будущее', en: 'Present-future', aff: '-a / -y',
      pos: pl(six((i) => stem + aY + P_PRES[i])), neg: pl(six((i) => stem + 'may' + P_PRES[i])) },
    { group: 'indicative', id: 'pres_cont', uz: 'Hozirgi zamon davom feʼli', ru: 'Настоящее длительное', en: 'Present continuous', aff: '-yap',
      pos: pl(six((i) => stem + 'yap' + P_PROG[i])), neg: pl(six((i) => stem + 'mayap' + P_PROG[i])) },
    { group: 'indicative', id: 'pres_moqda', uz: 'Hozirgi zamon kitobiy shakli', ru: 'Настоящее (книжное)', en: 'Present (formal)', aff: '-moqda',
      pos: pl(six((i) => stem + 'moqda' + P_PRED[i])), neg: pl(six((i) => stem + 'mamoqda' + P_PRED[i])) },
    { group: 'indicative', id: 'past_def', uz: 'Yaqin oʻtgan zamon', ru: 'Прошедшее (совершившееся)', en: 'Simple past', aff: '-di',
      pos: pl(six((i) => stem + 'di' + P_POSS[i])), neg: pl(six((i) => stem + 'madi' + P_POSS[i])) },
    { group: 'indicative', id: 'past_indef', uz: 'Oʻtgan zamon natijali', ru: 'Прошедшее результативное', en: 'Perfect', aff: '-gan',
      pos: pl(six((i) => stem + gan + P_PRED[i])), neg: pl(six((i) => stem + 'magan' + P_PRED[i])) },
    { group: 'indicative', id: 'past_narr', uz: 'Oʻtgan zamon hikoya feʼli', ru: 'Прошедшее повествовательное (о чём узнали)', en: 'Narrative (reported) past', aff: '-ibdi',
      pos: pl(six((i) => stem + (V ? 'b' : 'ib') + ['man', 'san', 'di', 'miz', 'siz', 'di'][i])),
      neg: pl(six((i) => stem + 'mab' + ['man', 'san', 'di', 'miz', 'siz', 'di'][i])) },
    { group: 'indicative', id: 'past_cont', uz: 'Oʻtgan zamon davom feʼli', ru: 'Прошедшее длительное', en: 'Past continuous', aff: '-ayotgan edi',
      pos: pl(six((i) => `${stem}${V ? 'yotgan' : 'ayotgan'} ${EDI[i]}`)), neg: pl(six((i) => `${stem}mayotgan ${EDI[i]}`)) },
    { group: 'indicative', id: 'past_perf', uz: 'Uzoq oʻtgan zamon', ru: 'Давнопрошедшее', en: 'Pluperfect', aff: '-gan edi',
      pos: pl(six((i) => `${stem}${gan} ${EDI[i]}`)), neg: pl(six((i) => `${stem}magan ${EDI[i]}`)) },
    { group: 'indicative', id: 'past_habit', uz: 'Oʻtgan zamon odat feʼli', ru: 'Прошедшее привычное («бывало»; «бы»)', en: 'Habitual past / would', aff: '-ar edi',
      pos: pl(six((i) => `${stem}${ar} ${EDI[i]}`)), neg: pl(six((i) => `${stem}mas ${EDI[i]}`)) },
    { group: 'indicative', id: 'fut_pres', uz: 'Kelasi zamon gumon feʼli', ru: 'Будущее предположительное', en: 'Presumptive future', aff: '-r / -ar',
      pos: pl(six((i) => stem + ar + P_PRED[i])), neg: pl(six((i) => stem + 'mas' + P_PRED[i])) },
    { group: 'indicative', id: 'fut_intent', uz: 'Kelasi zamon maqsad feʼli', ru: 'Будущее намерения', en: 'Future of intention', aff: '-moqchi',
      pos: pl(six((i) => stem + 'moqchi' + P_PRED[i])), neg: pl(six((i) => `${stem}moqchi emas${P_PRED[i]}`)) },

    // ---------------------------------------------------------------- повелительно-желательное наклонение
    { group: 'imperative', id: 'imper', uz: 'Buyruq-istak mayli', ru: 'Повелительно-желательное', en: 'Imperative', aff: '-ay, —/-gin, -sin, -aylik, -ing, -sinlar',
      pos: [`${stem}${V ? 'y' : 'ay'} / ${stem}${V ? 'yin' : 'ayin'}`, `${stem} / ${stem}${gAffix(stem, 'gin')}`, stem + 'sin',
            stem + (V ? 'ylik' : 'aylik'), stem + (V ? 'ng' : 'ing'), stem + 'sinlar'].map(p),
      neg: [stem + 'may', `${stem}ma / ${stem}magin`, stem + 'masin', stem + 'maylik', stem + 'mang', stem + 'masinlar'].map(p) },

    // ---------------------------------------------------------------- условное и сослагательное
    { group: 'conditional', id: 'cond', uz: 'Shart mayli', ru: 'Условное («если…»)', en: 'Conditional (if)', aff: '-sa',
      pos: pl(six((i) => stem + 'sa' + P_POSS[i])), neg: pl(six((i) => stem + 'masa' + P_POSS[i])) },
    { group: 'conditional', id: 'wish', uz: 'Istak shakli', ru: 'Желательное («вот бы…»)', en: 'Wish (if only)', aff: '-sa edi',
      pos: six((i) => `${stem}sa${P_POSS[i]} edi`).map((f, i) => (i === 5 ? f.replace(/sa edi$/, 'sa(lar) edi') : f)),
      neg: six((i) => `${stem}masa${P_POSS[i]} edi`).map((f, i) => (i === 5 ? f.replace(/sa edi$/, 'sa(lar) edi') : f)) },
    { group: 'conditional', id: 'unreal', uz: 'Natija shakli', ru: 'Сослагательное («…бы»)', en: 'Unreal (would have)', aff: '-gan boʻlardi',
      pos: pl(six((i) => `${stem}${gan} ${BOLARDI[i]}`)), neg: pl(six((i) => `${stem}magan ${BOLARDI[i]}`)) },

    // ---------------------------------------------------------------- возможность
    { group: 'ability', id: 'can', uz: 'Imkoniyat', ru: 'Возможность («могу»)', en: 'Ability (can)', aff: '-a / -y olmoq',
      pos: pl(six((i) => `${stem}${aY} ol${'a' + P_PRES[i]}`)), neg: pl(six((i) => `${stem}${aY} olmay${P_PRES[i]}`)) },
  ];

  // неличные формы
  const nonfinite = [
    { id: 'inf', uz: 'Harakat nomi', ru: 'Инфинитив / отглагольное имя', aff: '-moq / -ish', forms: [p(stem + 'moq'), p(stem + (/^(de|ye)$/.test(stem) ? 'yish' : V ? 'sh' : 'ish'))] },
    { id: 'part_past', uz: 'Sifatdosh (oʻtgan)', ru: 'Причастие прошедшее', aff: '-gan', forms: [p(stem + gan)] },
    { id: 'part_pres', uz: 'Sifatdosh (hozirgi)', ru: 'Причастие настоящее', aff: '-ayotgan', forms: [p(stem + (V ? 'yotgan' : 'ayotgan'))] },
    { id: 'part_fut', uz: 'Sifatdosh (hozirgi-kelasi)', ru: 'Причастие настояще-будущее', aff: '-adigan', forms: [p(stem + (V ? 'ydigan' : 'adigan'))] },
    { id: 'conv_ib', uz: 'Ravishdosh', ru: 'Деепричастие («сделав»)', aff: '-ib', forms: [p(stem + (V ? 'b' : 'ib'))] },
    { id: 'conv_gach', uz: 'Ravishdosh (keyin)', ru: 'Деепричастие («после того как»)', aff: '-gach', forms: [p(stem + gAffix(stem, 'gach'))] },
    { id: 'conv_guncha', uz: 'Ravishdosh (gacha)', ru: 'Деепричастие («пока не»)', aff: '-guncha', forms: [p(stem + gAffix(stem, 'guncha'))] },
  ];
  return { inf: v.inf, stem, prefix, tenses, nonfinite };
}

// Варианты, которые принимаются как верный ответ для одной клетки таблицы: «bor / borgin» → bor | borgin;
// «boradi(lar)» → boradi | boradilar
export function acceptedForms(cell) {
  const out = new Set();
  for (const part of String(cell).split(' / ')) {
    const p = part.trim();
    if (/\(lar\)/.test(p)) {
      out.add(p.replace('(lar)', ''));
      out.add(p.replace('(lar)', 'lar'));
    } else {
      out.add(p);
    }
  }
  return [...out];
}

// ---------------------------------------------------------------- склонение имён
// Озвончение конечных k/q перед гласным в многосложных исконных словах (yurak → yuragi, qishloq → qishlogʻi);
// в заимствованиях (park → parki) его нет — поэтому только для слов из списка правил ниже.
// Слова, теряющие гласный перед аффиксом на гласный (shahar → shahri): только по списку — правилом не предсказать
const DROP = { shahar: 'shahr', ogʻiz: 'ogʻz', burun: 'burn', oʻgʻil: 'oʻgʻl', koʻngil: 'koʻngl', singil: 'singl',
  qorin: 'qorn', bagʻir: 'bagʻr', zahar: 'zahr', boʻyin: 'boʻyn', qayin: 'qayn', ayol: 'ayol', asr: 'asr' };
// Заимствования, в которых k / q не озвончаются (huquq → huquqi)
const NO_VOICE = new Set(['ishtirok', 'idrok', 'huquq', 'ittifoq', 'axloq', 'mantiq', 'ishtiyoq', 'akademik', 'park', 'disk',
  'kiosk', 'blok', 'bank', 'tank', 'fabrik', 'mexanik', 'texnik', 'elektrik', 'klinik', 'nostalgik', 'shtamp', 'iste'+'mol',
  'tabrik', 'mulk', 'shirk', 'xalq', 'farq', 'haq', 'shart', 'ishq', 'sharq', 'tafovut']);
const syllables = (w) => (w.match(/oʻ|[aeiou]/gi) || []).length;
function voiced(word) {
  if (DROP[word]) return DROP[word];
  if (syllables(word) < 2 || NO_VOICE.has(word)) return word;
  if (/k$/.test(word) && /(ak|ik|uk|ok|ek|oʻk)$/.test(word) ) return word.slice(0, -1) + 'g';
  if (/q$/.test(word) && /(oq|aq|iq|uq|oʻq)$/.test(word)) return word.slice(0, -1) + 'gʻ';
  return word;
}

const CASES = [
  { id: 'nom', uz: 'Bosh kelishik', q: 'kim? nima?', aff: '—' },
  { id: 'gen', uz: 'Qaratqich kelishigi', q: 'kimning? nimaning?', aff: '-ning' },
  { id: 'acc', uz: 'Tushum kelishigi', q: 'kimni? nimani?', aff: '-ni' },
  { id: 'dat', uz: 'Joʻnalish kelishigi', q: 'kimga? nimaga? qayerga?', aff: '-ga / -ka / -qa' },
  { id: 'loc', uz: 'Oʻrin-payt kelishigi', q: 'kimda? nimada? qayerda?', aff: '-da' },
  { id: 'abl', uz: 'Chiqish kelishigi', q: 'kimdan? nimadan? qayerdan?', aff: '-dan' },
];
export { CASES };

function caseOf(base, c) {
  const last = lastCons(base);
  switch (c) {
    case 'nom': return base;
    case 'gen': return base + 'ning';
    case 'acc': return base + 'ni';
    case 'dat': return base + (last === 'k' ? 'ka' : last === 'q' ? 'qa' : 'ga');
    case 'loc': return base + 'da';
    case 'abl': return base + 'dan';
    default: return base;
  }
}

// Таблица склонения: строки — падежи; столбцы — ед. ч., мн. ч. и притяжательные формы (моё, твоё, его, наше, ваше, их)
export function decline(noun) {
  const w = String(noun || '').trim();
  if (!w || /\s/.test(w) || !/^[a-zʻʼ]+$/i.test(w)) return null;
  const V = endsVowel(w);
  const vw = V ? w : voiced(w);
  const poss = V
    ? [w + 'm', w + 'ng', w + 'si', w + 'miz', w + 'ngiz', w + 'si']
    : [vw + 'im', vw + 'ing', vw + 'i', vw + 'imiz', vw + 'ingiz', vw + 'i'];
  const columns = [
    { id: 'sg', base: w },
    { id: 'pl', base: w + 'lar' },
    ...poss.map((b, i) => ({ id: `poss${i}`, base: b, person: i })),
  ];
  return {
    word: w,
    columns: columns.map((col) => ({ ...col, forms: CASES.map((c) => caseOf(col.base, c.id)) })),
  };
}
