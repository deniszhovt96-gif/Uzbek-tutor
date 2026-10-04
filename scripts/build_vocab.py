#!/usr/bin/env python3
"""
Сборка словаря для импорта в Supabase.

Вход:
  data/source/vocabulary.xlsx  — исходная таблица (лист `words`), НЕ изменяется
  data/fixes.csv               — утверждённые правки примеров (replace / hide / audio_off)
  data/word_fixes.csv          — правки самих слов: uz / ru (исправление) и off (повреждённая запись — слово отключено)
  data/levels.csv              — уровень CEFR по каждому слову (перепроверка 04.10.2026; в источнике уровень стоял по теме)
  data/source/colloquial.json  — разговорная лексика Ташкента (отдельные темы «Разговорная речь. …», ID с 20001)

Выход (data/build/):
  topics.csv, words.csv, examples.csv — данные для загрузки (scripts/load_vocab.sql)
  report.md                           — отчёт проверки

Правила нормализации описаны в docs/normalization.md и должны совпадать
с проверкой ответов в приложении и в базе.
"""
from __future__ import annotations

import csv
import json
import re
import sys
import unicodedata
from collections import defaultdict
from pathlib import Path

import openpyxl

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "data" / "source" / "vocabulary.xlsx"
FIXES = ROOT / "data" / "fixes.csv"
WORD_FIXES = ROOT / "data" / "word_fixes.csv"
LEVELS = ROOT / "data" / "levels.csv"
COLLOQUIAL = ROOT / "data" / "source" / "colloquial.json"
COLLOQ_PREFIX = "Разговорная речь. "
TOPIC_NAMES = ROOT / "data" / "topic_names.csv"   # переводы названий тем: name_ru,name_uz,name_en
AUDIO_VOICED = ROOT / "data" / "audio_voiced.txt"  # файлы, озвученные workflow «Озвучка» (scripts/tts.py)
OUT = ROOT / "data" / "build"

CEFR_RANK = {"A1": 1, "A2": 2, "B1": 3, "B2": 4}
APOSTROPHES = "‘’'ʻʼ`´ʹ"   # ‘ ’ ' ʻ ʼ ` ´ ʹ
OKINA = "ʻ"   # ʻ  — в oʻ, gʻ
TUTUQ = "ʼ"   # ʼ  — tutuq belgisi
CYRILLIC = re.compile("[Ѐ-ӿ]")


# --------------------------------------------------------------------------- нормализация
def display_uz(text: str) -> str:
    """Узбекский текст для показа: апострофы приведены к стандарту (oʻ gʻ, ʼ)."""
    s = unicodedata.normalize("NFC", str(text)).strip()
    s = re.sub(r"\s+", " ", s)
    out = []
    for i, ch in enumerate(s):
        if ch in APOSTROPHES:
            prev = s[i - 1] if i > 0 else ""
            out.append(OKINA if prev in "oOgG" else TUTUQ)
        else:
            out.append(ch)
    return "".join(out)


def key_uz(text: str) -> str:
    """Ключ для сравнения узбекских ответов: регистр, вид апострофа, пунктуация не важны."""
    s = unicodedata.normalize("NFC", str(text)).lower()
    s = "".join("'" if ch in APOSTROPHES else ch for ch in s)
    s = re.sub(r"[^a-z' \-]", " ", s)
    s = s.replace("-", " ")
    s = re.sub(r"\s+", " ", s).strip(" '")
    return s


def key_ru(text: str) -> str:
    """Ключ русского перевода целиком (со скобками): для поиска полных дублей."""
    s = unicodedata.normalize("NFC", str(text)).lower().replace("ё", "е")
    s = re.sub(r"\s+", " ", s).strip()
    s = re.sub(r"[.!?…]+$", "", s).strip()
    return s


def _clean_ru(s: str) -> str:
    s = s.lower().replace("ё", "е")
    s = re.sub(r"[^0-9a-zа-я \-]", " ", s)
    s = s.replace("-", " ")
    return re.sub(r"\s+", " ", s).strip()


def ru_variants(text: str) -> list[str]:
    """Принимаемые варианты русского ответа: без пояснений в скобках, каждый через запятую/;/ и целиком."""
    s = unicodedata.normalize("NFC", str(text))
    no_paren = re.sub(r"\([^)]*\)", " ", s)
    variants = []
    whole = _clean_ru(no_paren)
    if whole:
        variants.append(whole)
    for part in re.split(r"[,;/]", no_paren):
        p = _clean_ru(part)
        if p and p not in variants:
            variants.append(p)
    return variants


def word_class(uz_key: str) -> str:
    last = uz_key.split(" ")[-1] if uz_key else ""
    if last.endswith("moq") or last.endswith("mak"):
        return "verb"
    if " " in uz_key:
        return "phrase"
    return "other"


# --------------------------------------------------------------------------- пропуск в примере
TOKEN_CHARS = "a-zʻʼ"


def find_blank(sentence: str, word_display: str) -> tuple[int, int] | None:
    """Позиция части предложения, которую закрываем в «вставь слово».

    1) слово целиком (или фраза целиком);
    2) слово + аффикс (kitob → kitobni), только для слов длиной ≥ 3;
    3) основа глагола + аффикс (bormoq → boraman), основа длиной ≥ 3.
    Закрывается само слово/основа, аффикс остаётся видимым.
    """
    low = sentence.lower()
    w = word_display.lower().strip(" .!?")
    if not w:
        return None
    left = rf"(?<![{TOKEN_CHARS}])"
    m = re.search(left + re.escape(w) + rf"(?![{TOKEN_CHARS}])", low)
    if m:
        return m.start(), len(w)
    if " " not in w and len(w) >= 3:
        m = re.search(left + re.escape(w) + rf"(?=[{TOKEN_CHARS}])", low)
        if m:
            return m.start(), len(w)
    stem = re.sub(r"(moq|mak)$", "", w)
    if stem != w and len(stem) >= 3:
        m = re.search(left + re.escape(stem) + rf"(?=[{TOKEN_CHARS}])", low)
        if m:
            return m.start(), len(stem)
    return None


# --------------------------------------------------------------------------- чтение
def read_source():
    wb = openpyxl.load_workbook(SRC, read_only=True, data_only=True)
    ws = wb["words"]
    rows = ws.iter_rows(values_only=True)
    header = [re.sub(r"[\s|]+", "", str(h or "")) for h in next(rows)]
    idx = {h: i for i, h in enumerate(header)}
    need = ["ID", "Тема", "Русский", "Узбекский(латиница)", "Уровень"] + \
           [f"ex{k}" for k in range(1, 6)] + [f"ex{k}_ru" for k in range(1, 6)]
    missing = [n for n in need if n not in idx]
    if missing:
        sys.exit(f"В листе words нет колонок: {missing}. Заголовки: {header}")
    data = []
    for r in rows:
        if r is None or r[idx["ID"]] in (None, ""):
            continue
        get = lambda name: r[idx[name]]
        data.append({
            "id": int(float(get("ID"))),
            "topic": str(get("Тема")).strip(),
            "topic_no": get("Тема№") if "Тема№" in idx else None,
            "ru": str(get("Русский")).strip(),
            "uz": str(get("Узбекский(латиница)")).strip(),
            "cefr": str(get("Уровень")).strip(),
            "ex": [(get(f"ex{k}"), get(f"ex{k}_ru")) for k in range(1, 6)],
        })
    return data


def read_fixes():
    fixes = []
    with open(FIXES, encoding="utf-8") as f:
        for row in csv.DictReader(f):
            row["word_id"] = int(row["word_id"])
            fixes.append(row)
    return fixes


def apply_word_fixes(data):
    """Исправления слов. Старое значение сверяется с источником — если источник изменился, сборка останавливается."""
    by_id = {d["id"]: d for d in data}
    off, changed = set(), set()
    if not WORD_FIXES.exists():
        return data, changed
    with open(WORD_FIXES, encoding="utf-8") as f:
        for row in csv.DictReader(f):
            wid, field = int(row["word_id"]), row["field"]
            d = by_id.get(wid)
            if d is None:
                sys.exit(f"word_fixes.csv: нет слова с ID {wid}")
            cur = display_uz(d["uz"]) if field in ("uz", "off") else d["ru"]
            if cur.strip() != row["old"].strip():
                sys.exit(f"word_fixes.csv: {wid}/{field} в источнике изменилось: ожидалось {row['old']!r}, в файле {cur!r}")
            if field == "off":
                off.add(wid)
            elif field == "uz":
                d["uz"] = row["new"]
                changed.add(wid)          # аудио слова записано для старого текста — отключаем
            elif field == "ru":
                d["ru"] = row["new"]
            else:
                sys.exit(f"word_fixes.csv: неизвестное поле {field}")
    return [d for d in data if d["id"] not in off], changed


def apply_levels(data):
    if not LEVELS.exists():
        return 0
    by_id = {d["id"]: d for d in data}
    n = 0
    with open(LEVELS, encoding="utf-8") as f:
        for row in csv.DictReader(f):
            d = by_id.get(int(row["word_id"]))
            if d is None:
                continue                  # слово отключено правкой
            if row["new"] not in CEFR_RANK:
                sys.exit(f"levels.csv: неизвестный уровень {row['new']} у {row['word_id']}")
            d["cefr"] = row["new"]
            d["level_fixed"] = True
            n += 1
    return n


def read_colloquial(existing_keys):
    """Разговорная лексика: слово + литературный вариант + пометка; до двух примеров. Без аудио."""
    if not COLLOQUIAL.exists():
        return [], []
    items = json.loads(COLLOQUIAL.read_text(encoding="utf-8"))
    out, skipped = [], []
    for e in items:
        if key_uz(e["uz"]) in existing_keys:
            skipped.append(e["uz"])      # такое слово уже есть в словаре
            continue
        ex = [(e.get("ex_uz"), e.get("ex_ru")), (e.get("ex2_uz"), e.get("ex2_ru"))]
        out.append({
            "id": int(e["id"]), "topic": COLLOQ_PREFIX + e["topic"].strip(), "topic_no": None,
            "ru": e["ru"].strip(), "uz": e["uz"].strip(), "cefr": e["cefr"],
            "ex": [x for x in ex if x[0] and x[1]],
            "register": "colloquial", "literary": e.get("literary") or "", "note": e.get("note") or "",
            "en": e.get("en") or "", "level_fixed": True,
        })
    return out, skipped


def csv_array(items) -> str:
    """Массив Postgres в текстовом формате для COPY CSV: {"a","b"}."""
    esc = ['"' + str(x).replace("\\", "\\\\").replace('"', '\\"') + '"' for x in items]
    return "{" + ",".join(esc) + "}"


# --------------------------------------------------------------------------- сборка
def main():
    data = read_source()
    data, uz_changed = apply_word_fixes(data)
    n_levels = apply_levels(data)
    colloq, colloq_skipped = read_colloquial({key_uz(d["uz"]) for d in data})
    data += colloq
    by_id = {d["id"]: d for d in data}
    problems = []
    if colloq_skipped:
        problems.append(f"Разговорная лексика: пропущено (уже есть в словаре): {', '.join(colloq_skipped)}")

    # -- правки
    hidden, audio_off_ex, edited = set(), set(), set()
    for fx in read_fixes():
        wid, field, action = fx["word_id"], fx["field"], fx["action"]
        d = by_id.get(wid)
        if d is None:
            sys.exit(f"fixes.csv: нет слова с ID {wid}")
        if action == "audio_off":
            n = int(re.match(r"ex(\d)_audio", field).group(1))
            audio_off_ex.add((wid, n))
            continue
        n = int(re.match(r"ex(\d)$", field).group(1))
        cur = d["ex"][n - 1][0]
        if str(cur).strip() != fx["old"].strip():
            sys.exit(f"fixes.csv: текст {wid}/{field} в источнике изменился — проверьте правку.\n"
                     f"  ожидалось: {fx['old']}\n  в файле:   {cur}")
        if action == "hide":
            hidden.add((wid, n))
        elif action == "replace":
            d["ex"][n - 1] = (fx["new"], d["ex"][n - 1][1])
            edited.add((wid, n))
        else:
            sys.exit(f"fixes.csv: неизвестное действие {action}")

    # -- темы: по названию, порядок по первому слову
    topics = {}
    for d in sorted(data, key=lambda x: x["id"]):
        t = topics.setdefault(d["topic"], {"name": d["topic"], "first": d["id"], "cefr": set(), "no": d["topic_no"]})
        t["cefr"].add(d["cefr"])
    for i, t in enumerate(sorted(topics.values(), key=lambda t: t["first"]), start=1):
        t["id"] = i
        t["cefr"] = min(t["cefr"], key=lambda c: CEFR_RANK.get(c, 9))

    # -- слова
    for d in data:
        if d["cefr"] not in CEFR_RANK:
            sys.exit(f"Слово {d['id']}: неизвестный уровень {d['cefr']}")
        d["uz_disp"] = display_uz(d["uz"])
        d["uz_key"] = key_uz(d["uz"])
        d["ru_key"] = key_ru(d["ru"])
        d["ru_vars"] = ru_variants(d["ru"])
        d["ru_whole"] = d["ru_vars"][0] if d["ru_vars"] else ""
        d["class"] = word_class(d["uz_key"])
        if not d["uz_key"] or not d["ru_vars"]:
            problems.append(f"Слово {d['id']}: пустой ключ ({d['uz']!r} / {d['ru']!r})")
        if CYRILLIC.search(d["uz"]):
            problems.append(f"Слово {d['id']}: кириллица в узбекском слове {d['uz']!r}")

    # полные дубли (узб. + рус. совпадают) → одна карточка: основная = та, что раньше
    # всех в порядке изучения (CEFR → тема → ID), чтобы слово не откладывалось до B2
    learn_pos = lambda i: (CEFR_RANK[by_id[i]["cefr"]], topics[by_id[i]["topic"]]["id"], i)
    groups = defaultdict(list)
    for d in data:
        groups[(d["uz_key"], d["ru_key"])].append(d["id"])
    # уровень перепроверялся по основной карточке — дубли получают тот же уровень
    for ids in groups.values():
        fixed = [by_id[i]["cefr"] for i in ids if by_id[i].get("level_fixed")]
        if fixed:
            lvl = min(fixed, key=lambda c: CEFR_RANK[c])
            for i in ids:
                by_id[i]["cefr"] = lvl
    for ids in groups.values():
        main_id = min(ids, key=learn_pos)
        for i in ids:
            by_id[i]["canonical"] = None if i == main_id else main_id

    # принимаемые ответы
    ru_by_uz = defaultdict(list)
    uz_by_ruwhole = defaultdict(list)
    for d in data:
        for v in d["ru_vars"]:
            if v not in ru_by_uz[d["uz_key"]]:
                ru_by_uz[d["uz_key"]].append(v)
        if d["uz_key"] not in uz_by_ruwhole[d["ru_whole"]]:
            uz_by_ruwhole[d["ru_whole"]].append(d["uz_key"])
    for d in data:
        d["accept_ru"] = ru_by_uz[d["uz_key"]]
        d["accept_uz"] = uz_by_ruwhole[d["ru_whole"]]

    # порядок изучения: CEFR → тема → ID
    order = sorted(data, key=lambda d: (CEFR_RANK[d["cefr"]], topics[d["topic"]]["id"], d["id"]))
    for i, d in enumerate(order, start=1):
        d["sort_key"] = i

    # -- примеры
    examples = []
    blank_stats = defaultdict(int)
    for d in data:
        for n, (uz, ru) in enumerate(d["ex"], start=1):
            if uz in (None, "") or ru in (None, ""):
                problems.append(f"Слово {d['id']}: пустой пример {n}")
                continue
            uz_disp = display_uz(uz)
            is_hidden = (d["id"], n) in hidden
            if CYRILLIC.search(uz_disp) and not is_hidden:
                problems.append(f"Слово {d['id']} пример {n}: кириллица в узбекском тексте: {uz_disp}")
            blank = None if is_hidden else find_blank(uz_disp, d["uz_disp"])
            blank_stats["скрыт" if is_hidden else ("есть пропуск" if blank else "нет пропуска")] += 1
            examples.append({
                "word_id": d["id"], "n": n, "uz": uz_disp, "ru": str(ru).strip(),
                "blank_start": blank[0] if blank else "",
                "blank_len": blank[1] if blank else "",
                "blank_answer": uz_disp[blank[0]:blank[0] + blank[1]] if blank else "",
                "audio_ok": "f" if ((d["id"], n) in audio_off_ex or (d["id"], n) in edited or is_hidden
                                  or d.get("register") == "colloquial") else "t",
                "is_hidden": "t" if is_hidden else "f",
            })

    # -- переводы названий тем и дозаписанное аудио
    topic_tr = {}
    if TOPIC_NAMES.exists():
        with open(TOPIC_NAMES, encoding="utf-8") as f:
            topic_tr = {r["name_ru"]: r for r in csv.DictReader(f)}
    missing_tr = [t["name"] for t in topics.values() if t["name"] not in topic_tr]
    if missing_tr:
        problems.append(f"Нет перевода названия темы: {', '.join(missing_tr)}")
    voiced = set()
    if AUDIO_VOICED.exists():
        voiced = {x.strip() for x in AUDIO_VOICED.read_text(encoding="utf-8").split() if x.strip()}
    for e in examples:
        if e["audio_ok"] == "f" and e["is_hidden"] == "f" and f"word_{e['word_id']}_ex{e['n']}.mp3" in voiced:
            e["audio_ok"] = "t"

    # -- запись
    OUT.mkdir(parents=True, exist_ok=True)
    with open(OUT / "topics.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["id", "source_no", "name_ru", "name_uz", "name_en", "cefr", "sort_order"])
        for t in sorted(topics.values(), key=lambda t: t["id"]):
            no = t["no"]
            try:
                no = int(float(no)) if no not in (None, "") else ""
            except ValueError:
                no = ""
            tr = topic_tr.get(t["name"], {})
            w.writerow([t["id"], no, t["name"], tr.get("name_uz", ""), tr.get("name_en", ""), t["cefr"], t["id"]])
    with open(OUT / "words.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["id", "topic_id", "cefr", "uz", "ru", "uz_key", "accept_ru", "accept_uz",
                    "word_class", "canonical_id", "audio_ok", "sort_key", "register", "literary", "note", "en"])
        for d in sorted(data, key=lambda x: x["id"]):
            audio = "f" if (d["id"] in uz_changed or d.get("register") == "colloquial") else "t"
            if f"word_{d['id']}.mp3" in voiced:
                audio = "t"
            w.writerow([d["id"], topics[d["topic"]]["id"], d["cefr"], d["uz_disp"], d["ru"], d["uz_key"],
                        csv_array(d["accept_ru"]), csv_array(d["accept_uz"]), d["class"],
                        d["canonical"] if d["canonical"] else "", audio, d["sort_key"],
                        d.get("register", "lit"), display_uz(d["literary"]) if d.get("literary") else "",
                        d.get("note", ""), d.get("en", "")])
    with open(OUT / "examples.csv", "w", newline="", encoding="utf-8") as f:
        cols = ["word_id", "n", "uz", "ru", "blank_start", "blank_len", "blank_answer", "audio_ok", "is_hidden"]
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        w.writerows(examples)

    # -- отчёт
    n_alias = sum(1 for d in data if d["canonical"])
    classes = defaultdict(int)
    for d in data:
        classes[d["class"]] += 1
    lines = [
        "# Отчёт сборки словаря", "",
        f"- Слов: **{len(data)}** (основных карточек: {len(data) - n_alias}, полных дублей: {n_alias})",
        f"- Тем: **{len(topics)}**",
        f"- Примеров: **{len(examples)}** — " + ", ".join(f"{k}: {v}" for k, v in sorted(blank_stats.items())),
        f"- Правки: заменено {len(edited)}, скрыто {len(hidden)}, аудио отключено {len(audio_off_ex | edited | hidden)}",
        f"- Правки слов: исправлено узб. {len(uz_changed)}, уровней из levels.csv {n_levels}, "
        f"разговорных {len(colloq)}",
        f"- Классы слов: " + ", ".join(f"{k}: {v}" for k, v in sorted(classes.items())),
        f"- По уровням: " + ", ".join(f"{c}: {sum(1 for d in data if d['cefr'] == c)}" for c in CEFR_RANK),
        "", "## Проблемы", "",
    ]
    lines += [f"- {p}" for p in problems] or ["- нет"]
    lines += ["", "## Примеры (первые 5 слов в порядке изучения)", ""]
    for d in order[:5]:
        ex = next(e for e in examples if e["word_id"] == d["id"] and e["n"] == 1)
        lines.append(f"- {d['id']}: **{d['uz_disp']}** — {d['ru']} | принимается: {', '.join(d['accept_ru'])} | "
                     f"пример: {ex['uz']} | пропуск: «{ex['blank_answer']}»")
    (OUT / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))
    if problems:
        print(f"\nВНИМАНИЕ: найдено проблем: {len(problems)} (см. выше)")


if __name__ == "__main__":
    main()
