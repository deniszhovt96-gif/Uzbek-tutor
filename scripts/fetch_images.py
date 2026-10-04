#!/usr/bin/env python3
"""Иллюстрации к темам курсов из Wikimedia Commons (запускается в GitHub Actions перед сборкой приложения).

Вход:  data/images.json — для каждой темы кандидаты: поисковый запрос (q), обязательные слова в имени файла (must),
       подписи RU/UZ/EN; можно закрепить конкретный файл ключом "file": "File:Имя.jpg".
Выход: app/public/img/<курс>-<номер>.<jpg|png> и app/public/img/manifest.json (автор, лицензия, ссылка, подписи).
Берутся только свободные лицензии (public domain, CC0, CC BY, CC BY-SA). Ошибки сети не останавливают сборку:
у темы просто не будет картинки. Итоговая таблица пишется в $GITHUB_STEP_SUMMARY.
"""
import html
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

API = 'https://commons.wikimedia.org/w/api.php'
UA = 'UzbekTutorBot/1.0 (https://github.com/deniszhovt96-gif/Uzbek-tutor; Telegram Mini App images)'
FREE = re.compile(r'^(public domain|pd\b|pd-|cc0|cc[- ]by(-sa)?\b|cc[- ]by(-sa)?[- ]\d)', re.I)
WIDTH = 1200


def get(params):
    url = API + '?' + urllib.parse.urlencode({**params, 'format': 'json', 'formatversion': '2'})
    req = urllib.request.Request(url, headers={'User-Agent': UA})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def strip(s):
    return html.unescape(re.sub(r'<[^>]+>', '', s or '')).strip()


def info(title):
    d = get({'action': 'query', 'titles': title, 'prop': 'imageinfo',
             'iiprop': 'url|size|extmetadata|mime', 'iiurlwidth': WIDTH})
    pages = d.get('query', {}).get('pages', [])
    if not pages or 'imageinfo' not in pages[0]:
        return None
    ii = pages[0]['imageinfo'][0]
    meta = ii.get('extmetadata', {})
    return {
        'title': pages[0]['title'], 'width': ii.get('width', 0), 'height': ii.get('height', 0), 'mime': ii.get('mime', ''),
        'thumb': ii.get('thumburl') or ii.get('url'), 'page': ii.get('descriptionurl'),
        'license': strip(meta.get('LicenseShortName', {}).get('value')),
        'author': strip(meta.get('Artist', {}).get('value'))[:80],
        'nonfree': str(meta.get('NonFree', {}).get('value', '')).lower() == 'true',
        'restrictions': strip(meta.get('Restrictions', {}).get('value')),
    }


def acceptable(i, cand, used):
    if not i or i['title'] in used or i['nonfree'] or not FREE.search(i['license'] or ''):
        return False
    if 'trademark' in (i['restrictions'] or '').lower():
        return False
    if not i['mime'].startswith('image/') or i['mime'] == 'image/gif':
        return False
    svg = i['mime'] == 'image/svg+xml'
    if not svg and (i['width'] < 800 or i['height'] < 400):
        return False
    ratio = i['width'] / max(i['height'], 1)
    return 0.9 <= ratio <= 2.4


def search(q, limit=25):
    d = get({'action': 'query', 'list': 'search', 'srnamespace': 6, 'srsearch': f'{q} filetype:bitmap', 'srlimit': limit})
    return [r['title'] for r in d.get('query', {}).get('search', [])]


def pick(cand, used):
    titles = [cand['file']] if cand.get('file') else search(cand['q'])
    must = [m.lower() for m in cand.get('must', [])]
    for t in titles:
        if must and not any(m in t.lower() for m in must):
            continue
        try:
            i = info(t)
        except Exception as e:  # noqa: BLE001
            print('  info failed', t, e)
            continue
        time.sleep(0.15)
        if acceptable(i, cand, used):
            return i
    return None


def download(url, path):
    req = urllib.request.Request(url, headers={'User-Agent': UA})
    with urllib.request.urlopen(req, timeout=60) as r:
        path.write_bytes(r.read())


def main():
    root = Path(__file__).resolve().parent.parent
    spec = json.loads((root / 'data' / 'images.json').read_text(encoding='utf-8'))
    out = root / 'app' / 'public' / 'img'
    out.mkdir(parents=True, exist_ok=True)
    manifest, used, rows = {}, set(), []
    for course, topics in spec.items():
        for n, cands in topics.items():
            key = f'{course}-{n}'
            chosen, cand = None, None
            for cand in cands:
                try:
                    chosen = pick(cand, used)
                except Exception as e:  # noqa: BLE001
                    print('  search failed', key, e)
                if chosen:
                    break
            if not chosen:
                rows.append(f'| {key} | — | не найдено | |')
                continue
            used.add(chosen['title'])
            ext = '.png' if chosen['thumb'].lower().endswith('.png') or chosen['mime'] in ('image/png', 'image/svg+xml') else '.jpg'
            fname = key + ext
            try:
                download(chosen['thumb'], out / fname)
            except Exception as e:  # noqa: BLE001
                print('  download failed', key, e)
                fname = None
            manifest[key] = {
                'file': fname, 'remote': chosen['thumb'], 'page': chosen['page'], 'title': chosen['title'],
                'author': chosen['author'], 'license': chosen['license'],
                'caption_ru': cand['caption_ru'], 'caption_uz': cand['caption_uz'], 'caption_en': cand['caption_en'],
            }
            rows.append(f"| {key} | [{chosen['title'][5:]}]({chosen['page']}) | {chosen['license']} | {chosen['author']} |")
            print(key, chosen['title'], chosen['license'])
    (out / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=1), encoding='utf-8')
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    table = '\n'.join(['## Иллюстрации к темам', '', f'Найдено: {len(manifest)} из {sum(len(t) for t in spec.values())}', '',
                       '| Тема | Файл | Лицензия | Автор |', '|---|---|---|---|', *rows, ''])
    if summary:
        with open(summary, 'a', encoding='utf-8') as f:
            f.write(table)
    print(table)


if __name__ == '__main__':
    try:
        main()
    except Exception as e:  # noqa: BLE001 — сборка приложения не должна падать из-за картинок
        print('fetch_images: ошибка, картинки пропущены:', e, file=sys.stderr)
        out = Path(__file__).resolve().parent.parent / 'app' / 'public' / 'img'
        out.mkdir(parents=True, exist_ok=True)
        if not (out / 'manifest.json').exists():
            (out / 'manifest.json').write_text('{}', encoding='utf-8')
