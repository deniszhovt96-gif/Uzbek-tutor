#!/usr/bin/env python3
"""Курсы «Грамматика», «История», «Обществознание», «Культура»: xlsx → SQL (повторный запуск безопасен, прогресс сохраняется).

Запуск:  python3 scripts/build_courses.py data/source data/build/courses.sql
Файлы:   data/source/grammar.xlsx, history.xlsx, civics.xlsx (имена — как ниже в SOURCES).

Что делает:
  • темы (кратко / подробно на RU-UZ-EN, источник), 5 заданий на тему (без ответов → «открытые»);
  • разделы, периоды истории, хронология, справочник контактов, базовая лексика грамматики;
  • апострофы узбекского текста приводятся к oʻ gʻ ʼ (как в словаре);
  • к темам грамматики — шаблоны поиска примеров в словаре (GRAMMAR_PATTERNS), их можно менять.
"""
import json
import re
import sys
from pathlib import Path

import openpyxl

SOURCES = {'grammar': 'grammar.xlsx', 'history': 'history.xlsx', 'civics': 'civics.xlsx', 'culture': 'culture.xlsx'}

SECTION_TR = {
    'Фонетика': ('Fonetika', 'Phonetics'),
    'Морфология: имя': ('Morfologiya: ism', 'Morphology: nominals'),
    'Морфология: местоимения': ('Morfologiya: olmoshlar', 'Morphology: pronouns'),
    'Морфология: глагол': ('Morfologiya: feʼl', 'Morphology: the verb'),
    'Синтаксис': ('Sintaksis', 'Syntax'),
    'Государство и право': ('Davlat va huquq', 'State and law'),
    'Право в повседневной жизни': ('Kundalik hayotda huquq', 'Law in everyday life'),
    'Для иностранцев в Узбекистане': ('Oʻzbekistondagi chet elliklar uchun', 'For foreigners in Uzbekistan'),
    'Обществознание': ('Jamiyatshunoslik', 'Social studies'),
    'Гостеприимство и повседневная жизнь': ('Mehmondoʻstlik va kundalik hayot', 'Hospitality and everyday life'),
    'Семейные обряды': ('Oilaviy marosimlar', 'Family rituals'),
    'Праздники': ('Bayramlar', 'Holidays'),
    'Ремёсла, одежда и искусство': ('Hunarmandchilik, kiyim va sanʼat', 'Crafts, clothing and art'),
}
SECTION_ORDER = {
    'grammar': ['Фонетика', 'Морфология: имя', 'Морфология: местоимения', 'Морфология: глагол', 'Синтаксис'],
    'civics': ['Государство и право', 'Право в повседневной жизни', 'Для иностранцев в Узбекистане', 'Обществознание'],
    'culture': ['Гостеприимство и повседневная жизнь', 'Семейные обряды', 'Праздники', 'Ремёсла, одежда и искусство'],
}

# Названия тем грамматики на узбекском и английском (в файле одно поле «Тема (RU / UZ / EN)»)
GRAMMAR_TITLES = {
    1: ('Oʻzbek alifbosi', 'The Uzbek alphabet'),
    2: ('Kishilik olmoshlari', 'Personal pronouns'),
    3: ('Hozirgi-kelasi zamon (-a/-y)', 'Present-future tense (-a/-y)'),
    4: ('-mi soʻroq yuklamasi', 'The question particle -mi'),
    5: ('Oʻtgan aniq zamon (-di)', 'Definite past tense (-di)'),
    6: ('Oʻtgan noaniq zamon (-gan)', 'Indefinite past tense (-gan)'),
    7: ('Aniq hozirgi zamon (-yap)', 'Present continuous tense (-yap)'),
    8: ('Feʼlning boʻlishsiz shakli (-ma)', 'Negative verb form (-ma)'),
    9: ('Kelishiklar: 6 kelishik', 'The case system: 6 cases'),
    10: ('Egalik qoʻshimchalari', 'Possessive affixes'),
    11: ('Koʻplik qoʻshimchasi -lar', 'Plural affix -lar'),
    12: ('Sifat va sifat darajalari', 'Adjectives and degrees of comparison'),
    13: ('Son: sanoq va tartib sonlar', 'Numerals: cardinal and ordinal'),
    14: ('Koʻmakchilar', 'Postpositions'),
    15: ('Koʻrsatish va soʻroq olmoshlari', 'Demonstrative and interrogative pronouns'),
    16: ('Buyruq-istak mayli', 'Imperative mood'),
    17: ('Gapda soʻz tartibi (SOV)', 'Word order in a sentence (SOV)'),
    18: ('bor va yoʻq', 'Existence: bor and yoʻq'),
    19: ('Asosiy tovushlar talaffuzi', 'Pronunciation of key sounds'),
    20: ('Bogʻlovchilar', 'Conjunctions'),
}

# Шаблоны поиска примеров в словаре (регулярные выражения PostgreSQL, без учёта регистра).
# \m и \M — начало и конец слова. Буквы oʻ gʻ — с символом ʻ, как в словаре.
GRAMMAR_PATTERNS = {
    1: r'\m\w*(oʻ|gʻ)\w*\M',
    2: r'^(men|sen|u|biz|siz|ular)\M',
    3: r'\m\w{2,}(a|y)(man|san|miz|siz)\M',
    4: r'\m\w+mi\?',
    5: r'\m\w{2,}di(m|ng|k|ngiz|lar)\M',
    6: r'\m\w{2,}(g|k|q)an(man|san|miz|siz)\M|\m\w{2,}(g|k|q)an[.!?]$',
    7: r'\m\w+yap(man|san|ti|miz|siz|tilar)\M',
    8: r'\m\w+(may(man|san|di|miz|siz)|madi(m|ng|k|ngiz|lar)?)\M',
    9: r'\m\w{3,}(ning|ga|ka|qa|da|dan|ni)\M',
    10: r'\m(mening|sening|uning|bizning|sizning|ularning) \w+',
    11: r'\m\w{2,}lar\M',
    12: r'\m\w+roq\M|\meng \w+',
    13: r'\m(bir|ikki|uch|toʻrt|besh|olti|yetti|sakkiz|toʻqqiz|oʻn|yigirma|oʻttiz|qirq|ellik|yuz|ming)\M|\m\w+(i|)nchi\M',
    14: r'\m(bilan|uchun|kabi|haqida|keyin|oldin|qadar|orqali|tomon|sari)\M',
    15: r'\m(bu|shu|ana|mana|kim|nima|qaysi|qanday|qayer\w*|qachon|nega|nimaga|necha)\M',
    16: r'\m\w+[^d](ing|ingiz)!|\m\w+(gin|sin|aylik|ylik)!',
    17: r'^\S+ \S+ \S+(man|san|di|miz|siz|dim|dik)\.$',
    18: r'\m(bor|yoʻq)\M',
    19: r'\m\w*(q|x|gʻ|oʻ)\w*\M',
    20: r'\m(va|lekin|yoki|chunki|ammo|biroq|agar|shuning uchun)\M',
}


def clean(v):
    if v is None:
        return None
    s = str(v).strip()
    if not s or s in ('—', '-'):
        return None
    return s


def uz_apostrophes(s, uz=False):
    """oʻ gʻ — U+02BB (как в словаре); в узбекском тексте ’ ' между буквами — ʼ (U+02BC)."""
    if s is None:
        return None
    marks = r"[‘’`ʼ']" if uz else r'[‘]'    # в русском/английском тексте узбекские слова пишутся с ‘
    s = re.sub(r'([oOgG])' + marks, lambda m: m.group(1) + 'ʻ', s)
    if uz:
        s = re.sub(r'(?<=[A-Za-z])[’\'](?=[A-Za-z])', 'ʼ', s)
    return s


def num(v):
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return None


def q(v):
    """SQL-литерал."""
    if v is None:
        return 'null'
    if isinstance(v, int):
        return str(v)
    s = str(v)
    assert '$q$' not in s
    return f'$q${s}$q$'


def main_rows(path):
    ws = openpyxl.load_workbook(path, data_only=True).worksheets[0]
    rows = list(ws.iter_rows(values_only=True))
    header = [clean(h) for h in rows[3]]
    out = []
    for r in rows[4:]:
        if num(r[0]) is None:
            continue
        out.append(dict(zip(header, r)))
    return header, out


def col(row, *names):
    for n in names:
        if n in row:
            return clean(row[n])
    raise KeyError(names)


def build(src: Path):
    sql = ['-- Сгенерировано scripts/build_courses.py — не править вручную.', 'begin;']
    stats = {}

    for course, fname in SOURCES.items():
        header, rows = main_rows(src / fname)
        stats[course] = {'units': len(rows), 'tasks': 0}
        # разделы
        if course in SECTION_ORDER:
            for i, title in enumerate(SECTION_ORDER[course], 1):
                uz, en = SECTION_TR[title]
                sql.append(
                    f"insert into public.course_sections (course_id, title_ru, title_uz, title_en, sort_order) "
                    f"values ({q(course)}, {q(title)}, {q(uz)}, {q(en)}, {i}) "
                    f"on conflict (course_id, title_ru) do update set title_uz = excluded.title_uz, title_en = excluded.title_en, sort_order = excluded.sort_order;")
            known = set(SECTION_ORDER[course])
            for r in rows:
                sec = col(r, 'Раздел')
                if sec not in known:
                    raise SystemExit(f'{course}: неизвестный раздел «{sec}» — добавьте в SECTION_ORDER и SECTION_TR')

        for r in rows:
            n = num(r['№'])
            if course == 'grammar':
                title_ru = col(r, 'Тема (RU / UZ / EN)')
                title_uz, title_en = GRAMMAR_TITLES.get(n, (None, None))
                ex = ('Экспресс-объяснение (русский)', 'Экспресс-объяснение (o‘zbekcha)', 'Express explanation (English)')
                de = ('Подробное объяснение (русский)', 'Подробное объяснение (o‘zbekcha)', 'Detailed explanation (English)')
                tasks = [(f'Задание {k} (русский)', f'Задание {k} (o‘zbekcha)', f'Task {k} (English)') for k in range(1, 6)]
                period = (None, None, None)
            else:
                title_ru = col(r, 'Тема (русский)')
                title_uz = col(r, 'Mavzu (o‘zbekcha)')
                title_en = col(r, 'Topic (English)')
                ex = ('Экспресс-объяснение (русский)', 'Qisqacha tushuntirish (o‘zbekcha)', 'Express explanation (English)')
                de = ('Подробное объяснение (русский)', 'Batafsil tushuntirish (o‘zbekcha)', 'Detailed explanation (English)')
                tasks = [(f'Задание {k} (русский)', f'Vazifa {k} (o‘zbekcha)', f'Task {k} (English)') for k in range(1, 6)]
                period = (col(r, 'Период'), None, None) if course == 'history' else (None, None, None)

            section = col(r, 'Раздел') if 'Раздел' in r else None
            section_sql = (f"(select id from public.course_sections where course_id = {q(course)} and title_ru = {q(section)})"
                           if section else 'null')
            vals = {
                'title_ru': uz_apostrophes(title_ru), 'title_uz': uz_apostrophes(title_uz, True), 'title_en': uz_apostrophes(title_en),
                'express_ru': uz_apostrophes(clean(r[ex[0]])), 'express_uz': uz_apostrophes(clean(r[ex[1]]), True),
                'express_en': uz_apostrophes(clean(r[ex[2]])),
                'detailed_ru': uz_apostrophes(clean(r[de[0]])), 'detailed_uz': uz_apostrophes(clean(r[de[1]]), True),
                'detailed_en': uz_apostrophes(clean(r[de[2]])),
                'source': clean(r.get('Источник / материал')),
                'period': period[0],
                'example_pattern': GRAMMAR_PATTERNS.get(n) if course == 'grammar' else None,
            }
            cols = ', '.join(vals)
            sql.append(
                f"insert into public.course_units (course_id, source_no, section_id, sort_order, {cols}) values "
                f"({q(course)}, {n}, {section_sql}, {n}, {', '.join(q(v) for v in vals.values())}) "
                f"on conflict (course_id, source_no) do update set section_id = excluded.section_id, sort_order = excluded.sort_order, "
                + ', '.join(f'{k} = excluded.{k}' for k in vals) + ';')
            unit_sql = f"(select id from public.course_units where course_id = {q(course)} and source_no = {n})"
            for k, (ru, uz, en) in enumerate(tasks, 1):
                pr, pu, pe = clean(r.get(ru)), clean(r.get(uz)), clean(r.get(en))
                if not pr:
                    continue
                stats[course]['tasks'] += 1
                sql.append(
                    f"insert into public.unit_tasks (unit_id, n, kind, prompt_ru, prompt_uz, prompt_en, origin, status) values "
                    f"({unit_sql}, {k}, 'open', {q(uz_apostrophes(pr))}, {q(uz_apostrophes(pu, True))}, {q(uz_apostrophes(pe))}, 'source', 'approved') "
                    f"on conflict (unit_id, n) do update set prompt_ru = excluded.prompt_ru, prompt_uz = excluded.prompt_uz, prompt_en = excluded.prompt_en "
                    f"where public.unit_tasks.origin = 'source';")
            # лишние темы, удалённые из файла, остаются в базе — удаляйте вручную, чтобы не потерять прогресс

    # ---- хронология истории
    wb = openpyxl.load_workbook(src / SOURCES['history'], data_only=True)
    ws = wb['Хронология (сводная таблица)']
    n_tl = 0
    for r in list(ws.iter_rows(values_only=True))[1:]:
        k = num(r[0])
        if k is None:
            continue
        n_tl += 1
        sql.append(
            f"insert into public.timeline_events (course_id, date_label, text_ru, text_uz, text_en, sort_order) values "
            f"('history', {q(clean(r[1]))}, {q(uz_apostrophes(clean(r[2])))}, {q(uz_apostrophes(clean(r[3]), True))}, {q(uz_apostrophes(clean(r[4])))}, {k}) "
            f"on conflict (course_id, sort_order) do update set date_label = excluded.date_label, text_ru = excluded.text_ru, "
            f"text_uz = excluded.text_uz, text_en = excluded.text_en;")
    stats['history']['timeline'] = n_tl

    # ---- справочник контактов (обществознание)
    ws = openpyxl.load_workbook(src / SOURCES['civics'], data_only=True)['Справочник контактов']
    n_c = 0
    for r in list(ws.iter_rows(values_only=True))[1:]:
        k = num(r[0])
        if k is None:
            continue
        n_c += 1
        sql.append(
            f"insert into public.reference_items (course_id, kind, title_ru, title_uz, title_en, value, sort_order) values "
            f"('civics', 'contact', {q(clean(r[1]))}, {q(uz_apostrophes(clean(r[2]), True))}, {q(clean(r[3]))}, {q(clean(r[4]))}, {k}) "
            f"on conflict (course_id, kind, sort_order) do update set title_ru = excluded.title_ru, title_uz = excluded.title_uz, "
            f"title_en = excluded.title_en, value = excluded.value;")
    stats['civics']['contacts'] = n_c

    # ---- базовая лексика (грамматика)
    ws = openpyxl.load_workbook(src / SOURCES['grammar'], data_only=True)['Базовая лексика (уроки 1–6)']
    n_v = 0
    for r in list(ws.iter_rows(values_only=True))[1:]:
        k = num(r[0])
        if k is None:
            continue
        n_v += 1
        extra = {'transcription': clean(r[2]), 'example': uz_apostrophes(clean(r[5]))}
        sql.append(
            f"insert into public.reference_items (course_id, kind, title_ru, title_uz, title_en, value, extra, sort_order) values "
            f"('grammar', 'vocab', {q(clean(r[3]))}, {q(uz_apostrophes(clean(r[1]), True))}, {q(clean(r[4]))}, {q(uz_apostrophes(clean(r[1]), True))}, "
            f"{q(json.dumps(extra, ensure_ascii=False))}::jsonb, {k}) "
            f"on conflict (course_id, kind, sort_order) do update set title_ru = excluded.title_ru, title_uz = excluded.title_uz, "
            f"title_en = excluded.title_en, value = excluded.value, extra = excluded.extra;")
    stats['grammar']['vocab'] = n_v

    # ---- вопросы для тестов по темам (черновики; публикует администратор в приложении)
    qpath = src.parent / 'quiz' / 'questions.json'
    n_q = 0
    if qpath.exists():
        for qq in json.loads(qpath.read_text(encoding='utf-8')):
            n_q += 1
            unit_sql = f"(select id from public.course_units where course_id = {q(qq['course'])} and source_no = {int(qq['n'])})"
            options = json.dumps({'ru': qq['options_ru'], 'uz': qq['options_uz'], 'en': qq['options_en']}, ensure_ascii=False)
            sql.append(
                f"insert into public.unit_tasks (unit_id, n, kind, prompt_ru, prompt_uz, prompt_en, options, answer, source_quote, origin, status) values "
                f"({unit_sql}, {100 + int(qq['k'])}, 'choice', {q(qq['q_ru'])}, {q(qq['q_uz'])}, {q(qq['q_en'])}, {q(options)}::jsonb, '0'::jsonb, "
                f"{q(qq['quote_ru'])}, 'generated', 'draft') "
                # изменился текст вопроса — снова на проверку; не изменился — статус сохраняется
                f"on conflict (unit_id, n) do update set "
                f"status = case when public.unit_tasks.prompt_ru is distinct from excluded.prompt_ru "
                f"or public.unit_tasks.options is distinct from excluded.options then 'draft' else public.unit_tasks.status end, "
                f"prompt_ru = excluded.prompt_ru, prompt_uz = excluded.prompt_uz, prompt_en = excluded.prompt_en, "
                f"options = excluded.options, answer = excluded.answer, source_quote = excluded.source_quote, kind = excluded.kind;")
    stats['quiz'] = {'questions': n_q}

    sql.append('commit;')
    return '\n'.join(sql) + '\n', stats


if __name__ == '__main__':
    src = Path(sys.argv[1] if len(sys.argv) > 1 else 'data/source')
    out = Path(sys.argv[2] if len(sys.argv) > 2 else 'data/build/courses.sql')
    out.parent.mkdir(parents=True, exist_ok=True)
    text, stats = build(src)
    out.write_text(text, encoding='utf-8')
    for c, s in stats.items():
        print(c, ', '.join(f'{k}: {v}' for k, v in s.items()))
    print(f'→ {out} ({len(text) // 1024} КБ)')
