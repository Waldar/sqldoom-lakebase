#!/usr/bin/env python3
"""Static check of every SQL statement embedded in the ported PL/pgSQL functions.

PL/pgSQL only parses/analyses embedded SQL the first time a code path runs, and
plpgsql_check is not available on Lakebase. This transpiles the SQLDoom function
files, replaces variables / parameters / loop-record fields with typed NULL
placeholders, and runs plain EXPLAIN (plans, never executes) on each statement.
Analysis-time errors -- missing GROUP BY columns, type mismatches, unknown
columns or functions -- surface for every path at once.

    python3 run_on_lakebase.py <repo> /abs/path/static_check.py
"""
import os
import re
import sys
from collections import Counter
from pathlib import Path

import psycopg2

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cedar2plpgsql as c2p  # noqa: E402


def placeholders(body, sql):
    toks = c2p.tokenize(sql)
    out, i = [], 0
    while i < len(toks):
        t = toks[i]
        if (t.kind == "id" and i + 2 < len(toks) and toks[i + 1].text == "."
                and toks[i + 2].kind == "id"):
            name = toks[i + 2].low
            if t.low == c2p.VAR_LABEL and name in body.vars:
                out.append(f"(NULL::{body.vars[name]})")
                i += 3
                continue
            if t.low == body.fn_label and name in body.params:
                out.append(f"(NULL::{body.params[name]})")
                i += 3
                continue
            if re.fullmatch(r"_r\d+", t.low):
                out.append("NULL")      # loop-record field: type unknown statically
                i += 3
                continue
        out.append(t.text)
        i += 1
    return "".join(out)


def main():
    repo = Path(os.getcwd())
    conn = psycopg2.connect(os.environ["DB_DSN"])
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("SELECT DISTINCT column_name FROM information_schema.columns "
                "WHERE table_schema = current_schema()")
    cols = frozenset(r[0] for r in cur.fetchall())

    t = c2p.Transpiler()
    t.known_columns = cols
    for p in repo.rglob("*"):
        if p.suffix in (".sql", ".py") and p.is_file():
            t.learn(p.read_text(encoding="utf-8", errors="replace"))
    order = re.findall(r'"(\d\d\w*\.sql)"', (repo / "cedarscript_runtime.py").read_text())
    files = sorted(repo.glob("sql/loader/functions/*.sql")) + [repo / "sql/runtime/functions" / f for f in order]
    for f in files:
        t.transpile_sql(c2p.postgres_rewrites(f.read_text(), columns=cols))

    errors, checked = [], 0
    for body, sql in t.sql_log:
        stmt = placeholders(body, sql).strip().rstrip(";")
        checked += 1
        try:
            cur.execute("EXPLAIN " + stmt)
        except psycopg2.Error as e:
            msg = str(e).strip().splitlines()
            line = next((l for l in msg if l.startswith("LINE")), "")
            errors.append((body.name, msg[0], line.strip()[:160]))
    print(f"statements checked: {checked}  failing: {len(errors)}")
    kinds = Counter(re.sub(r'"[^"]*"', '".."', e[1])[:70] for e in errors)
    for k, n in kinds.most_common():
        print(f"  {n:3d} x {k}")
    print()
    for e in errors:
        print(" | ".join(e))


if __name__ == "__main__":
    main()
