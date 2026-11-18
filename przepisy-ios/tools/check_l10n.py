#!/usr/bin/env python3
"""Sprawdza tłumaczenia iOS (Shared/L10n.swift) bez kompilatora:
- każdy klucz użyty w kodzie (L.t / L.tp / L.md) istnieje w EN, DE i PL,
- brak zdublowanych kluczy w słownikach (w Swifcie to awaria przy starcie),
- te same zmienne {..} we wszystkich językach.
Uruchom: python3 tools/check_l10n.py"""
import re, sys, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
src = (root / "Shared/L10n.swift").read_text()

def section(name):
    start = src.index(f"private static let {name}:")
    body = src[start:]
    depth, end = 0, 0
    for i, ch in enumerate(body[body.index("= [") + 2:], body.index("= [") + 2):
        if ch == "[": depth += 1
        elif ch == "]":
            depth -= 1
            if depth == 0: end = i; break
    return body[:end]

def langs(block):
    out = {}
    for m in re.finditer(r'^\s{8}"(en|de|pl)": \[\n(.*?)^\s{8}\],', block, re.S | re.M):
        out[m.group(1)] = m.group(2)
    return out

errors = []
strings, plurals = {}, {}
for lang, body in langs(section("strings")).items():
    keys = re.findall(r'^\s+"([^"]+)":\s*"', body, re.M)
    dup = {k for k in keys if keys.count(k) > 1}
    if dup: errors.append(f"[{lang}] zdublowane klucze: {sorted(dup)}")
    strings[lang] = dict(re.findall(r'^\s+"([^"]+)":\s*"((?:[^"\\]|\\.)*)"', body, re.M))
for lang, body in langs(section("plurals")).items():
    keys = re.findall(r'^\s+"([^"]+)":\s*\[', body, re.M)
    dup = {k for k in keys if keys.count(k) > 1}
    if dup: errors.append(f"[{lang}] zdublowane klucze liczby mnogiej: {sorted(dup)}")
    plurals[lang] = {k: dict(re.findall(r'"(\w+)":\s*"((?:[^"\\]|\\.)*)"', v))
                     for k, v in re.findall(r'^\s+"([^"]+)":\s*\[(.*?)\],?$', body, re.M)}

need_forms = {"en": {"one", "other"}, "de": {"one", "other"}, "pl": {"one", "few", "many"}}
for lang in ("en", "de", "pl"):
    for k, forms in plurals.get(lang, {}).items():
        missing = need_forms[lang] - set(forms)
        if missing: errors.append(f"[{lang}] {k}: brak form {sorted(missing)}")

code = "\n".join(p.read_text() for d in ("App", "Shared", "ShareExtension") for p in (root / d).glob("*.swift"))
used_t = set(re.findall(r'L\.(?:t|md)\("([^"]+)"', code))
# klucze wybierane warunkowo: L.t(cond ? "a" : "b")
for expr in re.findall(r'L\.t\(([^()]*\?[^()]*)\)', code):
    used_t |= set(re.findall(r'"([a-zA-Z]+\.[a-zA-Z_.]+)"', expr))
used_tp = set(re.findall(r'L\.tp\("([^"]+)"', code)) | {"portions"}

for lang in ("en", "de", "pl"):
    for k in sorted(used_t):
        if k not in strings.get(lang, {}): errors.append(f"[{lang}] brak klucza: {k}")
    for k in sorted(used_tp):
        if k not in plurals.get(lang, {}): errors.append(f"[{lang}] brak klucza liczby mnogiej: {k}")

ph = lambda s: sorted(set(re.findall(r"\{(\w+)\}", s)))
for k, en in strings["en"].items():
    for lang in ("de", "pl"):
        if k in strings[lang] and ph(strings[lang][k]) != ph(en):
            errors.append(f"[{lang}] {k}: inne zmienne niż w EN ({ph(strings[lang][k])} vs {ph(en)})")
    for lang in ("de", "pl"):
        if k not in strings[lang]: errors.append(f"[{lang}] brak tłumaczenia klucza z EN: {k}")
unused = set(strings["en"]) - used_t
if errors:
    print("\n".join(errors)); sys.exit(1)
print(f"OK: {len(used_t)} kluczy tekstu i {len(used_tp)} kluczy liczby mnogiej w 3 językach."
      + (f" Nieużywane: {sorted(unused)}" if unused else ""))
