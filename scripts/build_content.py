#!/usr/bin/env python3
"""Buduje dane startowe z katalogu content/:
  - supabase/seed.sql                         (seed bazy produkcyjnej/testowej)
  - ios/QuizVerse/Resources/content.json      (offline / tryb demonstracyjny)

Identyfikatory pytań i odpowiedzi są deterministyczne (uuid5), więc
ten sam zestaw pytań ma te same ID w bazie i w aplikacji.
Użycie: python3 scripts/build_content.py"""
import hashlib
import json
import os
import sys
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "content"))

import catalog  # noqa: E402
import questions_a  # noqa: E402
import questions_b  # noqa: E402

NS = uuid.UUID("6b1f4c1e-8e4a-4c55-9d1e-51c0a1e5e000")
DEFAULT_SOURCE = [{"title": "Redakcja QuizVerse – pytanie zweryfikowane ręcznie", "url": None}]


def sql(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, (list, dict)):
        return "'" + json.dumps(v, ensure_ascii=False).replace("'", "''") + "'::jsonb"
    return "'" + str(v).replace("'", "''") + "'"


def norm(text):
    return " ".join(text.lower().split())


def build():
    errors = []
    cats = {}
    subs = {}
    categories, subcategories = [], []
    for ci, (slug, name, icon, color, desc, sublist) in enumerate(catalog.CATEGORIES, start=1):
        cats[slug] = ci
        categories.append(dict(id=ci, slug=slug, name=name, icon=icon, color_hex=color, description=desc, sort_order=ci))
        for si, (sslug, sname) in enumerate(sublist):
            sid = ci * 100 + si + 1
            subs[(slug, sslug)] = sid
            parent = ci * 100 + (si - 3) + 1 if si >= 3 else None
            subcategories.append(dict(id=sid, category_id=ci, slug=sslug, name=sname, description="",
                                      tree_parent_id=parent, unlock_correct=3 if parent else 0, sort_order=si))
    assert len(categories) == 28, "Specyfikacja wymaga 28 kategorii"

    articles = []
    article_ids = {}
    for ai, a in enumerate(catalog.ARTICLES, start=1):
        slug, cslug, sslug, title, summary, body, facts, dates, terms, related, sources = a
        if (cslug, sslug) not in subs:
            errors.append(f"artykuł {slug}: brak podkategorii {cslug}/{sslug}")
        article_ids[slug] = ai
        articles.append(dict(id=ai, slug=slug, category_id=cats[cslug], subcategory_id=subs.get((cslug, sslug)),
                             title=title, summary=summary, body=body, key_facts=facts, dates=dates, terms=terms,
                             related_slugs=related, sources=sources))
    article_sources = {a["slug"]: a["sources"] for a in articles}

    questions = []
    seen = set()

    def add(cslug, sslug, diff, prompt, correct, wrong, expl, art, kind="standard", clues=None):
        key = norm(prompt + "|" + "|".join(clues or []))
        if key in seen:
            errors.append(f"duplikat: {prompt}")
        seen.add(key)
        if cslug not in cats:
            errors.append(f"nieznana kategoria {cslug}: {prompt}")
            return
        if sslug and (cslug, sslug) not in subs:
            errors.append(f"nieznana podkategoria {cslug}/{sslug}: {prompt}")
        if not 1 <= diff <= 6:
            errors.append(f"trudność {diff}: {prompt}")
        opts = [correct] + list(wrong)
        if len(opts) != 4 or len(set(norm(o) for o in opts)) != 4:
            errors.append(f"odpowiedzi muszą być 4 i różne: {prompt}")
        if art and art not in article_ids:
            errors.append(f"nieznany artykuł {art}: {prompt}")
        qid = uuid.uuid5(NS, "q:" + key)
        # deterministyczne tasowanie pozycji
        order = sorted(range(4), key=lambda i: hashlib.md5(f"{qid}:{i}".encode()).hexdigest())
        answers = []
        for pos, idx in enumerate(order):
            answers.append(dict(id=str(uuid.uuid5(NS, f"a:{qid}:{idx}")), body=opts[idx], is_correct=idx == 0, position=pos))
        questions.append(dict(
            id=str(qid), category_id=cats[cslug], subcategory_id=subs.get((cslug, sslug)) if sslug else None,
            difficulty=diff, kind=kind, prompt=prompt, clues=clues, explanation=expl,
            article_id=article_ids.get(art), article_slug=art,
            sources=article_sources.get(art) or DEFAULT_SOURCE,
            content_hash=hashlib.md5(key.encode()).hexdigest(), answers=answers))

    for q in questions_a.Q + questions_b.Q:
        add(*q)
    for (cslug, diff, title, clues, correct, wrong, expl) in questions_b.DETECTIVE:
        add(cslug, None, diff, title, correct, wrong, expl, None, kind="detective", clues=clues)

    leagues = [dict(id=i, code=c, name=n, roman=r, color_hex=col, emblem=e, description=d)
               for (i, c, n, r, col, e, d) in catalog.LEAGUES]
    assert len(leagues) == 5, "Dokładnie pięć lig"
    missions = [dict(id=i, code=c, period=p, title=t, description=d, icon=ic, metric=m, param=pa, target=ta,
                     xp_reward=x, lp_reward=l) for (i, c, p, t, d, ic, m, pa, ta, x, l) in catalog.MISSIONS]
    achievements = [dict(id=i, code=c, category=cat, name=n, description=d, icon=ic, rarity=r, tier=t, metric=m,
                         threshold=th, xp_reward=x) for (i, c, cat, n, d, ic, r, t, m, th, x) in catalog.ACHIEVEMENTS]
    cards = []
    for (i, c, n, d, k, cslug, r, art, era) in catalog.CARDS:
        if cslug not in cats:
            errors.append(f"karta {c}: nieznana kategoria {cslug}")
            continue
        cards.append(dict(id=i, code=c, name=n, description=d, kind=k, category_id=cats[cslug], rarity=r, art=art, era=era))

    if errors:
        print("\n".join(errors), file=sys.stderr)
        sys.exit(1)

    return dict(leagues=leagues, categories=categories, subcategories=subcategories, articles=articles,
                questions=questions, missions=missions, achievements=achievements, cards=cards)


def write_sql(data, path):
    out = ["-- WYGENEROWANO przez scripts/build_content.py – nie edytuj ręcznie.",
           "-- Dane referencyjne + ręcznie zweryfikowana baza pytań QuizVerse.", "begin;"]

    def ins(table, cols, rows, conflict="id"):
        if not rows:
            return
        out.append(f"insert into public.{table} ({', '.join(cols)}) values")
        out.append(",\n".join("  (" + ", ".join(sql(r[c]) for c in cols) + ")" for r in rows))
        out.append(f"on conflict ({conflict}) do nothing;")

    ins("leagues", ["id", "code", "name", "roman", "color_hex", "emblem", "description"], data["leagues"])
    ins("categories", ["id", "slug", "name", "icon", "color_hex", "description", "sort_order"], data["categories"])
    ins("subcategories", ["id", "category_id", "slug", "name", "description", "tree_parent_id", "unlock_correct", "sort_order"],
        sorted(data["subcategories"], key=lambda s: (s["tree_parent_id"] is not None, s["id"])))
    out.append("insert into public.knowledge_articles (id, slug, category_id, subcategory_id, title, summary, body, key_facts, dates, terms, related_slugs, sources) overriding system value values")
    out.append(",\n".join("  (" + ", ".join([sql(a["id"]), sql(a["slug"]), sql(a["category_id"]), sql(a["subcategory_id"]),
                                               sql(a["title"]), sql(a["summary"]), sql(a["body"]), sql(a["key_facts"]),
                                               sql(a["dates"]), sql(a["terms"]),
                                               "array[" + ",".join(sql(s) for s in a["related_slugs"]) + "]::text[]",
                                               sql(a["sources"])]) + ")" for a in data["articles"]))
    out.append("on conflict (slug) do nothing;")
    out.append("select setval(pg_get_serial_sequence('public.knowledge_articles', 'id'), (select max(id) from public.knowledge_articles));")

    ins("missions", ["id", "code", "period", "title", "description", "icon", "metric", "param", "target", "xp_reward", "lp_reward"], data["missions"])
    ins("achievements", ["id", "code", "category", "name", "description", "icon", "rarity", "tier", "metric", "threshold", "xp_reward"], data["achievements"])
    ins("collectible_cards", ["id", "code", "name", "description", "kind", "category_id", "rarity", "art", "era"], data["cards"])

    qrows = []
    arows = []
    for q in data["questions"]:
        qrows.append(dict(q, status="approved", source="manual"))
        for a in q["answers"]:
            arows.append(dict(a, question_id=q["id"]))
    ins("questions", ["id", "category_id", "subcategory_id", "difficulty", "kind", "prompt", "clues", "explanation",
                      "article_id", "source", "sources", "status", "content_hash"], qrows)
    ins("answers", ["id", "question_id", "body", "is_correct", "position"], arows)
    out.append("select public.ensure_season();")
    out.append("commit;")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")


def write_json(data, path):
    payload = dict(data)
    payload["generated_by"] = "scripts/build_content.py"
    with open(path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, separators=(",", ":"))


if __name__ == "__main__":
    d = build()
    write_sql(d, os.path.join(ROOT, "supabase", "seed.sql"))
    write_json(d, os.path.join(ROOT, "ios", "QuizVerse", "Resources", "content.json"))
    by_cat = {}
    for q in d["questions"]:
        by_cat[q["category_id"]] = by_cat.get(q["category_id"], 0) + 1
    print(f"pytania: {len(d['questions'])} (w tym detektyw: {sum(1 for q in d['questions'] if q['kind']=='detective')}), "
          f"kategorie: {len(d['categories'])}, podkategorie: {len(d['subcategories'])}, artykuły: {len(d['articles'])}, "
          f"karty: {len(d['cards'])}, osiągnięcia: {len(d['achievements'])}, misje: {len(d['missions'])}")
    print("min pytań w kategorii:", min(by_cat.values()), "max:", max(by_cat.values()))
