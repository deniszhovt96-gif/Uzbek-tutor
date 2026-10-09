// Перевод форм глагола на русский и английский по шаблонам времени.
// Формы русского/английского глагола берутся из словаря (words.morph, файл data/verb_forms.csv):
//   ru: { inf, tail, pres[6], past[м, ж, мн], imp[ед, мн] }, en: { f: [base, 3s, past, pp, ing], tail }.
// Переводы приблизительные (вид глагола, оттенки) — ошибку можно отметить кнопкой ⚑.

const RU_PR = ['я', 'ты', 'он(а)', 'мы', 'вы', 'они'];
const EN_PR = ['I', 'you', 'he/she', 'we', 'you', 'they'];
const SOBIR = ['собираюсь', 'собираешься', 'собирается', 'собираемся', 'собираетесь', 'собираются'];
const MOGU = ['могу', 'можешь', 'может', 'можем', 'можете', 'могут'];

// «ходил» + «ходила» → «ходил(а)»; «шёл» + «шла» → «шёл / шла»
function ruPastSg(m, f) {
  if (!m) return '';
  if (f === `${m}а`) return `${m}(а)`;
  if (m.endsWith('ся') && f === `${m.slice(0, -2)}ась`) return `${m}(-ась)`;
  return f ? `${m} / ${f}` : m;
}

function ru(morph, tense, neg, i) {
  const r = morph && morph.ru;
  if (!r || !r.pres || !r.pres[i]) return '';
  const pr = RU_PR[i];
  const ne = neg ? 'не ' : '';
  const V = `${ne}${r.pres[i]}`;
  const P = `${ne}${i >= 3 ? r.past[2] : ruPastSg(r.past[0], r.past[1])}`;
  const I = r.inf;
  let s;
  switch (tense) {
    case 'pres_fut': case 'pres_moqda': s = `${pr} ${V}`; break;
    case 'pres_cont': s = `${pr} ${neg ? '' : 'сейчас '}${V}`; break;
    case 'past_def': s = `${pr} ${P}`; break;
    case 'past_indef': s = `${pr} ${neg ? 'ещё' : 'уже'} ${P}`; break;
    case 'past_narr': s = `${pr}, оказывается, ${P}`; break;
    case 'past_cont': s = `${pr} ${P} (в тот момент)`; break;
    case 'past_perf': s = `${pr} ${P} (до того)`; break;
    case 'past_habit': s = `${pr}, бывало, ${P}`; break;
    case 'fut_pres': s = `${pr}, наверное, ${V}`; break;
    case 'fut_intent': s = `${pr} ${ne}${SOBIR[i]} ${I}`; break;
    case 'imper':
      s = [`давай я ${V}`, `${ne}${r.imp[0]}`, `пусть он(а) ${V}`, `давайте ${V}`, `${ne}${r.imp[1]}`, `пусть они ${V}`][i];
      break;
    case 'cond': s = `если ${pr} ${V}`; break;
    case 'wish': s = `вот бы ${pr} ${P}`; break;
    case 'unreal': s = `${pr} бы ${P}`; break;
    case 'can': s = `${pr} ${ne}${MOGU[i]} ${I}`; break;
    default: return '';
  }
  return r.tail ? `${s} ${r.tail}` : s;
}

function en(morph, tense, neg, i) {
  const e = morph && morph.en;
  if (!e || !e.f || !e.f[0]) return '';
  const [b, s3, past, pp, ing] = e.f;
  const be = b === 'be';
  const third = i === 2;
  const pr = EN_PR[i];
  const am = i === 0 ? 'am' : third ? 'is' : 'are';
  const was = i === 0 || third ? 'was' : 'were';
  const has = third ? 'has' : 'have';
  const doo = third ? 'does' : 'do';
  const n = neg ? ' not' : '';
  let s;
  switch (tense) {
    case 'pres_fut':
      s = be ? `${pr} ${am}${n}` : neg ? `${pr} ${doo} not ${b}` : `${pr} ${third ? s3 : b}`; break;
    case 'pres_cont': case 'pres_moqda': s = `${pr} ${am}${n} ${ing}`; break;
    case 'past_def': s = be ? `${pr} ${was}${n}` : neg ? `${pr} did not ${b}` : `${pr} ${past}`; break;
    case 'past_indef': s = `${pr} ${has}${n} ${pp}`; break;
    case 'past_narr': s = `apparently, ${be ? `${pr} ${was}${n}` : neg ? `${pr} did not ${b}` : `${pr} ${past}`}`; break;
    case 'past_cont': s = `${pr} ${was}${n} ${ing}`; break;
    case 'past_perf': s = `${pr} had${n} ${pp}`; break;
    case 'past_habit': s = neg ? `${pr} never used to ${b}` : `${pr} used to ${b}`; break;
    case 'fut_pres': s = neg ? `${pr} probably won't ${b}` : `${pr} will probably ${b}`; break;
    case 'fut_intent': s = `${pr} ${am}${n} going to ${b}`; break;
    case 'imper':
      s = neg ? ['let me not', `don't`, 'let him/her not', `let's not`, `don't`, 'let them not'][i] + ` ${b}`
        : ['let me', '', 'let him/her', `let's`, '', 'let them'][i] + ` ${b}`;
      s = s.trim(); break;
    case 'cond': s = `if ${be ? `${pr} ${am}${n}` : neg ? `${pr} ${doo} not ${b}` : `${pr} ${third ? s3 : b}`}`; break;
    case 'wish': s = `if only ${pr} ${be ? 'were' : neg ? `didn't ${b}` : past}${be && neg ? ' not' : ''}`; break;
    case 'unreal': s = `${pr} would${n} have ${pp}`; break;
    case 'can': s = `${pr} ${neg ? 'cannot' : 'can'} ${b}`; break;
    default: return '';
  }
  return e.tail ? `${s} ${e.tail}` : s;
}

// Перевод клетки таблицы: lang 'ru' | 'en' (для узбекского интерфейса — русский)
export function formTranslation(morph, tense, neg, i, lang) {
  if (!morph) return '';
  return lang === 'en' ? en(morph, tense, neg, i) : ru(morph, tense, neg, i);
}

// Значения падежей и притяжательных форм для таблиц склонения
export const CASE_MEANING = {
  ru: { nom: 'именительный: кто? что?', gen: 'родительный: чей? кого? чего?', acc: 'винительный: кого? что?',
        dat: 'дательный / направление: кому? куда?', loc: 'место и время: где? у кого? когда?', abl: 'исходный: откуда? от кого? из чего?' },
  en: { nom: 'nominative: who? what?', gen: 'genitive: whose? of what?', acc: 'accusative (definite object)',
        dat: 'dative / direction: to whom? where to?', loc: 'locative: where? when? with whom?', abl: 'ablative: from where? from whom?' },
};
export const POSS_MEANING = {
  ru: ['мой, моя, моё', 'твой, твоя, твоё', 'его, её', 'наш, наша, наше', 'ваш, ваша, ваше', 'их'],
  en: ['my', 'your', 'his / her', 'our', 'your (pl./polite)', 'their'],
};
