// Движок сеанса: очередь заданий, повторы ошибок, отправка ответов пачками.
// Правила уровней применяет сервер; здесь — только порядок показа и мгновенная обратная связь.
import { rpc } from './api.js';
import { pickExercise, checkAnswer } from './exercises.js';

const RETRY_GAP = [3, 5];          // ошибка → то же слово через 3–5 заданий другим типом
const STEP_GAP = 4;                // шаг заучивания 1→2 — не раньше чем через 4 задания
const MAX_RETRIES_LEARNING = 3;
const MAX_RETRIES_REVIEW = 1;
const FLUSH_EVERY = 8;

export class Session {
  constructor(data, opts = {}) {
    this.id = data.session_id;
    this.items = new Map(data.items.map((it) => [it.id, it]));
    this.opts = opts;
    this.state = new Map();
    for (const it of data.items) {
      this.state.set(it.id, { level: it.level, stage: it.stage, lastType: null, retries: 0, shown: it.stage !== 'new' });
    }
    this.sentencePool = data.items.flatMap((it) => (it.examples || []).map((e) => e.ru));
    this.queue = buildQueue(data.items);
    this.pending = [];
    this.seq = (Math.floor(Date.now() / 1000) % 1000000) * 1000;
    this.stats = { answers: 0, correct: 0, newShown: 0, reviewed: new Set() };
    this.startedAt = Date.now();
    this.saveFailed = false;
  }

  get total() { return this.queue.length + this.stats.answers + this.stats.newShown; }
  get done() { return this.stats.answers + this.stats.newShown; }
  isEmpty() { return this.queue.length === 0; }

  // Следующее задание: {kind:'card', item} или {kind:'ex', ex, attempt}
  next() {
    const task = this.queue.shift();
    if (!task) return null;
    const item = this.items.get(task.wordId);
    const st = this.state.get(task.wordId);
    if (task.kind === 'card') return { kind: 'card', item };
    const ex = pickExercise(item, st.level, st.lastType, { audio: this.opts.audio, sentencePool: this.sentencePool });
    st.lastType = ex.type;
    return { kind: 'ex', ex, attempt: task.attempt, item };
  }

  cardShown(item) {
    const st = this.state.get(item.id);
    if (st.shown) return;
    st.shown = true;
    this.stats.newShown++;
    this.push({ kind: 'shown', word_id: item.id });
  }

  // Ответ пользователя → мгновенная оценка + планирование следующих заданий
  answer(task, answerText) {
    const { ex, attempt } = task;
    const st = this.state.get(ex.wordId);
    const correct = checkAnswer(ex, answerText);
    const isReview = st.level >= 2;
    const counted = st.level <= 1 || attempt === 'first';

    this.stats.answers++;
    if (correct) this.stats.correct++;
    if (isReview) this.stats.reviewed.add(ex.wordId);

    this.push({
      kind: 'answer', word_id: ex.wordId, ex_type: ex.type, target: ex.target,
      answer: answerText, attempt, example: ex.example,
    });

    if (correct && counted) st.level = Math.min(15, st.level + 1);

    if (!correct) {
      st.retries++;
      const max = st.level <= 1 ? MAX_RETRIES_LEARNING : MAX_RETRIES_REVIEW;
      if (st.retries <= max) this.insertAt(randomGap(), { kind: 'ex', wordId: ex.wordId, attempt: 'retry' });
    } else if (st.level === 1) {
      // шаг заучивания 1→2 в этом же сеансе
      this.insertAt(STEP_GAP, { kind: 'ex', wordId: ex.wordId, attempt: 'first' });
    }
    return { correct, level: st.level };
  }

  insertAt(gap, task) {
    const pos = Math.min(gap, this.queue.length);
    this.queue.splice(pos, 0, task);
  }

  push(event) {
    this.seq += 1;
    this.pending.push({ seq: this.seq, ...event });
    if (this.pending.length >= FLUSH_EVERY) this.flush();
  }

  async flush() {
    if (!this.pending.length || this.flushing) return this.flushing;
    const batch = this.pending.splice(0, 50);
    this.flushing = rpc('submit_answers', { p_session_id: this.id, p_events: batch })
      .then((r) => {
        this.saveFailed = false;
        if (r && r.error) console.warn('[session] submit error', r.error);
      })
      .catch((err) => {
        console.warn('[session] submit failed, will retry', err);
        this.pending.unshift(...batch);   // вернём в очередь — сервер отбросит дубли по seq
        this.saveFailed = true;
      })
      .finally(() => { this.flushing = null; });
    return this.flushing;
  }

  async finish() {
    await this.flush();
    if (this.pending.length) await this.flush();
    const seconds = Math.round((Date.now() - this.startedAt) / 1000);
    await rpc('finish_session', { p_session_id: this.id, p_seconds: seconds }).catch(() => {});
    return {
      answers: this.stats.answers,
      correct: this.stats.correct,
      newWords: this.stats.newShown,
      reviewed: this.stats.reviewed.size,
    };
  }
}

function randomGap() {
  return RETRY_GAP[0] + Math.floor(Math.random() * (RETRY_GAP[1] - RETRY_GAP[0] + 1));
}

// Порядок: 3 повторения для разминки → новые слова группами по 5
// (5 карточек → задания по ним вперемешку с повторениями) → оставшиеся повторения.
export function buildQueue(items) {
  const reviews = items.filter((i) => i.stage !== 'new').map((i) => ({ kind: 'ex', wordId: i.id, attempt: 'first' }));
  const news = items.filter((i) => i.stage === 'new');
  const queue = reviews.splice(0, 3);
  for (let b = 0; b < news.length; b += 5) {
    const group = news.slice(b, b + 5);
    for (const w of group) queue.push({ kind: 'card', wordId: w.id });
    group.forEach((w, i) => {
      queue.push({ kind: 'ex', wordId: w.id, attempt: 'first' });
      if (i % 2 === 1 && reviews.length) queue.push(reviews.shift());
    });
  }
  return queue.concat(reviews);
}
