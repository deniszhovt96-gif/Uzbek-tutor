#!/usr/bin/env python3
"""Озвучка слов и примеров, у которых ещё нет аудио (запускается workflow «Озвучка» в GitHub Actions).

Что озвучивается — ровно то, что приложение показывает без кнопки звука:
  • разговорная лексика (слова и примеры),
  • слова, исправленные в data/word_fixes.csv (старое аудио записано для неверного текста),
  • примеры, изменённые в data/fixes.csv.
Список берётся из data/build/words.csv и examples.csv (результат scripts/build_vocab.py): строки с audio_ok = f,
кроме скрытых примеров и уже озвученных файлов из data/audio_voiced.txt.

Голос: бесплатная озвучка Google (как у исходных файлов, библиотека gTTS, язык uz). Если Google не принимает
узбекский, используется голос Microsoft (edge-tts, uz-UZ-MadinaNeural / uz-UZ-SardorNeural).
Имена файлов — как в приложении: word_<id>.mp3 и word_<id>_ex<n>.mp3.

Запуск: python3 scripts/tts.py --out out/audio [--engine gtts|edge] [--voice uz-UZ-MadinaNeural] [--limit 700]
Готовые имена дописываются в data/audio_voiced.txt — повторный запуск продолжает с того места, где остановился.
"""
import argparse
import asyncio
import csv
import random
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "data" / "build"
VOICED = ROOT / "data" / "audio_voiced.txt"


def speakable(text: str) -> str:
    """Для синтеза: стандартные узбекские апострофы oʻ → o‘, tutuq ʼ → ’ (так их читает Google)."""
    return str(text).replace("ʻ", "‘").replace("ʼ", "’").strip()


def todo_list():
    voiced = set()
    if VOICED.exists():
        voiced = {x.strip() for x in VOICED.read_text(encoding="utf-8").split() if x.strip()}
    items = []
    with open(BUILD / "words.csv", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            name = f"word_{r['id']}.mp3"
            if r["audio_ok"] == "f" and name not in voiced:
                items.append((name, r["uz"]))
    with open(BUILD / "examples.csv", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            name = f"word_{r['word_id']}_ex{r['n']}.mp3"
            if r["audio_ok"] == "f" and r["is_hidden"] == "f" and name not in voiced:
                items.append((name, r["uz"]))
    return items


def gtts_ok() -> bool:
    try:
        from gtts.lang import tts_langs
        return "uz" in tts_langs()
    except Exception as e:  # noqa: BLE001
        print("gTTS недоступен:", e)
        return False


def say_gtts(text: str, path: Path):
    from gtts import gTTS
    gTTS(speakable(text), lang="uz").save(str(path))


def say_edge(text: str, path: Path, voice: str):
    import edge_tts
    asyncio.run(edge_tts.Communicate(speakable(text), voice).save(str(path)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="out/audio")
    ap.add_argument("--engine", default="gtts", choices=["gtts", "edge"])
    ap.add_argument("--voice", default="uz-UZ-MadinaNeural")
    ap.add_argument("--limit", type=int, default=1000, help="не больше стольких файлов за запуск (защита от лимитов сервиса)")
    a = ap.parse_args()

    items = todo_list()
    print(f"Без аудио: {len(items)} файлов; за этот запуск — до {a.limit}")
    if not items:
        return
    engine = a.engine
    if engine == "gtts" and not gtts_ok():
        print("Google не озвучивает узбекский через gTTS — переключаюсь на голос Microsoft", a.voice)
        engine = "edge"

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    done, failed = [], []
    for k, (name, text) in enumerate(items[: a.limit], start=1):
        path = out / name
        for attempt in range(4):
            try:
                if engine == "gtts":
                    say_gtts(text, path)
                else:
                    say_edge(text, path, a.voice)
                if path.stat().st_size < 500:
                    raise RuntimeError("слишком короткий файл")
                done.append(name)
                break
            except Exception as e:  # noqa: BLE001 — сеть, лимит запросов: ждём и пробуем снова
                wait = 5 * (attempt + 1) + random.random() * 3
                print(f"  {name}: {e} — повтор через {wait:.0f} c")
                time.sleep(wait)
        else:
            failed.append(name)
        if engine == "gtts":
            time.sleep(0.4 + random.random() * 0.4)     # бережно к бесплатному сервису
        if k % 50 == 0:
            print(f"  {k}/{min(len(items), a.limit)}")
            # сохраняем по ходу: если запуск прервётся, готовое не потеряется
            with open(VOICED, "a", encoding="utf-8") as f:
                f.write("".join(n + "\n" for n in done))
            done = []

    with open(VOICED, "a", encoding="utf-8") as f:
        f.write("".join(n + "\n" for n in done))
    left = len(items) - min(len(items), a.limit) + len(failed)
    print(f"Готово. Голос: {'Google (gTTS)' if engine == 'gtts' else 'Microsoft ' + a.voice}. Ошибок: {len(failed)}. Осталось: {left}")
    if failed:
        print("Не получилось:", ", ".join(failed[:30]))
    if failed and len(failed) == min(len(items), a.limit):
        sys.exit(1)


if __name__ == "__main__":
    main()
