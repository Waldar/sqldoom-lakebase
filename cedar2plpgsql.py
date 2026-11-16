"""cedar2plpgsql -- translate CedarDB `LANGUAGE cedarscript` functions to PL/pgSQL.

Built for porting SQLDoom (github.com/cedardb/sqldoom) to Lakebase Postgres.

CedarScript constructs handled (the full set SQLDoom uses):
  let [mut] x = expr;          -> DECLARE x <inferred type>;  x := expr;
  x = expr;                    -> x := expr;
  if cond { ... }              -> IF cond THEN ... END IF;
  else if / else               -> ELSIF / ELSE
  while cond { ... }           -> WHILE cond LOOP ... END LOOP;
  return [expr];               -> RETURN [expr];
  fn(args);                    -> PERFORM fn(args);
  <query> { body }             -> FOR _rN IN <query> LOOP body END LOOP;
                                  (bare column names in body -> _rN.col)
  bare SELECT/WITH..SELECT;    -> ... INTO _discard;
  plain DML                    -> passed through
Header: LANGUAGE cedarscript -> LANGUAGE plpgsql, missing RETURNS -> RETURNS void.
Body gets `#variable_conflict use_variable` (variables win over same-named columns,
which is how the CedarScript sources read).

Usage:
  t = Transpiler(); t.learn(all_sql_text)      # optional: collect function return types
  plpgsql_sql = t.transpile_sql(sql_text)      # rewrites every cedarscript function in text
  cur = ShimCursor(real_cursor, t)             # transpiles transparently on execute()
"""
import re

# --------------------------------------------------------------------------
# Tokenizer (keeps every byte, so untouched SQL round-trips exactly)
# --------------------------------------------------------------------------
_TOKEN_RE = re.compile(r"""
   (?P<ws>\s+)
  |(?P<comment>--[^\n]*|/\*.*?\*/)
  |(?P<dollar>\$\$.*?\$\$|\$(?P<tag>[A-Za-z_][A-Za-z0-9_]*)\$.*?\$(?P=tag)\$)
  |(?P<param>\$\d+)
  |(?P<str>[EeBbXxUu]?'(?:[^']|'')*')
  |(?P<qid>"(?:[^"]|"")*")
  |(?P<num>(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)
  |(?P<id>[A-Za-z_][A-Za-z0-9_$]*)
  |(?P<op>::|:=|<>|<=|>=|!=|<<|>>|\|\||->>|->|\#>>|\#>|=>|[^\s])
""", re.X | re.S)

TRIVIA = ("ws", "comment")


class Tok:
    __slots__ = ("kind", "text")

    def __init__(self, kind, text):
        self.kind, self.text = kind, text

    @property
    def low(self):
        return self.text.lower()

    def __repr__(self):
        return f"{self.kind}:{self.text!r}"


def tokenize(s):
    out, pos = [], 0
    while pos < len(s):
        m = _TOKEN_RE.match(s, pos)
        if not m:
            raise ValueError(f"tokenize failed at {pos}: {s[pos:pos+40]!r}")
        kind = m.lastgroup if m.lastgroup != "tag" else "dollar"
        for k in ("ws", "comment", "dollar", "param", "str", "qid", "num", "id", "op"):
            if m.group(k) is not None:
                kind = k
                break
        out.append(Tok(kind, m.group(0)))
        pos = m.end()
    return out


# --------------------------------------------------------------------------
# Type inference helpers
# --------------------------------------------------------------------------
SQL_STMT_KW = {"select", "with", "insert", "update", "delete", "values", "table",
               "merge", "truncate", "lock", "refresh", "analyze", "notify", "call",
               "perform", "set", "reset", "create", "drop", "alter", "grant", "revoke"}
BOOL_OPS = {"=", "<>", "!=", "<", ">", "<=", ">=", "and", "or", "not", "is",
            "exists", "in", "like", "ilike", "between"}
FLOAT_FUNCS = {"sqrt", "cos", "sin", "tan", "atan", "atan2", "radians", "degrees",
               "floor", "ceil", "ceiling", "power", "exp", "ln", "pi", "random", "round"}
PASSTHRU_FUNCS = {"coalesce", "greatest", "least", "abs", "nullif"}
TYPE_NORMAL = {"int": "integer", "int4": "integer", "int8": "bigint", "float8": "double precision",
               "float": "double precision", "float4": "real", "bool": "boolean",
               "varchar": "text", "character varying": "text"}
NUM_RANK = {"smallint": 1, "integer": 2, "bigint": 3, "numeric": 4, "real": 5, "double precision": 6}


def norm_type(t):
    t = re.sub(r"\s+", " ", t.strip().lower())
    t = re.sub(r"\(.*\)$", "", t).strip()  # varchar(8) -> varchar
    return TYPE_NORMAL.get(t, t)


def wider(a, b):
    if a is None:
        return b
    if b is None or a == b:
        return a
    if a in NUM_RANK and b in NUM_RANK:
        return a if NUM_RANK[a] >= NUM_RANK[b] else b
    return a  # keep the declared/initial type for non-numeric mismatches


def split_params(sig):
    """'p_a integer, p_b double precision DEFAULT 1' -> [(name, type)]"""
    toks = [t for t in tokenize(sig) if t.kind not in TRIVIA]
    params, cur, depth = [], [], 0
    for t in toks + [Tok("op", ",")]:
        if t.text == "(":
            depth += 1
        elif t.text == ")":
            depth -= 1
        if t.text == "," and depth == 0:
            if cur:
                words = [x.text for x in cur]
                if words[0].lower() in ("in", "inout", "variadic"):
                    words = words[1:]
                low = [w.lower() for w in words]
                for stop in ("default", "="):
                    if stop in low:
                        words = words[:low.index(stop)]
                        low = low[:len(words)]
                if len(words) >= 2:
                    params.append((words[0].lower(), norm_type(" ".join(words[1:]))))
            cur = []
        else:
            cur.append(t)
    return params


# --------------------------------------------------------------------------
# Function header regex
# --------------------------------------------------------------------------
FN_RE = re.compile(
    r"(?P<head>CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+(?P<name>[\w.]+)\s*\((?P<sig>[^()]*(?:\([^()]*\)[^()]*)*)\)\s*)"
    r"(?P<ret>RETURNS\s+(?:(?!LANGUAGE\b)[\w\s\[\]().,])+?\s*)?"
    r"(?P<pre>(?:(?:SECURITY\s+DEFINER|IMMUTABLE|STABLE|VOLATILE|STRICT|PARALLEL\s+\w+)\s+)*)"
    r"LANGUAGE\s+(?P<lang>\w+)"
    r"(?P<post>(?:\s+(?:SECURITY\s+DEFINER|IMMUTABLE|STABLE|VOLATILE|STRICT|PARALLEL\s+\w+))*)"
    r"\s+AS\s+(?P<q>\$(?P<tag>\w*)\$)(?P<body>.*?)(?P=q)",
    re.I | re.S)

ANY_FN_RE = re.compile(
    r"CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+(?P<name>[\w.]+)\s*\((?P<sig>[^()]*(?:\([^()]*\)[^()]*)*)\)\s*"
    r"(?:RETURNS\s+(?P<ret>(?:(?!LANGUAGE\b|AS\b)[\w\s\[\]])+?))?\s*(?:SECURITY\s+DEFINER\s+|IMMUTABLE\s+|STABLE\s+)*LANGUAGE",
    re.I | re.S)


class TranspileError(Exception):
    pass


VAR_LABEL = "_cs"   # outer block label: variables are referenced as _cs.<name>

# Keywords after which an identifier is an expression operand (so a variable).
EXPR_KW = {"select", "where", "and", "or", "not", "on", "when", "then", "else", "case",
           "in", "between", "like", "ilike", "is", "by", "having", "limit", "offset",
           "values", "return", "if", "while", "distinct", "all", "any", "some", "exists",
           "array", "elsif", "returning", "interval", "preceding", "following"}


class Transpiler:
    def __init__(self):
        self.func_returns = {"doom_const": "double precision"}
        self.warnings = []
        # Every embedded SQL statement emitted: (function_body, sql_text). Used by
        # static_check.py, since PL/pgSQL only analyses SQL when it first runs.
        self.sql_log = []

    # ---------------------------------------------------------------- learn
    def learn(self, text):
        """Collect return types of every CREATE FUNCTION in text (any language)."""
        for m in ANY_FN_RE.finditer(text):
            ret = m.group("ret")
            self.func_returns[m.group("name").lower()] = norm_type(ret) if ret else "void"

    # ------------------------------------------------------------ top level
    def transpile_sql(self, text):
        self.learn(text)
        out, last = [], 0
        for m in FN_RE.finditer(text):
            if m.group("lang").lower() != "cedarscript":
                continue
            out.append(text[last:m.start()])
            out.append(self._function(m))
            last = m.end()
        out.append(text[last:])
        return "".join(out)

    def _function(self, m):
        name = m.group("name")
        ret = m.group("ret")
        ret_t = norm_type(ret[len("RETURNS"):]) if ret else "void"
        params = split_params(m.group("sig"))
        fp = _FunctionBody(self, name, params, ret_t)
        try:
            body = batch_const_lookups(fp.translate(m.group("body")))
        except TranspileError as e:
            raise TranspileError(f"{name}: {e}") from None
        tag = "$" + (m.group("tag") or "pl") + "$"
        head = m.group("head")
        ret_clause = ret if ret else "RETURNS void "
        mods = " ".join(x for x in (m.group("pre").strip(), m.group("post").strip()) if x)
        return (f"{head}{ret_clause}LANGUAGE plpgsql{(' ' + mods) if mods else ''} AS {tag}\n"
                f"{body}{tag}")


# --------------------------------------------------------------------------
# Per-function translation
# --------------------------------------------------------------------------
class _FunctionBody:
    def __init__(self, tr, name, params, ret_t):
        self.tr, self.name, self.ret_t = tr, name, ret_t
        self.params = dict(params)
        self.vars = {}          # name -> type
        self.var_order = []
        self.assigns = []       # (var, expr_tokens, rewrite_maps snapshot)
        self.records = 0
        self.need_discard = False
        self.rewrite = []       # stack of {colname: recname}
        self.active = set()     # variables in scope (declared by an earlier let)
        self.fn_label = name.split(".")[-1]

    # ------------------------------------------------------------- helpers
    def warn(self, msg):
        self.tr.warnings.append(f"{self.name}: {msg}")

    def sig_idx(self, i, step=1):
        """index of next significant token from i (inclusive) in direction step"""
        while 0 <= i < len(self.t) and self.t[i].kind in TRIVIA:
            i += step
        return i if 0 <= i < len(self.t) else None

    def tok(self, i):
        return self.t[i] if i is not None and 0 <= i < len(self.t) else None

    def text(self, a, b, rewrite=True):
        """Render tokens [a, b): loop columns -> _rN.col, variables -> _cs.var,
        parameters -> fn.param (explicit qualification; the body runs with
        #variable_conflict use_column, so anything left bare is a column)."""
        if not rewrite:
            return "".join(t.text for t in self.t[a:b])
        noreb = self._no_rewrite_ranges(a, b)
        out = []
        for i in range(a, b):
            t = self.t[i]
            if t.kind == "id" and not any(lo <= i < hi for lo, hi in noreb):
                rec = self._lookup_col(t.low)
                if rec and self._is_colref(i):
                    out.append(f"{rec}.{t.text}")
                    continue
                if (t.low in self.active or t.low in self.params) and self._is_var_position(i):
                    if t.low in self.active:
                        if t.low in getattr(self.tr, "known_columns", ()):
                            self.warn(f"variable '{t.low}' is also a table column; qualified as variable")
                        out.append(f"{VAR_LABEL}.{t.text}")
                    else:
                        out.append(f"{self.fn_label}.{t.text}")
                    continue
            out.append(t.text)
        return "".join(out)

    def _is_var_position(self, i):
        """Is token i an expression operand (not an alias, table, column-list or SET target)?"""
        p_i = self.sig_idx(i - 1, -1)
        p = self.tok(p_i)
        n_i = self.sig_idx(i + 1)
        n = self.tok(n_i)
        if n is not None and n.text in (".", "(", "=>"):
            return False
        if n is not None and n.low == "as":
            nn = self.tok(self.sig_idx(n_i + 1))
            if nn is not None and nn.text == "(":   # CTE name
                return False
        if p is None:
            return True
        if p.text in (".", "::", ")") or p.kind in ("num", "str", "qid"):
            return False                              # qualified / cast / alias after expr
        if n is not None and n.text == "=" and (p.low == "set" or p.text == ","):
            return False                              # UPDATE ... SET col = ...
        if p.kind == "id":
            return p.low in EXPR_KW                   # else: `FROM tbl alias`, `AS name`, ...
        return True

    def _lookup_col(self, name):
        for m in reversed(self.rewrite):
            if name in m:
                return m[name]
        return None

    def _is_colref(self, i):
        p = self.tok(self.sig_idx(i - 1, -1))
        n_i = self.sig_idx(i + 1)
        n = self.tok(n_i)
        if p is not None and (p.text == "." or p.low == "as"):
            return False
        if n is not None and n.text in (".", "("):
            return False
        if n is not None and n.low == "as":
            nn = self.tok(self.sig_idx(n_i + 1))
            if nn is not None and nn.text == "(":   # CTE name
                return False
        if n is not None and n.text == "=" and p is not None and (p.low == "set" or p.text == ","):
            return False  # UPDATE ... SET col = ...
        return True

    def _no_rewrite_ranges(self, a, b):
        """INSERT INTO t (cols...) and ON CONFLICT (cols...) column lists."""
        ranges = []
        i = a
        while i < b:
            t = self.t[i]
            if t.kind == "id" and t.low in ("into", "conflict"):
                j = self.sig_idx(i + 1)
                if t.low == "into":
                    # skip table name (possibly schema-qualified)
                    while j is not None and j < b and (self.t[j].kind in ("id", "qid") or self.t[j].text == "."):
                        j = self.sig_idx(j + 1)
                if j is not None and j < b and self.t[j].text == "(":
                    k = self._match_paren(j)
                    ranges.append((j, k + 1))
            i += 1
        return ranges

    def _match_paren(self, j):
        depth = 0
        for k in range(j, len(self.t)):
            if self.t[k].text == "(":
                depth += 1
            elif self.t[k].text == ")":
                depth -= 1
                if depth == 0:
                    return k
        raise TranspileError("unbalanced parentheses")

    def scan_until(self, i, stops):
        """Advance from i to first depth-0 token whose text is in stops. Returns index."""
        depth = 0
        while i < len(self.t):
            t = self.t[i]
            if t.kind not in TRIVIA:
                if depth == 0 and t.text in stops:
                    return i
                if t.text in ("(", "["):
                    depth += 1
                elif t.text in (")", "]"):
                    depth -= 1
            i += 1
        raise TranspileError(f"expected one of {stops} before end of body")

    def sig_tokens(self, a, b):
        return [t for t in self.t[a:b] if t.kind not in TRIVIA]

    # ------------------------------------------------------------- driver
    def translate(self, body):
        self.t = tokenize(body)
        code = self.block(0, top=True)
        self._finalize_types()
        decls = []
        for v in self.var_order:
            decls.append(f"  {v} {self.vars[v]};")
        for k in range(1, self.records + 1):
            decls.append(f"  _r{k} record;")
        if self.need_discard:
            decls.append("  _discard record;")
        out = f"#variable_conflict use_column\n<<{VAR_LABEL}>>\n"
        if decls:
            out += "DECLARE\n" + "\n".join(decls) + "\n"
        out += "BEGIN\n" + code.rstrip() + "\n"
        if self.ret_t == "void":
            out += "RETURN;\n"
        out += f"END {VAR_LABEL};\n"
        return out

    # ------------------------------------------------------------ blocks
    def block(self, i, top=False):
        """Translate statements from i until matching '}' (or end if top). Sets self.end."""
        out = []
        scope = set(self.active)      # lets inside a block end with it
        while True:
            j = self.sig_idx(i)
            if j is None:
                if not top:
                    raise TranspileError("missing '}'")
                out.append("".join(t.text for t in self.t[i:]))
                self.end = len(self.t)
                return "".join(out)
            lead = "".join(t.text for t in self.t[i:j])  # whitespace/comments kept
            t = self.t[j]
            if t.text == "}":
                if top:
                    raise TranspileError("unexpected '}'")
                out.append(lead)
                self.end = j + 1
                self.active = scope
                return "".join(out)
            out.append(lead)
            stmt, i = self.statement(j)
            out.append(stmt)

    def statement(self, j):
        t = self.t[j]
        low = t.low if t.kind == "id" else None
        nxt_i = self.sig_idx(j + 1)
        nxt = self.tok(nxt_i)

        if low == "let":
            k = nxt_i
            if self.t[k].low == "mut":
                k = self.sig_idx(k + 1)
            var = self.t[k].low
            eq = self.sig_idx(k + 1)
            if self.t[eq].text != "=":
                raise TranspileError(f"let {var}: expected '='")
            semi = self.scan_until(eq + 1, {";"})
            self._declare(var, eq + 1, semi)
            expr = self.text(eq + 1, semi).strip()     # rendered before var is in scope
            self.active.add(var)
            return f"{var} := {expr};", semi + 1

        if low == "if":
            return self._if(j)

        if low == "while":
            lb = self.scan_until(nxt_i, {"{"})
            cond = self.text(nxt_i, lb).strip()
            inner = self.block(lb + 1)
            return f"WHILE {cond} LOOP{inner}END LOOP;", self.end

        if low == "return":
            semi = self.scan_until(nxt_i, {";"})
            expr = self.text(nxt_i, semi).strip()
            if self.ret_t == "void" or not expr:
                return "RETURN;", semi + 1
            return f"RETURN {expr};", semi + 1

        if low == "break":
            semi = self.scan_until(nxt_i, {";"})
            return "EXIT;", semi + 1
        if low == "continue":
            semi = self.scan_until(nxt_i, {";"})
            return "CONTINUE;", semi + 1

        # assignment:  x = expr;
        if t.kind == "id" and low not in SQL_STMT_KW and nxt is not None and nxt.text in ("=", ":="):
            semi = self.scan_until(nxt_i + 1, {";"})
            var = low
            if var not in self.vars and var not in self.params:
                self.warn(f"assignment to undeclared '{var}'")
            self.assigns.append((var, self._expr_tokens(nxt_i + 1, semi)))
            return f"{var} := {self.text(nxt_i + 1, semi).strip()};", semi + 1

        # bare function call: fn(args);
        if t.kind == "id" and low not in SQL_STMT_KW and nxt is not None and nxt.text == "(":
            semi = self.scan_until(j, {";"})
            return f"PERFORM {self.text(j, semi).strip()};", semi + 1

        # SQL statement, optionally followed by { body }
        stop = self.scan_until(j, {";", "{"})
        verb = self._main_verb(j, stop)
        if self.t[stop].text == "{":
            return self._query_loop(j, stop, verb)
        sql = self.text(j, stop).rstrip()
        self.tr.sql_log.append((self, sql))
        if verb == "select":
            self.need_discard = True
            return f"{sql} INTO _discard;", stop + 1
        return f"{sql};", stop + 1

    def _if(self, j):
        c0 = self.sig_idx(j + 1)
        lb = self.scan_until(c0, {"{"})
        cond = self.text(c0, lb).strip()
        inner = self.block(lb + 1)
        out = f"IF {cond} THEN{inner}"
        i = self.end
        while True:
            k = self.sig_idx(i)
            if k is not None and self.t[k].low == "else":
                k2 = self.sig_idx(k + 1)
                if self.t[k2].low == "if":
                    c0 = self.sig_idx(k2 + 1)
                    lb = self.scan_until(c0, {"{"})
                    cond = self.text(c0, lb).strip()
                    inner = self.block(lb + 1)
                    out += f"ELSIF {cond} THEN{inner}"
                    i = self.end
                    continue
                if self.t[k2].text == "{":
                    inner = self.block(k2 + 1)
                    out += f"ELSE{inner}"
                    i = self.end
                break
            break
        return out + "END IF;", i

    # -------------------------------------------------------- query loops
    def _main_verb(self, a, b):
        depth = 0
        first = None
        for i in range(a, b):
            t = self.t[i]
            if t.kind in TRIVIA:
                continue
            if t.text == "(":
                depth += 1
            elif t.text == ")":
                depth -= 1
            elif depth == 0 and t.kind == "id":
                if first is None:
                    first = t.low
                    if first != "with":
                        return first
                elif t.low in ("select", "insert", "update", "delete", "merge", "values"):
                    return t.low
        return first

    def _output_columns(self, a, b, verb):
        """Names produced by the statement's top-level SELECT list / RETURNING list."""
        key = "returning" if verb in ("insert", "update", "delete", "merge") else "select"
        depth, start = 0, None
        for i in range(a, b):
            t = self.t[i]
            if t.kind in TRIVIA:
                continue
            if t.text == "(":
                depth += 1
            elif t.text == ")":
                depth -= 1
            elif depth == 0 and t.low == key:
                start = i + 1
                break
        if start is None:
            raise TranspileError(f"query loop without top-level {key.upper()} list")
        enders = {"from", "into", "where", "group", "having", "window", "order", "limit",
                  "offset", "fetch", "union", "except", "intersect", "for", "on"}
        items, cur, depth = [], [], 0
        i = start
        while i < b:
            t = self.t[i]
            if t.kind not in TRIVIA:
                if depth == 0 and (t.low in enders and t.kind == "id"):
                    break
                if t.text == "(":
                    depth += 1
                elif t.text == ")":
                    depth -= 1
                if depth == 0 and t.text == ",":
                    items.append(cur)
                    cur = []
                else:
                    cur.append(t)
            i += 1
        if cur:
            items.append(cur)
        names = []
        for it in items:
            if it and it[0].low in ("distinct", "all"):
                it = it[1:]
            if not it:
                continue
            # Postgres names `x::type` / `t.x::type` after x: drop a trailing cast
            depth_c = 0
            for k in range(len(it) - 1, 0, -1):
                if it[k].text == ")":
                    depth_c += 1
                elif it[k].text == "(":
                    depth_c -= 1
                elif depth_c == 0 and it[k].text == "::":
                    if not (k >= 2 and it[k - 2].low == "as"):
                        it = it[:k]
                    break
                elif depth_c == 0 and it[k].low == "as":
                    break
            last = it[-1]
            if last.text == "*":
                self.warn("query loop selects '*' -- body columns not rewritten for it")
                continue
            if len(it) >= 2 and it[-2].low == "as" and last.kind in ("id", "qid"):
                names.append(last.low.strip('"'))
            elif last.kind == "id" and (len(it) == 1 or it[-2].text == "."):
                names.append(last.low)
            elif last.kind == "id" and len(it) >= 2 and (it[-2].text == ")" or it[-2].kind in ("id", "num", "str")):
                names.append(last.low)  # implicit alias:  expr name
            else:
                self.warn(f"could not name select item ending {last.text!r}")
        return names

    def _query_loop(self, j, lb, verb):
        cols = self._output_columns(j, lb, verb)
        query = self.text(j, lb).rstrip()      # outer rewrites apply inside query
        self.tr.sql_log.append((self, query))
        self.records += 1
        rec = f"_r{self.records}"
        self.rewrite.append({c: rec for c in cols})
        self._rec_cols = getattr(self, "_rec_cols", {})
        self._rec_cols[rec] = cols
        inner = self.block(lb + 1)
        self.rewrite.pop()
        return f"FOR {rec} IN {query}\nLOOP{inner}END LOOP;", self.end

    # ------------------------------------------------------------- typing
    def _expr_tokens(self, a, b):
        """significant tokens, with record-rewritten identifiers marked"""
        toks = []
        for i in range(a, b):
            t = self.t[i]
            if t.kind in TRIVIA:
                continue
            if t.kind == "id" and self.rewrite and self._lookup_col(t.low) and self._is_colref(i):
                toks.append(Tok("reccol", t.text))
            else:
                toks.append(t)
        return toks

    def _declare(self, var, a, b):
        toks = self._expr_tokens(a, b)
        if var in self.vars:
            self.assigns.append((var, toks))
            return
        if var in self.params:
            self.warn(f"let '{var}' shadows a parameter")
        self.vars[var] = None
        self.var_order.append(var)
        self.assigns.append((var, toks))

    def _finalize_types(self):
        for _ in range(6):
            changed = False
            for var, toks in self.assigns:
                if var not in self.vars:
                    continue
                ty = self.infer(toks)
                new = wider(self.vars[var], ty) if self.vars[var] else ty
                if new != self.vars[var]:
                    self.vars[var], changed = new, True
            if not changed:
                break
        for v in self.var_order:
            if not self.vars[v]:
                self.warn(f"could not infer type of '{v}', defaulting to text")
                self.vars[v] = "text"

    def infer(self, toks):
        if not toks:
            return None
        # trailing top-level cast
        depth = 0
        for k in range(len(toks) - 1, -1, -1):
            x = toks[k].text
            if x == ")":
                depth += 1
            elif x == "(":
                depth -= 1
            elif depth == 0 and x == "::":
                return norm_type(" ".join(t.text for t in toks[k + 1:]))
            elif depth == 0 and toks[k].kind not in ("id",) and x not in ("[", "]"):
                break
        # strip wrapping parens
        while toks[0].text == "(" and toks[-1].text == ")" and self._wraps(toks):
            toks = toks[1:-1]
        top = self._top_level(toks)
        if any((t.kind == "id" and t.low in BOOL_OPS) or (t.kind == "op" and t.text in BOOL_OPS) for t in top):
            return "boolean"
        if len(toks) == 1 or (len(toks) == 2 and toks[0].text in ("-", "+")):
            t = toks[-1]
            if t.kind == "num":
                return "double precision" if re.search(r"[.eE]", t.text) else "integer"
            if t.kind == "str":
                return "text"
            if t.kind == "id":
                if t.low in ("true", "false"):
                    return "boolean"
                if t.low == "null":
                    return None
                return self.vars.get(t.low) or self.params.get(t.low)
            if t.kind == "reccol":
                return None
        # whole-expression function call
        if toks[0].kind == "id" and len(toks) >= 3 and toks[1].text == "(" and self._wraps(toks[1:]):
            fn = toks[0].low
            if fn in self.tr.func_returns:
                return self.tr.func_returns[fn]
            if fn in FLOAT_FUNCS:
                return "double precision"
            if fn in ("count",):
                return "bigint"
            if fn in ("now", "clock_timestamp"):
                return "timestamp with time zone"
            if fn in PASSTHRU_FUNCS:
                args = self._first_arg(toks[2:-1])
                return self.infer(args)
            if fn in ("length", "octet_length", "get_byte", "position", "strpos"):
                return "integer"
            if fn in ("substr", "substring", "lower", "upper", "concat", "format", "md5"):
                return "text"
        if toks[0].low == "case":
            # type of first THEN branch
            for k, t in enumerate(toks):
                if t.low == "then":
                    end = next((m for m in range(k + 1, len(toks)) if toks[m].low in ("when", "else", "end")), len(toks))
                    return self.infer(toks[k + 1:end])
        # arithmetic: widest operand type
        best = None
        for t in top:
            ty = None
            if t.kind == "num":
                ty = "double precision" if re.search(r"[.eE]", t.text) else "integer"
            elif t.kind == "id":
                ty = self.vars.get(t.low) or self.params.get(t.low) or self.tr.func_returns.get(t.low)
                if ty is None and t.low in FLOAT_FUNCS:
                    ty = "double precision"
            elif t.kind == "str":
                ty = "text"
            if t.text == "||":
                return "text"
            if ty and ty != "void":
                best = wider(best, ty) if best else ty
        return best

    @staticmethod
    def _wraps(toks):
        depth = 0
        for k, t in enumerate(toks):
            if t.text == "(":
                depth += 1
            elif t.text == ")":
                depth -= 1
                if depth == 0 and k != len(toks) - 1:
                    return False
        return True

    @staticmethod
    def _top_level(toks):
        out, depth = [], 0
        for t in toks:
            if t.text == "(":
                depth += 1
                continue
            if t.text == ")":
                depth -= 1
                continue
            if depth == 0:
                out.append(t)
        return out

    @staticmethod
    def _first_arg(toks):
        depth = 0
        for k, t in enumerate(toks):
            if t.text == "(":
                depth += 1
            elif t.text == ")":
                depth -= 1
            elif t.text == "," and depth == 0:
                return toks[:k]
        return toks


# --------------------------------------------------------------------------
# CedarDB-only SQL functions
# --------------------------------------------------------------------------
def _split_args(toks):
    args, cur, depth = [], [], 0
    for t in toks:
        if t.kind not in TRIVIA:
            if t.text in ("(", "["):
                depth += 1
            elif t.text in (")", "]"):
                depth -= 1
            elif t.text == "," and depth == 0:
                args.append(cur)
                cur = []
                continue
        cur.append(t)
    args.append(cur)
    return ["".join(x.text for x in a).strip() for a in args]


def rewrite_arg_max(sql, packed=True):
    """ARG_MAX(v, k): value v at the largest k; rows with NULL v or k ignored;
    ties go to the larger v (deterministic).

    packed=True  -> native MAX over (k << 32 | v): fast, integer v in [0, 2^31)
                    and integer k only (the renderer/client hot paths).
    packed=False -> (array_agg(v ORDER BY k DESC, v DESC) FILTER (..))[1]: any types.
    """
    if not re.search(r"\barg_max\s*\(", sql, re.I):
        return sql
    toks = tokenize(sql)
    out, i = [], 0
    while i < len(toks):
        t = toks[i]
        if t.kind == "id" and t.low == "arg_max":
            j = i + 1
            while j < len(toks) and toks[j].kind in TRIVIA:
                j += 1
            if j < len(toks) and toks[j].text == "(":
                depth, k = 0, j
                for k in range(j, len(toks)):
                    if toks[k].text == "(":
                        depth += 1
                    elif toks[k].text == ")":
                        depth -= 1
                        if depth == 0:
                            break
                args = _split_args(toks[j + 1:k])
                if len(args) != 2:
                    raise TranspileError("ARG_MAX expects 2 arguments")
                v, key = (rewrite_arg_max(a, packed) for a in args)
                if packed:
                    out.append(f"((MAX((({key})::bigint << 32) | (({v})::bigint & 4294967295)) & 4294967295)::int)")
                else:
                    out.append(f"((array_agg({v} ORDER BY {key} DESC, {v} DESC) "
                               f"FILTER (WHERE ({key}) IS NOT NULL AND ({v}) IS NOT NULL))[1])")
                i = k + 1
                continue
        out.append(t.text)
        i += 1
    return "".join(out)


# --------------------------------------------------------------------------
# Lateral column aliases:  SELECT 320 AS w, w/2 AS cx  (CedarDB ok, Postgres not)
# --------------------------------------------------------------------------
_LIST_END = {"from", "where", "group", "having", "window", "order", "limit", "offset",
             "fetch", "union", "except", "intersect", "into", "returning"}


def inline_lateral_aliases(sql, report=None, columns=frozenset()):
    """Inline references to earlier select-list aliases of the same SELECT.

    A name that is also a real column (``columns``) is left alone, since then
    the reference may mean the column. Each inlined use is appended to report.
    """
    toks = tokenize(sql)
    out = [t.text for t in toks]
    sig = [i for i, t in enumerate(toks) if t.kind not in TRIVIA]
    pos = {i: n for n, i in enumerate(sig)}

    def s(n):
        return toks[sig[n]] if 0 <= n < len(sig) else None

    depth_at = {}
    d = 0
    for n, i in enumerate(sig):
        t = toks[i]
        if t.text == ")":
            d -= 1
        depth_at[n] = d
        if t.text == "(":
            d += 1

    for n0 in range(len(sig)):
        t0 = s(n0)
        if not (t0.kind == "id" and t0.low == "select"):
            continue
        d0 = depth_at[n0]
        aliases = {}            # name -> rendered expression text
        item_start = n0 + 1
        n = n0 + 1
        while n <= len(sig):
            t = s(n)
            end_list = (t is None or depth_at[n] < d0 or
                        (depth_at[n] == d0 and (t.text in (",", ";", "{") or
                                                (t.kind == "id" and t.low in _LIST_END))))
            if end_list:
                # finish item [item_start, n)
                items = list(range(item_start, n))
                if items:
                    first = s(items[0])
                    if first.kind == "id" and first.low in ("distinct", "all"):
                        items = items[1:]
                if items:
                    # substitute earlier aliases inside this item (same SELECT only)
                    for m in items:
                        tk = s(m)
                        if tk.kind != "id" or tk.low not in aliases or tk.low in columns:
                            continue
                        p, q = s(m - 1), s(m + 1)
                        if p is not None and (p.text == "." or p.low == "as"):
                            continue
                        if q is not None and q.text in (".", "("):
                            continue
                        # skip if inside a nested SELECT within this item
                        if any(s(k).kind == "id" and s(k).low == "select" and depth_at[k] > d0
                               and depth_at[k] <= depth_at[m] for k in range(items[0], m)):
                            continue
                        out[sig[m]] = "(" + aliases[tk.low] + ")"
                        if report is not None:
                            report.append(tk.low)
                    last = s(items[-1])
                    name = None
                    if len(items) >= 2 and s(items[-2]).low == "as" and last.kind == "id":
                        name, expr_items = last.low, items[:-2]
                    elif len(items) >= 2 and last.kind == "id" and s(items[-2]).text in (")",) :
                        name, expr_items = last.low, items[:-1]
                    if name and expr_items:
                        a, b = sig[expr_items[0]], sig[expr_items[-1]]
                        aliases[name] = "".join(out[a:b + 1]).strip()
                if t is None or t.text != "," or depth_at[n] != d0:
                    break
                item_start = n + 1
            n += 1
    return "".join(out)


def rewrite_dollar_bodies(sql, fn, fn_inner=None):
    """Apply fn to sql and, recursively, fn_inner (default fn) to the inside of
    $tag$...$tag$ strings (function bodies, DO blocks)."""
    fn_inner = fn_inner or fn
    toks = tokenize(sql)
    if not any(t.kind == "dollar" for t in toks):
        return fn(sql)
    parts, plain = [], []
    for t in toks:
        if t.kind == "dollar":
            m = re.match(r"(\$\w*\$)(.*)(\1)$", t.text, re.S)
            parts.append(fn("".join(plain)))
            plain = []
            parts.append(m.group(1) + rewrite_dollar_bodies(m.group(2), fn_inner) + m.group(3))
        else:
            plain.append(t.text)
    parts.append(fn("".join(plain)))
    return "".join(parts)


# Statement-level fixes where CedarDB accepts SQL that Postgres rejects and no
# safe generic rewrite exists. Each is asserted to match exactly once, so an
# upstream change makes the port fail loudly instead of silently diverging.
# (function, old, new, why)
TARGETED_FIXES = [
    ("doom_cs_move", ") AND NOT p.noclip AS blocked", ") AND NOT bool_or(p.noclip) AS blocked",
     "p is the single-row params CTE; CedarDB allows its ungrouped column, Postgres needs an aggregate"),
    # PERF: doom_sector_at is a VOLATILE plpgsql BSP walk. In a join qual Postgres
    # re-evaluates it for every sectors row (85 on E1M1, ~30 ms/tic). Evaluate it
    # once in a LATERAL. A/B on 60 random moves: identical player_state, 45->8 ms.
    ("doom_cs_move",
     "  JOIN sectors s ON s.map_id=p.map_id\n   AND s.id=doom_sector_at(p.map_id,bp.cx,bp.cy)\n",
     "  CROSS JOIN LATERAL (SELECT doom_sector_at(p.map_id,bp.cx,bp.cy) AS sid) z\n"
     "  JOIN sectors s ON s.map_id=p.map_id AND s.id=z.sid\n",
     "perf: volatile function in join qual is evaluated per row in Postgres"),
    # PERF: Postgres inlines the non-recursive sound_edges CTE into the recursive
    # flood term, rescanning linedef_geom + 2x sectors on every flood step (~23).
    # A/B 400 states identical; firing tics 3.6 -> 0.9 ms (server).
    ("doom_cs_monster_noise",
     "sound_edges AS (\n  SELECT ld.fsec AS a",
     "sound_edges AS MATERIALIZED (\n  SELECT ld.fsec AS a",
     "perf: build the sector adjacency once, not per recursion step"),
    # PERF: the monster door-opening INSERT joined every thing x combat def
    # (138 x 140 nested loop) before filtering to 'see' monsters. Filter first
    # (OFFSET 0 fence), keep the t/cd aliases via LATERAL so the rest of the
    # statement is unchanged. A/B 400 states identical; 2.0 -> 1.1 ms/tic.
    ("doom_cs_monster_chase",
     "SELECT DISTINCT doom_cs_monster_chase.p_map_id::int, ai.thing_id, ld.linedef_id, 'use', TRUE\n"
     "FROM monster_ai ai\n"
     "JOIN things t ON t.map_id = ai.map_id AND t.id = ai.thing_id\n"
     "JOIN thing_combat_defs cd ON cd.thing_type = t.type\n",
     "SELECT DISTINCT doom_cs_monster_chase.p_map_id::int, ai.thing_id, ld.linedef_id, 'use', TRUE\n"
     "FROM (SELECT ai.map_id, ai.thing_id, ai.state, t.x, t.y, cd.radius, cd.explodes\n"
     "      FROM monster_ai ai\n"
     "      JOIN things t ON t.map_id = ai.map_id AND t.id = ai.thing_id\n"
     "      JOIN thing_combat_defs cd ON cd.thing_type = t.type\n"
     "      WHERE ai.map_id = doom_cs_monster_chase.p_map_id::int AND ai.state = 'see' AND NOT cd.explodes\n"
     "      OFFSET 0) ai\n"
     "CROSS JOIN LATERAL (SELECT ai.x, ai.y) t\n"
     "CROSS JOIN LATERAL (SELECT ai.radius, ai.explodes) cd\n",
     "perf: filter to 'see' monsters before the wall scan"),
    # PERF (spatial): monster_step tested every candidate step (up to 8 per
    # chasing monster) against every blocking wall of the map: ~920 x ~1100
    # bounding-box comparisons on E1M6 with the monsters awake, 51 ms/tic.
    # Probe the GiST index linedef_geom_box_gist (map_id, box) with the step's
    # box instead and apply the live blocking rule (sector heights) to the few
    # walls found. Same box test (&& is the inclusive overlap of the old four
    # inequalities). Lab A/B, E1M6 awake, 250 tics: identical monster_ai and
    # things every tic; step 51 -> 13 ms, tic 104 -> 66 ms. E1M2 awake 11 -> 3 ms.
    # The index is created by postgres_compat.sql; without it the rewrite is
    # still correct, just not faster.
    ("doom_cs_monster_step",
     '  SELECT c.pri, c.thing_id,\n'
     '         BOOL_OR(dd.dist < c.radius OR xing.intersects) AS blocked\n'
     '  FROM candidates c\n'
     '  JOIN blocking b\n'
     '    ON NOT (b.floor_step_only AND c.floats)\n'
     '   AND LEAST(b.x1, b.x2) <= GREATEST(c.cx, c.old_x) + c.radius + 2.0\n'
     '   AND GREATEST(b.x1, b.x2) >= LEAST(c.cx, c.old_x) - c.radius - 2.0\n'
     '   AND LEAST(b.y1, b.y2) <= GREATEST(c.cy, c.old_y) + c.radius + 2.0\n'
     '   AND GREATEST(b.y1, b.y2) >= LEAST(c.cy, c.old_y) - c.radius - 2.0\n'
     '  CROSS JOIN LATERAL (',
     '  -- Spatial: probe the GiST index on linedef_geom (map_id, box) with each\n'
     "  -- candidate's step box, then apply the live blocking rule (sector heights)\n"
     '  -- only to the few walls found, instead of testing every blocking wall of\n'
     '  -- the map against every candidate.\n'
     '  SELECT c.pri, c.thing_id,\n'
     '         BOOL_OR(dd.dist < c.radius OR xing.intersects) AS blocked\n'
     '  FROM candidates c\n'
     '  CROSS JOIN params p\n'
     '  JOIN linedef_geom ld\n'
     '    ON ld.map_id = p.map_id\n'
     '   AND box(point(ld.x1::double precision, ld.y1::double precision),\n'
     '           point(ld.x2::double precision, ld.y2::double precision))\n'
     '       && box(point(LEAST(c.cx, c.old_x) - c.radius - 2.0, LEAST(c.cy, c.old_y) - c.radius - 2.0),\n'
     '              point(GREATEST(c.cx, c.old_x) + c.radius + 2.0, GREATEST(c.cy, c.old_y) + c.radius + 2.0))\n'
     '  LEFT JOIN sectors sf ON sf.map_id = ld.map_id AND sf.id = ld.fsec\n'
     '  LEFT JOIN sectors sb ON sb.map_id = ld.map_id AND sb.id = ld.bsec\n'
     '  CROSS JOIN LATERAL (\n'
     '    SELECT ld.x1::double precision AS x1, ld.y1::double precision AS y1,\n'
     '           ld.x2::double precision AS x2, ld.y2::double precision AS y2,\n'
     '           (ld.left_sd_id = -1 OR ld.right_sd_id = -1\n'
     '            OR (ld.flags & 1) <> 0\n'
     '            OR (sb.floor_height IS NOT NULL AND sf.floor_height IS NOT NULL\n'
     '                AND ABS(sb.floor_height - sf.floor_height) > max_step)\n'
     '            OR (sb.ceil_height IS NOT NULL AND sf.ceil_height IS NOT NULL\n'
     '                AND sb.floor_height IS NOT NULL AND sf.floor_height IS NOT NULL\n'
     '                AND (LEAST(sf.ceil_height, sb.ceil_height) - GREATEST(sf.floor_height, sb.floor_height)) < min_walk_opening)) AS is_blocking,\n'
     '           (NOT (ld.left_sd_id = -1 OR ld.right_sd_id = -1 OR (ld.flags & 1) <> 0)\n'
     '            AND NOT (sb.ceil_height IS NOT NULL AND sf.ceil_height IS NOT NULL\n'
     '                     AND sb.floor_height IS NOT NULL AND sf.floor_height IS NOT NULL\n'
     '                     AND (LEAST(sf.ceil_height, sb.ceil_height) - GREATEST(sf.floor_height, sb.floor_height)) < min_walk_opening))\n'
     '             AS floor_step_only\n'
     '  ) b\n'
     '  CROSS JOIN LATERAL (',
     "perf: GiST index probe instead of a scan of all blocking walls"),
    ("doom_cs_monster_step",
     '    SELECT ((sides.d1 * sides.d2 < 0) AND (sides.d3 * sides.d4 < 0)) AS intersects\n'
     '  ) xing\n'
     '  GROUP BY c.pri, c.thing_id\n'
     '),\n'
     'candidate_blocked AS (',
     '    SELECT ((sides.d1 * sides.d2 < 0) AND (sides.d3 * sides.d4 < 0)) AS intersects\n'
     '  ) xing\n'
     '  WHERE b.is_blocking AND NOT (b.floor_step_only AND c.floats)\n'
     '  GROUP BY c.pri, c.thing_id\n'
     '),\n'
     'candidate_blocked AS (',
     "perf: live blocking rule applied after the index probe"),
    # PERF (spatial): same index for the monster -> target sight line in
    # monster_think. Lab A/B E1M6, 200 tics: identical; think 5.9 -> 4.1 ms.
    # (EXISTS instead of BOOL_OR, and blocking_walls AS MATERIALIZED, were tried
    # 2026-10-23 and made the live tic slower: 40 -> 43 / 100 ms.)
    ("doom_cs_monster_think",
     '  FROM near_monsters nm\n'
     '  JOIN blocking_walls b\n'
     '    ON LEAST(b.x1, b.x2) <= GREATEST(nm.mx, nm.tx)\n'
     '   AND GREATEST(b.x1, b.x2) >= LEAST(nm.mx, nm.tx)\n'
     '   AND LEAST(b.y1, b.y2) <= GREATEST(nm.my, nm.ty)\n'
     '   AND GREATEST(b.y1, b.y2) >= LEAST(nm.my, nm.ty)\n'
     '  CROSS JOIN LATERAL (\n'
     '    SELECT\n'
     '      (nm.mx - b.x1)',
     '  FROM near_monsters nm\n'
     '  CROSS JOIN params p\n'
     "  -- Spatial: GiST probe for the walls whose box overlaps the sight line's box,\n"
     '  -- then the live blocking rule on those walls only.\n'
     '  JOIN linedef_geom ld\n'
     '    ON ld.map_id = p.map_id\n'
     '   AND box(point(ld.x1::double precision, ld.y1::double precision),\n'
     '           point(ld.x2::double precision, ld.y2::double precision))\n'
     '       && box(point(nm.mx, nm.my), point(nm.tx, nm.ty))\n'
     '  LEFT JOIN sectors fr ON fr.map_id = ld.map_id AND fr.id = ld.fsec\n'
     '  LEFT JOIN sectors bk ON bk.map_id = ld.map_id AND bk.id = ld.bsec\n'
     '  CROSS JOIN LATERAL (\n'
     '    SELECT ld.x1::double precision AS x1, ld.y1::double precision AS y1,\n'
     '           ld.x2::double precision AS x2, ld.y2::double precision AS y2\n'
     '    WHERE ld.left_sd_id = -1 OR ld.right_sd_id = -1\n'
     '       OR fr.id IS NULL OR bk.id IS NULL\n'
     '       OR LEAST(fr.ceil_height, bk.ceil_height)\n'
     '            <= GREATEST(fr.floor_height, bk.floor_height)\n'
     '  ) b\n'
     '  CROSS JOIN LATERAL (\n'
     '    SELECT\n'
     '      (nm.mx - b.x1)',
     "perf: GiST index probe for walls crossing the sight line's box"),
    # PERF (plan stability): wall_block, thing_hit (monster_step) and
    # near_los_walls (monster_think) are each referenced once, so Postgres
    # inlines them and, once ANALYZE has seen a busy map, pushes the outer join
    # key into them: the GROUP BY then re-runs per candidate (860 loops, up to
    # 350 ms on one stepping tic of E1M6). MATERIALIZED computes each verdict
    # set once and hash-joins it, whatever the statistics say. Lab A/B after
    # VACUUM FULL ANALYZE, 150 tics, identical monster/sound state every tic:
    # E1M6 awake 122.9 -> 49.8 ms, E1M6 asleep 21.3 -> 17.7, E1M2 awake
    # 48.4 -> 40.3, E1M2 asleep 21.1 -> 17.6. (Different from the 2026-10-23
    # blocking_walls MATERIALIZED / EXISTS attempt, which was slower.)
    # doom_cs_sound was looked at too (2026-10-23): its 16-19 ms/tic on E1M6
    # was a stale-statistics plan; with current statistics it is ~6 ms/tic,
    # and inlining its input/player_pos CTEs was mixed (-11 / +1 ms) and made
    # the plan cache re-plan every call (14 ms) in some states. Left as is.
    ("doom_cs_monster_step", "wall_block AS (\n", "wall_block AS MATERIALIZED (\n",
     "perf: one wall verdict pass per tic, not one per candidate"),
    ("doom_cs_monster_step", "thing_hit AS (\n", "thing_hit AS MATERIALIZED (\n",
     "perf: one thing-collision pass per tic, not one per candidate"),
    ("doom_cs_monster_think", "near_los_walls AS (\n", "near_los_walls AS MATERIALIZED (\n",
     "perf: one sight-line pass per tic, not one per monster"),
    # APP: the map picked on the app page (mp_map_request, postgres_compat.sql)
    # wins over the rotation for the next map change; the rotation consumes it.
    ("doom_mp_next_map",
     "if next_id < 0 { SELECT m.map_id AS id FROM mp_match m { next_id = id; } }\nreturn next_id;",
     "if next_id < 0 { SELECT m.map_id AS id FROM mp_match m { next_id = id; } }\n"
     "SELECT ma.map_id AS id FROM mp_map_request q JOIN maps ma ON ma.name = q.map_name { next_id = id; }\n"
     "return next_id;",
     "app: a map chosen on the page goes before the rotation"),
    ("doom_mp_rotate",
     "let nxt = doom_mp_next_map();\n",
     "let nxt = doom_mp_next_map();\nDELETE FROM mp_map_request;\n",
     "app: the chosen map is used once"),
    # REVIEW-TIC (2026-10-23): the 9 entries of review_tic_patches.py. The
    # doom_sector_at / doom_cs_discover / doom_cs_monster_chase anchors are in
    # source form (unqualified p_* parameters): the review copied them from the
    # transpiled functions, where they never match and would be skipped silently.
    # E1M6 busy (4 players, fixed inputs), 240 measured tics, two branches at the
    # same LSN: full game state identical (116 tables; only sound_events.event_id
    # gaps differ), tic mean 74.1 -> 52.1 ms (-30%, 1 CU), WAL 44.6 -> 26.0 KB/tic.
    # Needs the 4 indexes in postgres_compat.sql.
    ('doom_cs_monster_think',
     'max_seq AS (\n  SELECT thing_type, state, MAX(seq_index) AS max_idx\n  FROM thing_ai_frames GROUP BY thing_type, state\n),',
     "max_seq AS (\n  SELECT thing_type,\n         MAX(seq_index) FILTER (WHERE state = 'see') AS see_max,\n         MAX(seq_index) FILTER (WHERE state = 'missile') AS missile_max,\n         MAX(seq_index) FILTER (WHERE state = 'pain') AS pain_max,\n         MAX(seq_index) FILTER (WHERE state = 'die') AS die_max,\n         MAX(seq_index) FILTER (WHERE state = 'xdeath') AS xdeath_max\n  FROM thing_ai_frames GROUP BY thing_type\n),",
     'perf: max_seq self-joined 5x -> one pivoted row per type (with the next 2 entries)'),
    ('doom_cs_monster_think',
     '    ms.max_idx AS see_max, mm.max_idx AS missile_max,\n    mp.max_idx AS pain_max, md.max_idx AS die_max,\n    mx.max_idx AS xdeath_max',
     '    ms.see_max, ms.missile_max, ms.pain_max, ms.die_max, ms.xdeath_max',
     'perf: pivoted max_seq columns'),
    ('doom_cs_monster_think',
     "  LEFT JOIN max_seq ms ON ms.thing_type = m.type AND ms.state = 'see'\n  LEFT JOIN max_seq mm ON mm.thing_type = m.type AND mm.state = 'missile'\n  LEFT JOIN max_seq mp ON mp.thing_type = m.type AND mp.state = 'pain'\n  LEFT JOIN max_seq md ON md.thing_type = m.type AND md.state = 'die'\n  LEFT JOIN max_seq mx ON mx.thing_type = m.type AND mx.state = 'xdeath'",
     '  LEFT JOIN max_seq ms ON ms.thing_type = m.type',
     'perf: one max_seq join instead of five'),
    ('doom_cs_monster_think',
     'near_los AS (',
     'near_los AS MATERIALIZED (',
     'perf: near_los was re-scanned per monster'),
    ('doom_sector_at',
     "  SELECT w.depth + 1,\n         CASE WHEN nc.child_kind = 'NODE' THEN nc.child_node_id END,\n         CASE WHEN nc.child_kind = 'SSECTOR' THEN nc.child_ssector_id END\n  FROM bsp w\n  JOIN nodes n ON n.map_id = p_map_id AND n.id = w.node_id\n  JOIN node_children nc ON nc.map_id = p_map_id AND nc.node_id = n.id\n    AND nc.side = CASE\n      WHEN (p_x - n.x) * n.dy::float8 - (p_y - n.y) * n.dx::float8 > 0\n      THEN 'R' ELSE 'L' END\n  WHERE w.node_id IS NOT NULL\n)\nSELECT rs.fsec AS f\nFROM bsp b\nJOIN render_segs rs ON rs.map_id = p_map_id AND rs.ssector_id = b.ssector_id\nWHERE b.ssector_id IS NOT NULL\nORDER BY rs.seg_id\nLIMIT 1",
     "  SELECT w.depth + 1, c.node_id, c.ssector_id\n  FROM bsp w\n  CROSS JOIN LATERAL (\n    SELECT CASE WHEN nc.child_kind = 'NODE' THEN nc.child_node_id END AS node_id,\n           CASE WHEN nc.child_kind = 'SSECTOR' THEN nc.child_ssector_id END AS ssector_id\n    FROM nodes n\n    JOIN node_children nc ON nc.map_id = n.map_id AND nc.node_id = n.id\n     AND nc.side = CASE\n       WHEN (p_x - n.x) * n.dy::float8 - (p_y - n.y) * n.dx::float8 > 0\n       THEN 'R' ELSE 'L' END\n    WHERE n.map_id = p_map_id AND n.id = w.node_id\n  ) c\n  WHERE w.node_id IS NOT NULL\n)\nSELECT (SELECT rs.fsec FROM render_segs rs\n        WHERE rs.map_id = p_map_id AND rs.ssector_id = b.ssector_id\n        ORDER BY rs.seg_id LIMIT 1) AS f\nFROM bsp b\nWHERE b.ssector_id IS NOT NULL\nLIMIT 1",
     'perf: BSP step hash-joined all nodes per level; LATERAL index probe + scalar first-seg lookup (render_segs_ssector index)'),
    ('doom_cs_monster_chase',
     "  SELECT w.thing_id, w.depth + 1,\n    CASE WHEN nc.child_kind = 'NODE' THEN nc.child_node_id END,\n    CASE WHEN nc.child_kind = 'SSECTOR' THEN nc.child_ssector_id END\n  FROM bsp w\n  JOIN params p ON TRUE\n  JOIN movers m ON m.thing_id = w.thing_id\n  JOIN nodes n ON n.map_id = p.map_id AND n.id = w.node_id\n  JOIN node_children nc ON nc.map_id = p.map_id AND nc.node_id = n.id\n    AND nc.side = CASE\n      WHEN (m.mx - n.x)::float8 * n.dy::float8\n           - (m.my - n.y)::float8 * n.dx::float8 > 0\n      THEN 'R' ELSE 'L' END\n  WHERE w.node_id IS NOT NULL",
     "  SELECT w.thing_id, w.depth + 1, c.node_id, c.ssec_id\n  FROM bsp w\n  JOIN movers m ON m.thing_id = w.thing_id\n  CROSS JOIN LATERAL (\n    SELECT CASE WHEN nc.child_kind = 'NODE' THEN nc.child_node_id END AS node_id,\n           CASE WHEN nc.child_kind = 'SSECTOR' THEN nc.child_ssector_id END AS ssec_id\n    FROM nodes n\n    JOIN node_children nc ON nc.map_id = n.map_id AND nc.node_id = n.id\n     AND nc.side = CASE\n       WHEN (m.mx - n.x)::float8 * n.dy::float8\n            - (m.my - n.y)::float8 * n.dx::float8 > 0\n       THEN 'R' ELSE 'L' END\n    WHERE n.map_id = p_map_id::int AND n.id = w.node_id\n  ) c\n  WHERE w.node_id IS NOT NULL",
     'perf: same BSP step rewrite for chasing monsters'),
    ('doom_cs_monster_chase',
     '  AND near.gap < cd.radius\n  AND sm.sector_id IS NULL',
     '  AND near.gap < cd.radius\n  AND sm.sector_id IS NULL\n  -- Necessary condition, exact: a line within cd.radius of the step point (8 units from the\n  -- monster) has its box within cd.radius + 8 of the monster. Lets the GiST index pick the lines.\n  AND box(point(ld.x1::double precision, ld.y1::double precision),\n          point(ld.x2::double precision, ld.y2::double precision))\n      && box(point(t.x - cd.radius - 9.0, t.y - cd.radius - 9.0),\n             point(t.x + cd.radius + 9.0, t.y + cd.radius + 9.0))',
     'perf: door-use scan crossed every see monster with every usable line; exact GiST box prefilter'),
    ('doom_cs_discover',
     'SELECT ps.map_id, ld.id\nFROM player_state ps\nJOIN linedefs ld ON ld.map_id = ps.map_id\nLEFT JOIN sidedefs rs ON rs.map_id = ld.map_id AND rs.id = ld.right_sd_id\nLEFT JOIN sidedefs ls ON ls.map_id = ld.map_id AND ls.id = ld.left_sd_id\nWHERE ps.map_id = p_map_id::int\n  AND ps.player_thing_id = p_player_thing_id::int\n  AND ps.sector_id IS NOT NULL\n  AND (rs.sector_id = ps.sector_id OR ls.sector_id = ps.sector_id)',
     'SELECT DISTINCT ps.map_id, ld.id\nFROM player_state ps\nJOIN sidedefs sd ON sd.map_id = ps.map_id AND sd.sector_id = ps.sector_id\nJOIN linedefs ld ON ld.map_id = sd.map_id AND (ld.right_sd_id = sd.id OR ld.left_sd_id = sd.id)\nWHERE ps.map_id = p_map_id::int\n  AND ps.player_thing_id = p_player_thing_id::int\n  AND ps.sector_id IS NOT NULL',
     'perf: all linedefs x 2 sidedefs per player per tic; go through the sector sidedefs (sidedefs_sector, linedefs_right/left_sd indexes)'),
    ('doom_cs_sound',
     'FROM events WHERE sound_name IS NOT NULL\nON CONFLICT (map_id,event_key) DO NOTHING;',
     'FROM events e WHERE sound_name IS NOT NULL\n  AND NOT EXISTS (SELECT 1 FROM sound_events s WHERE s.map_id = e.map_id AND s.event_key = e.event_key)\nON CONFLICT (map_id,event_key) DO NOTHING;',
     'perf/WAL: known keys burned nextval() before ON CONFLICT dropped them; skip them first'),
    # PROFILE-E1M6 (2026-10-23): monster step + world sound cues. E1M6 busy (4
    # players, fixed inputs), 600 tics interleaved on two branches at the same
    # LSN: full game state identical (116 tables, sound_events incl. event_id;
    # 3 deaths, 61 awake monsters), tic mean 44.1 -> 41.1 ms (1 CU). In-tic
    # profile: doom_cs_monster_step 8.7 -> 5.6 ms, doom_cs_sound 6.2 -> 3.3 ms.
    ('doom_cs_monster_step',
     '\nmon_target AS (\n',
     '\nmon_target AS MATERIALIZED (\n',
     'perf: mon_target computed once, not once per chasing monster'),
    ('doom_cs_monster_step',
     '  SELECT c.pri, c.thing_id, c.cx, c.cy, c.old_x, c.old_y, c.face_angle,\n         c.dir, c.next_movecount,\n         COALESCE(wb.blocked, FALSE) OR COALESCE(th2.hit, FALSE) AS blocked\n  FROM candidates c\n  LEFT JOIN wall_block wb ON wb.pri = c.pri AND wb.thing_id = c.thing_id\n  LEFT JOIN thing_hit th2 ON th2.pri = c.pri AND th2.thing_id = c.thing_id\n',
     '  SELECT c.pri, c.thing_id, c.cx, c.cy, c.old_x, c.old_y, c.face_angle,\n         c.dir, c.next_movecount,\n         FALSE AS blocked\n  FROM candidates c\n  WHERE NOT EXISTS (SELECT 1 FROM wall_block wb WHERE wb.pri = c.pri AND wb.thing_id = c.thing_id AND wb.blocked)\n    AND NOT EXISTS (SELECT 1 FROM thing_hit th2 WHERE th2.pri = c.pri AND th2.thing_id = c.thing_id AND th2.hit)\n',
     'perf: only unblocked candidates are used (best_pos); anti-joins instead of two nested-loop LEFT JOINs over CTEs'),
    ('doom_cs_sound',
     "let sound_trim_interval = doom_const('SOUND_TRIM_INTERVAL_TICS');\n",
     "let sound_trim_interval = doom_const('SOUND_TRIM_INTERVAL_TICS');\n-- World cues (monsters, impacts) are the same for every listener: emit them\n-- in the first call of the tic that has a player, not once per player slot.\n-- The flag is transaction-local (one tic = one transaction).\nlet mut world_cues = COALESCE(current_setting('doom.sound_world', true), '') = '';\n",
     'perf: world cues once per tic'),
    ('doom_cs_sound',
     '\nsound_pick AS (\n',
     '\nworld_pos AS (\n  SELECT p.* FROM player_pos p WHERE world_cues\n),\nsound_pick AS (\n',
     'perf: world cues once per tic'),
    ('doom_cs_sound',
     '  FROM player_pos p JOIN monster_ai ai ON ai.map_id=p.map_id\n  JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id\n  JOIN thing_combat_defs d ON d.thing_type=t.type\n',
     '  FROM world_pos p JOIN monster_ai ai ON ai.map_id=p.map_id\n  JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id\n  JOIN thing_combat_defs d ON d.thing_type=t.type\n',
     'perf: world cues once per tic'),
    ('doom_cs_sound',
     '  FROM player_pos p JOIN projectile_impacts i ON i.map_id=p.map_id\n',
     '  FROM world_pos p JOIN projectile_impacts i ON i.map_id=p.map_id\n',
     'perf: world cues once per tic'),
    ('doom_cs_sound',
     "  FROM player_pos p\n  JOIN monster_ai ai ON ai.map_id=p.map_id AND ai.state <> 'stand'\n",
     "  FROM world_pos p\n  JOIN monster_ai ai ON ai.map_id=p.map_id AND ai.state <> 'stand'\n",
     'perf: world cues once per tic'),
    ('doom_cs_sound',
     '  FROM player_pos p\n  JOIN monster_ai ai ON ai.map_id=p.map_id\n  JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id\n  JOIN thing_health h ON h.map_id=ai.map_id AND h.thing_id=ai.thing_id\n   AND NOT h.alive\n',
     '  FROM world_pos p\n  JOIN monster_ai ai ON ai.map_id=p.map_id\n  JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id\n  JOIN thing_health h ON h.map_id=ai.map_id AND h.thing_id=ai.thing_id\n   AND NOT h.alive\n',
     'perf: world cues once per tic'),
    ('doom_cs_sound',
     "  FROM player_pos p\n  JOIN monster_ai ai ON ai.map_id=p.map_id AND ai.state='pain'\n",
     "  FROM world_pos p\n  JOIN monster_ai ai ON ai.map_id=p.map_id AND ai.state='pain'\n",
     'perf: world cues once per tic'),
    ('doom_cs_sound',
     "  FROM player_pos p\n  JOIN monster_ai ai ON ai.map_id=p.map_id AND ai.state='see'\n",
     "  FROM world_pos p\n  JOIN monster_ai ai ON ai.map_id=p.map_id AND ai.state='see'\n",
     'perf: world cues once per tic'),
    ('doom_cs_sound',
     'ON CONFLICT (map_id,event_key) DO NOTHING;\n',
     "ON CONFLICT (map_id,event_key) DO NOTHING;\nif world_cues {\n  SELECT set_config('doom.sound_world', '1', true) AS x\n  FROM game_tic_commands g\n  JOIN player_state ps ON ps.map_id = g.map_id AND ps.player_thing_id = g.player_thing_id\n  JOIN things t ON t.map_id = g.map_id AND t.id = g.player_thing_id\n  WHERE g.map_id = p_map_id::int AND g.player_thing_id = p_player_thing_id::int\n  { world_cues = false; }\n}\n",
     'perf: world cues once per tic (mark them emitted when this call had a player)'),
    # GAME MODES (2026-10-23, app): solo while one player is seated, deathmatch
    # from the second (doomapp/referee.py switches, postgres_compat.sql holds
    # mp_match.mode/pending, doom_mp_apply_mode and doom_mp_world_flags).
    ('doom_mp_rotate',
     'DELETE FROM mp_map_request;\nlet mut skill = 3;\n',
     'DELETE FROM mp_map_request;\ndoom_mp_apply_mode();\nlet mut skill = 3;\n',
     'app: the mode the intermission led to (deathmatch / solo) applies before the map opens'),
    ('doom_mp_configure',
     "VALUES (0, p_map_id, p_skill, 'intermission', p_timer_tics, p_altdeath, p_monsters, p_respawn_monsters, p_intermission_tics, now());\n",
     "VALUES (0, p_map_id, p_skill, 'intermission', p_timer_tics, p_altdeath, p_monsters, p_respawn_monsters, p_intermission_tics, now());\n"
     "doom_mp_world_flags(false);\n",
     'app: a referee start is a solo match; things get their single-player flags back'),
    ('doom_mp_intermission_begin',
     "    intermission_until = now() + (intermission_tics::double precision / 35.0) * interval '1 second'\nWHERE state = 'playing';",
     "    intermission_until = now() + (CASE WHEN pending = 'final' THEN 30.0\n"
     "                                       WHEN pending IN ('restart', 'rules', 'stay', 'solo') THEN 3.0\n"
     "                                       ELSE intermission_tics::double precision / 35.0 END) * interval '1 second'\n"
     "WHERE state = 'playing';",
     'app: the end of a deathmatch waits 30 s for the choice; a level restart or a switch by Player 1 takes 3 s'),
    ('doom_mp_respawn',
     '  WHERE t.map_id=p_map_id AND t.type=11\n',
     "  WHERE t.map_id=p_map_id AND t.type=11\n"
     "    AND NOT EXISTS (SELECT 1 FROM mp_match mm WHERE mm.mode = 'solo')\n",
     'app: single player spawns at its own player start, not a deathmatch start'),
    ('doom_mp_respawn',
     '                    WHERE ABS(o.x-t.x)<64.0 AND ABS(o.y-t.y)<64.0)\n),\npick AS (',
     '                    WHERE ABS(o.x-t.x)<64.0 AND ABS(o.y-t.y)<64.0)\n'
     '  UNION ALL\n'
     '  -- single player: the slot\'s own player start (the WAD position)\n'
     '  SELECT t.id, t.spawn_x, t.spawn_y, t.spawn_angle, 1::bigint, 1::bigint\n'
     '  FROM things t\n'
     '  WHERE t.map_id=p_map_id AND t.id=p_player_thing_id\n'
     "    AND EXISTS (SELECT 1 FROM mp_match mm WHERE mm.mode = 'solo')\n"
     '),\npick AS (',
     'app: single player spawns at its own player start, not a deathmatch start'),
    ('doom_tic_dm_player',
     'let mut rs = false;\n',
     'let mut rs = false;\nlet mut restart_rule = false;\n',
     'app: single-player rule "death restarts the level"'),
    ('doom_tic_dm_player',
     'if rs { doom_mp_respawn(p_map_id,p); }\n',
     "if rs {\n"
     "  SELECT EXISTS (SELECT 1 FROM mp_match m WHERE m.mode = 'solo' AND m.death_restart) AS x { restart_rule = x; }\n"
     "}\n"
     "-- the referee sees pending = 'restart' and reopens the map (pistol start)\n"
     "if rs AND restart_rule {\n"
     "  UPDATE mp_match SET pending = 'restart' WHERE pending IS NULL AND state = 'playing';\n"
     "}\n"
     "if rs AND NOT restart_rule { doom_mp_respawn(p_map_id,p); }\n",
     'app: single-player rule "death restarts the level"'),
    ('doom_mp_respawn',
     '    key_blue=FALSE, key_yellow=FALSE, key_red=FALSE,\n',
     "    key_blue=EXISTS (SELECT 1 FROM mp_match mm WHERE mm.mode = 'deathmatch'),\n"
     "    key_yellow=EXISTS (SELECT 1 FROM mp_match mm WHERE mm.mode = 'deathmatch'),\n"
     "    key_red=EXISTS (SELECT 1 FROM mp_match mm WHERE mm.mode = 'deathmatch'),\n",
     'app: P_SpawnPlayer gives every card in a deathmatch'),
    ('doom_cs_pickups',
     'INSERT INTO picked_up_items (map_id,thing_id)\nSELECT DISTINCT map_id,thing_id FROM pickup_touches\n'
     'WHERE map_id=p_map_id AND player_thing_id=p_player_thing_id\nON CONFLICT (map_id,thing_id) DO NOTHING;\n',
     'INSERT INTO picked_up_items (map_id,thing_id)\nSELECT DISTINCT map_id,thing_id FROM pickup_touches\n'
     'WHERE map_id=p_map_id AND player_thing_id=p_player_thing_id\n'
     "  -- deathmatch 1.0: a map weapon stays for the others (who do not own it\n"
     "  -- yet). A weapon Thing is touched twice (the weapon and its ammo).\n"
     "  AND NOT (thing_id < dropped_base\n"
     "           AND EXISTS (SELECT 1 FROM mp_match mm WHERE mm.weapons_stay)\n"
     "           AND EXISTS (SELECT 1 FROM pickup_touches wt\n"
     "                       WHERE wt.map_id = p_map_id AND wt.player_thing_id = p_player_thing_id\n"
     "                         AND wt.thing_id = pickup_touches.thing_id AND wt.kind = 'weapon'))\n"
     'ON CONFLICT (map_id,thing_id) DO NOTHING;\n',
     'app: rule "weapons stay on the ground" (deathmatch 1.0)'),
]


# PERF: CedarScript functions start with a block of `let x = doom_const('NAME')`
# lines, i.e. one plpgsql call + one query per constant (doom_cs_move: 18 of
# them, ~150 us/tic). Collapse each run into one scan of doom_constants.
# PL/pgSQL has no tuple assignment, so it is SELECT ... INTO. COALESCE keeps
# doom_const's "0 when the name is missing" semantics.
_CONST_LINE = re.compile(r"^([ \t]*)(\w+) := doom_const\('([A-Za-z0-9_]+)'\);[ \t]*$")


def batch_const_lookups(body):
    lines, out, i = body.split("\n"), [], 0
    while i < len(lines):
        j = i
        while j < len(lines) and _CONST_LINE.match(lines[j]):
            j += 1
        if j - i < 2:
            out.append(lines[i])
            i += 1
            continue
        ms = [_CONST_LINE.match(x) for x in lines[i:j]]
        ind = ms[0].group(1)
        cols = ",\n".join(f"{ind}       COALESCE(max(value) FILTER (WHERE name = '{m.group(3)}'), 0)"
                          for m in ms)
        names = ", ".join(sorted({f"'{m.group(3)}'" for m in ms}))
        out.append(f"{ind}-- {j - i} constants in one scan (was {j - i} doom_const() calls)\n"
                   f"{ind}SELECT\n{cols}\n"
                   f"{ind}  INTO {', '.join(m.group(2) for m in ms)}\n"
                   f"{ind}  FROM doom_constants WHERE name IN ({names});")
        i = j
    return "\n".join(out)


# PERF fixes for renderer.sql (the per-frame statement), applied when its text
# is PREPAREd. Both decode in bulk instead of per pixel / per panel.
# A/B on 18 poses of E1M1: all frames byte-identical; server p50 1253 -> 428 ms,
# worst pose 3602 -> 675 ms.
_RENDERER_MARKER = "\npanel_clips AS ("
_PANEL_LATERALS = """  FROM panel_seq p
  CROSS JOIN render_settings rs
  CROSS JOIN cam c
  LEFT JOIN LATERAL (
    SELECT q.fsec, q.f_ceil, q.f_light, q.f_ceil_is_sky AS is_sky
    FROM panel_seq q
    WHERE q.col_x = p.col_x AND q.seq < p.seq
      AND q.f_ceil > c.pz
    ORDER BY q.seq DESC
    LIMIT 1
  ) pc ON TRUE
  LEFT JOIN LATERAL (
    SELECT q.fsec, q.f_floor, q.f_light
    FROM panel_seq q
    WHERE q.col_x = p.col_x AND q.seq < p.seq
      AND q.f_floor < c.pz
    ORDER BY q.seq DESC
    LIMIT 1
  ) pf ON TRUE
"""
_PANEL_JOINS = """  -- Nearest earlier panel per column, carried in one window pass
  -- (panel_carry packs seq|fsec|height|light|sky into a bigint, max = latest)
  -- and decoded here: no join back to panel_seq. Joins on (col_x, seq) were
  -- estimated at 1 row and ran as 960x960 nested loops on E1M2 (450 ms).
  FROM panel_carry p
  CROSS JOIN render_settings rs
  CROSS JOIN cam c
  CROSS JOIN LATERAL (SELECT ((p.pc_pack >> 32) & 65535)::int AS fsec,
                             ((((p.pc_pack >> 16) & 65535) - 32768))::smallint AS f_ceil,
                             ((p.pc_pack >> 1) & 32767)::smallint AS f_light,
                             ((p.pc_pack & 1) = 1) AS is_sky) pc
  CROSS JOIN LATERAL (SELECT ((p.pf_pack >> 32) & 65535)::int AS fsec,
                             ((((p.pf_pack >> 16) & 65535) - 32768))::smallint AS f_floor,
                             (p.pf_pack & 65535)::smallint AS f_light) pf
"""
_PANEL_CARRY = """
panel_carry AS (
  -- Packing (bits): seq 15 | fsec 16 | height+32768 16 | light 15 | sky 1.
  -- seq is the top field, so MAX picks the latest qualifying panel.
  SELECT q.*,
         MAX(CASE WHEN q.f_ceil > c.pz THEN
               (((q.seq << 48) | (q.fsec::bigint << 32))
                | ((q.f_ceil::int + 32768)::bigint << 16)
                | (q.f_light::bigint << 1) | q.f_ceil_is_sky::int) END) OVER w AS pc_pack,
         MAX(CASE WHEN q.f_floor < c.pz THEN
               (((q.seq << 48) | (q.fsec::bigint << 32))
                | ((q.f_floor::int + 32768)::bigint << 16)
                | q.f_light::bigint) END) OVER w AS pf_pack
  FROM panel_seq q CROSS JOIN cam c
  WINDOW w AS (PARTITION BY q.col_x ORDER BY q.seq ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
),
panel_clips AS ("""
_FRAME_TEXTURES = """
frame_flats AS MATERIALIZED (
  -- every flat decoded once per frame instead of once per floor/ceiling pixel;
  -- fid gives an integer join key (text hashing costs 310 ms vs 9 ms on 37K rows).
  SELECT row_number() OVER () AS fid, name,
         palette_indices || ''::bytea AS palette_indices FROM flat_textures
),
frame_sky AS MATERIALIZED (
  SELECT wt.name, wt.width, wt.palette_indices || ''::bytea AS palette_indices
  FROM walltex_meta wt JOIN maps m ON m.sky_texture = wt.name
  JOIN render_context rc ON rc.map_id = m.map_id
),
plane_color AS ("""
# (old, new). `x || ''::bytea` forces one detoast per row: textures are
# TOAST-compressed, and GET_BYTE on the stored value decompresses the whole
# texture again on every call (per pixel).
RENDERER_FIXES = [
    ("m.palette_indices      AS tex_pi", "(m.palette_indices || ''::bytea) AS tex_pi"),
    ("sf.left_offset, sf.top_offset, sl.pixels, sl.mask,",
     "sf.left_offset, sf.top_offset, (sl.pixels || ''::bytea) AS pixels, (sl.mask || ''::bytea) AS mask,"),
    ("         sl.pixels, sl.mask,\n         p.sx - sf.left_offset",
     "         (sl.pixels || ''::bytea) AS pixels, (sl.mask || ''::bytea) AS mask,\n         p.sx - sf.left_offset"),
    ("\nplane_color AS (", _FRAME_TEXTURES),
    ("  LEFT JOIN flat_textures ft\n    ON NOT p.is_sky", "  LEFT JOIN frame_flats ft\n    ON NOT p.is_sky"),
    ("  LEFT JOIN walltex_meta wt\n    ON p.is_sky", "  LEFT JOIN frame_sky wt\n    ON p.is_sky"),
    # PERF: text-key hash join on 37K floor/ceiling pixels costs ~220 ms.
    # Pre-resolve tex_name -> integer fid at the span level (~762 rows), carry
    # through the pipeline, join by integer at pixel level (~9 ms). A/B on 60
    # frames: byte-identical, server p50 406 -> 347 ms.
    ("\nplane_pixels AS (\n"
     "  SELECT ps.col_x AS x, y, ps.sector_id, ps.plane_z, ps.sector_light,\n"
     "         ps.plane, ps.is_sky, ps.source_priority\n"
     "  FROM plane_spans_deduped ps\n"
     "  CROSS JOIN LATERAL generate_series(ps.y0, ps.y1) AS y\n"
     "),",
     "\nplane_spans_textured AS (\n"
     "  -- Text->int lookup once per span (~762 rows); int carried to pixel level.\n"
     "  SELECT psd.*,\n"
     "    ft.fid AS flat_fid\n"
     "  FROM plane_spans_deduped psd\n"
     "  CROSS JOIN render_context rc\n"
     "  JOIN sectors_lit s ON s.id = psd.sector_id AND s.map_id = rc.map_id\n"
     "  LEFT JOIN frame_flats ft\n"
     "    ON NOT psd.is_sky\n"
     "    AND ft.name = (CASE WHEN psd.plane = 'floor' THEN s.floor_tex ELSE s.ceil_tex END)\n"
     "),\n"
     "plane_pixels AS (\n"
     "  SELECT ps.col_x AS x, y, ps.sector_id, ps.plane_z, ps.sector_light,\n"
     "         ps.plane, ps.is_sky, ps.source_priority, ps.flat_fid\n"
     "  FROM plane_spans_textured ps\n"
     "  CROSS JOIN LATERAL generate_series(ps.y0, ps.y1) AS y\n"
     "),"),
    ("    pp.x, pp.y, pp.sector_id, pp.sector_light, pp.plane, pp.source_priority,",
     "    pp.x, pp.y, pp.sector_id, pp.sector_light, pp.plane, pp.source_priority, pp.flat_fid, pp.is_sky,"),
    ("    pr.x, pr.y, pr.sector_id, pr.sector_light, pr.plane, pr.source_priority,",
     "    pr.x, pr.y, pr.sector_id, pr.sector_light, pr.plane, pr.source_priority, pr.flat_fid, pr.is_sky,"),
    ("    x, y, sector_id, sector_light, plane, source_priority, depth, tex_name,\n"
     "    (tex_name = 'F_SKY1') AS is_sky,",
     "    x, y, sector_id, sector_light, plane, source_priority, depth,\n"
     "    flat_fid, is_sky,"),
    ("  FROM plane_tex CROSS JOIN render_settings rs",
     "  FROM plane_world CROSS JOIN render_settings rs"),
    ("CASE WHEN tex_name = 'F_SKY1'\n      -- sky pans with view angle only",
     "CASE WHEN is_sky\n      -- sky pans with view angle only"),
    ("CASE WHEN tex_name = 'F_SKY1'\n      -- sky is drawn view-angle/row indexed",
     "CASE WHEN is_sky\n      -- sky is drawn view-angle/row indexed"),
    ("  LEFT JOIN frame_flats ft\n    ON NOT p.is_sky AND ft.name = p.tex_name\n"
     "  CROSS JOIN (SELECT m.sky_texture AS name\n"
     "              FROM maps m JOIN render_context rc ON rc.map_id = m.map_id) sk\n"
     "  LEFT JOIN frame_sky wt\n    ON p.is_sky AND wt.name = sk.name",
     "  LEFT JOIN frame_flats ft ON ft.fid = p.flat_fid\n"
     "  CROSS JOIN frame_sky sky"),
    # Rename wt → sky in the CASE WHEN expression (wt alias removed by the
    # FROM-clause replacement above).
    ("      WHEN p.is_sky AND wt.palette_indices IS NOT NULL THEN\n"
     "        CASE\n"
     "          WHEN (p.v_i * wt.width + p.u_i) >= 0\n"
     "            AND (p.v_i * wt.width + p.u_i) < OCTET_LENGTH(wt.palette_indices)\n"
     "          THEN GET_BYTE(\n"
     "            wt.palette_indices,\n"
     "            (p.v_i * wt.width + p.u_i)::int\n"
     "          )\n"
     "          ELSE 0\n"
     "        END",
     "      WHEN p.is_sky AND sky.palette_indices IS NOT NULL THEN\n"
     "        CASE\n"
     "          WHEN (p.v_i * sky.width + p.u_i) >= 0\n"
     "            AND (p.v_i * sky.width + p.u_i) < OCTET_LENGTH(sky.palette_indices)\n"
     "          THEN GET_BYTE(\n"
     "            sky.palette_indices,\n"
     "            (p.v_i * sky.width + p.u_i)::int\n"
     "          )\n"
     "          ELSE 0\n"
     "        END"),
    (_PANEL_LATERALS, _PANEL_JOINS),
    (_RENDERER_MARKER, _PANEL_CARRY),
    # PERF: player_sector joined sectors_lit (200 rows on E1M2) before the
    # ORDER BY seg_id LIMIT 1, and the planner rescanned the map's render_segs
    # per sector (200 x 1463 rows, ~105 ms). Pick the first seg, then its
    # sector. E1M2 frames byte-identical; with the panel fix 1164 -> 416 ms.
    ("  FROM bsp_order bo\n"
     "  JOIN render_context rc ON TRUE\n"
     "  JOIN render_segs sg ON sg.map_id = rc.map_id\n"
     "    AND sg.ssector_id = bo.ssector_id\n"
     "  JOIN sectors_lit sec ON sec.map_id = rc.map_id AND sec.id = sg.fsec\n"
     "  WHERE bo.bsp_seq = 1\n"
     "  ORDER BY sg.seg_id\n"
     "  LIMIT 1\n",
     "  FROM (SELECT sg.map_id, sg.fsec\n"
     "        FROM bsp_order bo\n"
     "        JOIN render_context rc ON TRUE\n"
     "        JOIN render_segs sg ON sg.map_id = rc.map_id\n"
     "          AND sg.ssector_id = bo.ssector_id\n"
     "        WHERE bo.bsp_seq = 1\n"
     "        ORDER BY sg.seg_id\n"
     "        LIMIT 1) sg\n"
     "  JOIN sectors_lit sec ON sec.map_id = sg.map_id AND sec.id = sg.fsec\n"
     "  LIMIT 1\n"),
    # PERF: framebuffer ends with an empty UNION ALL branch that exists only to
    # steer CedarDB's optimizer. Postgres still materializes all 256,000
    # generate_series rows before filtering them out (~27 ms/frame). Dropped:
    # 12 poses byte-identical; server p50 333 -> 309 ms. (An OFFSET 0-fenced
    # empty branch measured the same, so plain removal is used.)
    ("  UNION ALL -- hack to trick the optimizer\n"
     "  SELECT g AS x, 0 AS y, g AS pix, '\\x000000'::bytea AS rgb\n"
     "  FROM generate_series(0, 255999) AS g WHERE g + 0 < 0\n",
     ""),
    # PERF: resolved z-buffer uses GroupAggregate (sort 60K rows by pix then
    # aggregate). With OFFSET 0 the planner switches to HashAggregate (~5 ms
    # faster) and, because output is no longer pre-sorted, downstream palette_map
    # join flips from Merge to Hash (saves another ~8 ms in sort). A/B 30 poses
    # byte-identical; server p50 297 -> 282 ms.
    ("        FROM ranked_fragments GROUP BY pix) w",
     "        FROM (SELECT * FROM ranked_fragments OFFSET 0) rf GROUP BY pix) w"),
]


# PERF, round 2 (2026-10-22): applied to the renderer AFTER the dialect
# rewrites (postgres_rewrites), so the anchors are the Postgres text. Measured
# on 14 E1M1 poses, A/B inside one REPEATABLE READ snapshot (frozen game
# state), indexed and RGB frame views: every frame byte-identical (also with a
# pickup message and a damage palette forced on); server time sum -39%,
# p50 303 -> 187 ms, worst pose 593 -> 349 ms (8 CU primary).
# Applied all-or-nothing: if any anchor is missing (another renderer shape,
# e.g. the stats splice), the statement is left exactly as it was.
# Tags: E5 weapon sprite folded into the z-resolve as always-winning keys (no
# FULL JOIN + sort); E2 skip the hole fill when the view is fully covered;
# E4/E8 plane depth once per pixel, depth numerator and ray slope once per
# span, float8 twins of the numeric render settings (each equal to the
# implicit cast the per-row arithmetic did), 64-wide positive modulo as & 63;
# E1 zdepth in float8 (floor of a correctly rounded small-int quotient is
# exact); E3 view-angle trig once, ray angle only for sky pixels; E9 wall u
# once per span; O1 HUD message folded into the z-resolve (level 0, over the
# weapon) instead of two joins per pixel; O3 drop an unused LEFT JOIN (indexed
# variant only: the RGB variant still reads barcm); O7 resolve fed in pixel
# order (the final ORDER BY pix gets presorted input); O8 status-bar group by
# on sorted input (its HashAggregate sized itself from the wild row estimate:
# 7 ms for 1,772 rows).
# Rejected after measuring: inlining plane_world (+50..80%: the stored CTE
# keeps a good plan), COLORMAP as an array, single-key palette join, planner
# GUCs.
RENDERER_POST_FIXES = [
    ('E5',
     '        FROM (SELECT * FROM ranked_fragments OFFSET 0) rf GROUP BY pix) w',
     '        FROM (SELECT pix, winner_key FROM ranked_fragments\n              UNION ALL\n              -- the weapon is drawn over everything: a key below any depth key\n              SELECT p.y*rs0.screen_w+p.x, (-(1::bigint << 62)) | (p.light_index::bigint << 8) | p.palette_index::bigint\n              FROM psprite_resolved p CROSS JOIN render_settings rs0\n              OFFSET 0) rf GROUP BY pix) w'),
    ('E5',
     '  SELECT COALESCE(p.x,r.x) AS x, COALESCE(p.y,r.y) AS y,\n         COALESCE(p.light_index,r.light_index) AS light_index,\n         COALESCE(p.palette_index,r.palette_index) AS palette_index\n  FROM resolved r FULL JOIN psprite_resolved p USING (x,y)\n',
     '  SELECT r.x, r.y, r.light_index, r.palette_index\n  FROM resolved r\n'),
    ('E2',
     '  FROM render_settings rs\n  CROSS JOIN LATERAL generate_series(0, rs.screen_w - 1) AS sx(x)',
     '  FROM render_settings rs\n  CROSS JOIN LATERAL generate_series(0, CASE WHEN (SELECT count(*) FROM final_pixels) < rs.screen_w * rs.screen_h THEN rs.screen_w - 1 ELSE -1 END) AS sx(x)'),
    ('E4',
     '    CASE WHEN pp.is_sky THEN 1e7::float8\n         ELSE (rs.focal * (pp.plane_z - c.pz)) / NULLIF(rs.cy - pp.y, 0.0)\n    END AS depth_x,\n    (pp.x - rs.cx) / rs.focal AS tan_alpha\n  FROM plane_pixels pp\n  CROSS JOIN cam c\n  CROSS JOIN render_settings rs\n  WHERE pp.is_sky\n     OR (rs.focal * (pp.plane_z - c.pz)) / NULLIF(rs.cy - pp.y, 0.0) > rs.near\n),',
     '    CASE WHEN pp.is_sky THEN 1e7::float8 ELSE pp.d END AS depth_x,\n    (pp.x - rs.cx) / rs.focal AS tan_alpha\n  FROM (SELECT q.*, (rs0.focal * (q.plane_z - c0.pz)) / NULLIF(rs0.cy - q.y, 0.0) AS d\n        FROM plane_pixels q CROSS JOIN cam c0 CROSS JOIN render_settings rs0 OFFSET 0) pp\n  CROSS JOIN render_settings rs\n  WHERE pp.is_sky OR pp.d > rs.near\n),'),
    ('E1',
     'doom_light_zdepth(depth)',
     'FLOOR(80.0::float8 / (LEAST(127, FLOOR(depth / 16.0)::int) + 1))::int'),
    ('E3',
     '    (c.px + pr.depth_x * COS(c.view_rad) + (pr.tan_alpha * pr.depth_x) * SIN(c.view_rad)) AS wx,\n    (c.py + pr.depth_x * SIN(c.view_rad) - (pr.tan_alpha * pr.depth_x) * COS(c.view_rad)) AS wy,\n    -- absolute ray angle, for sky panning (view-angle indexed)\n    degrees(c.view_rad - ATAN(pr.tan_alpha)) AS ray_deg\n  FROM plane_rays pr\n  CROSS JOIN cam c\n',
     '    (c.px + pr.depth_x * c.cos_v + (pr.tan_alpha * pr.depth_x) * c.sin_v) AS wx,\n    (c.py + pr.depth_x * c.sin_v - (pr.tan_alpha * pr.depth_x) * c.cos_v) AS wy,\n    -- absolute ray angle, for sky panning (view-angle indexed)\n    CASE WHEN pr.is_sky THEN degrees(c.view_rad - ATAN(pr.tan_alpha)) END AS ray_deg\n  FROM plane_rays pr\n  CROSS JOIN (SELECT cc.*, COS(cc.view_rad) AS cos_v, SIN(cc.view_rad) AS sin_v FROM cam cc) c\n'),
    ('E8',
     '      64::int AS flat_size\n',
     '      64::int AS flat_size,\n      ((320::int)/2.0)::float8 AS cx_f,\n      ((168::int)/2.0)::float8 AS cy_f,\n      (1e-3)::float8 AS near_f,\n      (256.0/90.0)::float8 AS sky_ratio_f,\n      256::int AS sky_columns_i\n'),
    ('E8',
     '  SELECT ps.col_x AS x, y, ps.sector_id, ps.plane_z, ps.sector_light,\n         ps.plane, ps.is_sky, ps.source_priority, ps.flat_fid\n  FROM plane_spans_textured ps\n',
     '  SELECT ps.col_x AS x, y, ps.sector_id, ps.plane_z, ps.sector_light,\n         ps.plane, ps.is_sky, ps.source_priority, ps.flat_fid, ps.k_num, ps.tan_alpha\n  FROM (SELECT s.*, rs.focal * (s.plane_z - c.pz) AS k_num, (s.col_x - rs.cx_f) / rs.focal AS tan_alpha\n        FROM plane_spans_textured s CROSS JOIN cam c CROSS JOIN render_settings rs OFFSET 0) ps\n'),
    ('E8',
     '    CASE WHEN pp.is_sky THEN 1e7::float8 ELSE pp.d END AS depth_x,\n    (pp.x - rs.cx) / rs.focal AS tan_alpha\n  FROM (SELECT q.*, (rs0.focal * (q.plane_z - c0.pz)) / NULLIF(rs0.cy - q.y, 0.0) AS d\n        FROM plane_pixels q CROSS JOIN cam c0 CROSS JOIN render_settings rs0 OFFSET 0) pp\n  CROSS JOIN render_settings rs\n  WHERE pp.is_sky OR pp.d > rs.near\n),',
     '    CASE WHEN pp.is_sky THEN 1e7::float8 ELSE pp.d END AS depth_x,\n    pp.tan_alpha\n  FROM (SELECT q.*, q.k_num / NULLIF(rs0.cy_f - q.y, 0.0::float8) AS d\n        FROM plane_pixels q CROSS JOIN render_settings rs0 OFFSET 0) pp\n  CROSS JOIN render_settings rs\n  WHERE pp.is_sky OR pp.d > rs.near_f\n),'),
    ('E8',
     '      THEN ((FLOOR(ray_deg * (rs.sky_columns/rs.sky_degrees))::int\n             % rs.sky_columns::int) + rs.sky_columns::int) % rs.sky_columns::int\n',
     '      THEN ((FLOOR(ray_deg * rs.sky_ratio_f)::int\n             % rs.sky_columns_i) + rs.sky_columns_i) % rs.sky_columns_i\n'),
    ('E8',
     '      ELSE ((FLOOR(wx)::int % rs.flat_size) + rs.flat_size) % rs.flat_size\n    END AS u_i,',
     '      ELSE FLOOR(wx)::int & 63  -- = positive modulo flat_size (64)\n    END AS u_i,'),
    ('E8',
     '      ELSE ((FLOOR(wy)::int % rs.flat_size) + rs.flat_size) % rs.flat_size\n    END AS v_i',
     '      ELSE FLOOR(wy)::int & 63\n    END AS v_i'),
    ('E9',
     '    (FLOOR(c.u_col - c.tex_w * FLOOR(c.u_col / c.tex_w))::int) AS u_i,\n',
     '    c.u_i0 AS u_i,\n'),
    ('E9',
     "  FROM clamped_spans_lit c\n  CROSS JOIN LATERAL generate_series(c.y_start, c.y_end) AS y\n  WHERE c.tex IS NOT NULL AND c.tex <> '-'\n",
     "  FROM (SELECT s.*, (FLOOR(s.u_col - s.tex_w * FLOOR(s.u_col / s.tex_w))::int) AS u_i0\n        FROM clamped_spans_lit s WHERE s.tex IS NOT NULL AND s.tex <> '-' OFFSET 0) c\n  CROSS JOIN LATERAL generate_series(c.y_start, c.y_end) AS y\n"),
    ('E2b',
     '(SELECT count(*) FROM final_pixels) < rs.screen_w * rs.screen_h',
     '(SELECT count(*) FROM final_pixels f0 WHERE f0.x BETWEEN 0 AND rs.screen_w - 1 AND f0.y BETWEEN 0 AND rs.screen_h - 1) < rs.screen_w * rs.screen_h'),
    ('O1',
     '              FROM psprite_resolved p CROSS JOIN render_settings rs0\n              OFFSET 0) rf GROUP BY pix) w',
     '              FROM psprite_resolved p CROSS JOIN render_settings rs0\n              UNION ALL\n              -- the HUD pickup line is drawn over the weapon, at COLORMAP level 0\n              SELECT m.y*320+m.x, (1::bigint << 63) | m.palette_index::bigint\n              FROM message_pixels m WHERE m.x BETWEEN 0 AND 319 AND m.y BETWEEN 0 AND 167\n              OFFSET 0) rf GROUP BY pix) w'),
    ('O1',
     '  SELECT v.x, v.y, v.y * 4096 + v.x AS pix, COALESCE(m.rgb, v.rgb) AS rgb\n  FROM view_colored v\n  LEFT JOIN message_colored m ON m.x = v.x AND m.y = v.y\n',
     '  SELECT v.x, v.y, v.y * 4096 + v.x AS pix, v.rgb\n  FROM view_colored v\n'),
    ('O1',
     '  SELECT h.x, h.y, h.y * 4096 + h.x AS pix, COALESCE(m.rgb, h.rgb) AS rgb\n  FROM view_holes h\n  LEFT JOIN message_colored m ON m.x = h.x AND m.y = h.y\n',
     '  SELECT h.x, h.y, h.y * 4096 + h.x AS pix, h.rgb\n  FROM view_holes h\n'),
    ('O1',
     'message_colored AS (\n  SELECT m.x, m.y, cm.rgb\n  FROM message_pixels m\n  CROSS JOIN render_context rc\n  JOIN palette_map cm ON cm.level = 0 AND cm.palette_index = m.palette_index\n  WHERE m.x BETWEEN 0 AND 319 AND m.y BETWEEN 0 AND 167\n),\n',
     ''),
    ('O3',
     '  LEFT JOIN palette_map ovcm\n    ON ovcm.level = 0 AND ovcm.palette_index = ur.palette_index\n  LEFT JOIN palette_map barcm\n    ON ap.pal <> 0 AND barcm.level = 0\n   AND barcm.palette_index = s.palette_index\n',
     '  LEFT JOIN palette_map ovcm\n    ON ovcm.level = 0 AND ovcm.palette_index = ur.palette_index\n'),
    ('O7',
     '              OFFSET 0) rf GROUP BY pix) w',
     '              ORDER BY 1) rf GROUP BY pix) w'),
    ('O8',
     '  FROM ui_pixels GROUP BY x,y\n',
     '  FROM (SELECT * FROM ui_pixels ORDER BY x, y) u GROUP BY x,y\n'),
    # T: the numeric render settings typed float8 at the source, so the
    # remaining per-column / per-thing uses (vertical, plane_spans_raw,
    # thing_*, psprite_*) stop converting too. Byte-identical on the same
    # 14 poses (indexed, RGB, message + damage tint); a further -1.4..1.8%.
    ('T', '      ((320::int)/2.0) AS cx,\n', '      ((320::int)/2.0)::float8 AS cx,\n'),
    ('T', '      ((168::int)/2.0) AS cy,\n', '      ((168::int)/2.0)::float8 AS cy,\n'),
    ('T', '      1e-3 AS near,\n', '      (1e-3)::float8 AS near,\n'),
    ('T', '      256.0 AS sky_columns,\n', '      256.0::float8 AS sky_columns,\n'),
    ('T', '      90.0  AS sky_degrees,\n', '      90.0::float8  AS sky_degrees,\n'),
    # R1-R4 (render review, 2026-10-23). Byte-identical on 10 poses (E1M1 +
    # E1M6; indexed, low-detail, RGB). Indexed frame exec E1M1 232 -> 170 ms,
    # E1M6 503 -> 189 ms (worst pose 1346 -> 299); planning 79 -> 51 ms.
    # R1: sprite and weapon patches once, not decompressed + copied per pixel.
    ('R1', '\nthing_projected AS (\n', '\nthing_projected AS MATERIALIZED (\n'),
    ('R1', '\npsprite_patches AS (\n', '\npsprite_patches AS MATERIALIZED (\n'),
    # R2: the "+ 0" disabled render_segs_pkey: every heights row scanned all
    # the map's segs (261K rows thrown away per frame on E1M1).
    ('R2', '  JOIN render_segs s ON s.map_id = p.map_id AND s.seg_id + 0 = p.seg_id -- psst, optimizer hack\n',
           '  JOIN render_segs s ON s.map_id = p.map_id AND s.seg_id = p.seg_id\n'),
    # R3: each wall texture this frame uses, decompressed once.
    ('R3', '\nwall_parts_tex AS (\n',
           '\nframe_walltex AS MATERIALIZED (\n'
           '  -- each wall texture this frame uses, decompressed once\n'
           "  SELECT wt.name, wt.width, wt.height, (wt.palette_indices || ''::bytea) AS palette_indices\n"
           '  FROM walltex_meta wt\n'
           '  WHERE wt.name IN (SELECT wp0.tex FROM wall_parts wp0)\n'
           '),\nwall_parts_tex AS (\n'),
    ('R3', "         (m.palette_indices || ''::bytea) AS tex_pi\n  FROM wall_parts wp\n  LEFT JOIN walltex_meta m ON m.name = wp.tex\n",
           '         m.palette_indices AS tex_pi\n  FROM wall_parts wp\n  LEFT JOIN frame_walltex m ON m.name = wp.tex\n'),
    # R4: BSP visibility once per frame (with node_path_steps_map_id from
    # postgres_compat.sql: 2,228 of 32,770 rows read with 9 maps loaded).
    ('R4', '\nvisible_children AS (\n', '\nvisible_children AS MATERIALIZED (\n'),
]


def apply_renderer_post_fixes(sql, report=None):
    """RENDERER_POST_FIXES on a renderer statement (after the dialect
    rewrites); all-or-nothing, so an unknown renderer shape stays as it was."""
    if "panel_carry AS (" not in sql or "AS sky_columns_i" in sql:
        return sql
    out = sql
    for tag, old, new in RENDERER_POST_FIXES:
        if tag == "O3" and "barcm.rgb" in out:      # RGB variant still reads barcm
            continue
        if out.count(old) != 1:
            if report is not None:
                report.append(f"renderer post-fix {tag} skipped: anchor found {out.count(old)} times")
            return sql
        out = out.replace(old, new)
    return out


# --- frame tail: depth sort, colormap rows, hole fill ------------------------
# On the stored (pg_get_viewdef) text of an indexed frame view, full or low
# detail, after the status-bar cache rewrite. From an external performance review, measured
# 2026-10-28 on 8 CU, 13 poses (E1M1/E1M6/E1M9), median of 5 runs:
#  * depth: one sort (DISTINCT ON pix ORDER BY pix, winner_key) instead of a
#    sort + GROUP BY min(): -7 ms;
#  * colour: one 256-byte row per (palette, light level) in colormap_idx_lvl
#    (postgres_compat.sql), substring() by palette index, instead of a hash
#    join over the palette's 8,704 colormap_rgb rows: -3 ms;
#  * holes: every screen pixel LEFT JOINs the resolved pixels once, instead of
#    counting them and a NOT EXISTS per pixel (holes are common here, and the
#    low view ran its NOT EXISTS on every frame): with the two above, full
#    detail 182.6 -> 167.5 ms, low detail 105.6 -> 91.2 ms.
# Byte-identical on the 13 poses and in 6 lighting states plus the muzzle
# flash. All-or-nothing: an unknown shape keeps the view as it is. Not for the
# RGB views (no gain measured there).
FRAME_TAIL_RES_OLD = """           FROM (( SELECT rf.pix,
                    min(rf.winner_key) AS winner_key
                   FROM ( SELECT ranked_fragments.pix,"""
FRAME_TAIL_RES_NEW = """           FROM (( SELECT DISTINCT ON (rf.pix) rf.pix,
                    rf.winner_key
                   FROM ( SELECT ranked_fragments.pix,"""
FRAME_TAIL_GROUP_OLD = """                  ORDER BY 1) rf
                  GROUP BY rf.pix) w"""
FRAME_TAIL_GROUP_NEW = """) rf
                  ORDER BY rf.pix, rf.winner_key) w"""


def frame_tail_view_sql(sql, low=False):
    """Indexed frame view body (stored text) -> same frame, faster tail.
    Returns None when the shape is not the expected one."""
    sql = sql.rstrip().rstrip(";")
    if "colormap_idx_lvl" in sql:                     # already applied
        return sql
    if sql.count(FRAME_TAIL_RES_OLD) != 1 or sql.count(FRAME_TAIL_GROUP_OLD) != 1:
        return None
    a = sql.find("        ), view_holes AS (")
    b = sql.find("        ), hud_key AS (", a)
    if a < 0 or b < 0 or sql.count("        ), view_holes AS (") != 1:
        return None
    if low:   # scene columns 0, 2, ..., 318: 160 x 168 positions
        grid, pix = "generate_series(0, 26879) g(i)", "(((g.i / 160) * 320) + ((g.i % 160) * 2))"
    else:
        grid, pix = "generate_series(0, 53759) g(i)", "g.i"
    tail = ("        ), framebuffer AS (\n"
            f"         SELECT {pix} AS pix,\n"
            "            COALESCE(substring(cl.bytes FROM (r.palette_index + 1) FOR 1), '\\x00'::bytea) AS rgb\n"
            f"           FROM (({grid}\n"
            f"             LEFT JOIN final_pixels r ON ((((r.y * 320) + r.x) = {pix})))\n"
            "             LEFT JOIN ( SELECT b.level, b.bytes FROM (colormap_idx_lvl b JOIN active_palette ap ON ((b.pal = ap.pal)))) cl"
            " ON ((cl.level = r.light_index)))\n")
    out = sql[:a] + tail + sql[b:]
    out = out.replace(FRAME_TAIL_RES_OLD, FRAME_TAIL_RES_NEW).replace(FRAME_TAIL_GROUP_OLD, FRAME_TAIL_GROUP_NEW)
    return out


# --- leaner frame plan (after frame_tail_view_sql) ----------------------------
# On the stored text of an indexed frame view (full or low) that already has
# the frame tail. Measured 2026-11-03 on 8 CU, prepared statements, best of 3:
#  * render_settings NOT MATERIALIZED: it is all constants, so Postgres folds
#    them into the expressions instead of joining a one-row CTE scan into each
#    per-pixel stage (planning goes ~50 -> ~100 ms, paid once per prepared
#    statement since frames are prepared per connection);
#  * the hole join on the resolved pixel number (already sorted by the depth
#    sort) instead of recomputing y * 320 + x, which forced a second sort;
#  * the palette's 34 colormap rows as one in-query bytea (an InitPlan, not
#    TOASTed) instead of a join per pixel; with the join on pix, a join here
#    turned into a nested loop over 1.8M rows;
#  * plane_tex, a CTE nothing reads, dropped: its reference made plane_world
#    materialize.
# E1M9 full 211.9 -> 189.3 ms, low 126.0 -> 115.8 ms (14 poses); E1M1 full
# 194.3 -> 175.0 ms, low 107.3 -> 96.9 ms (10 poses). Byte-identical on all.
# All-or-nothing: an unknown shape returns None and the view is kept.
_LEAN_RES_OLD = """         SELECT (w.pix % rs.screen_w) AS x,
            (w.pix / rs.screen_w) AS y,"""
_LEAN_RES_NEW = """         SELECT w.pix,
            (w.pix % rs.screen_w) AS x,
            (w.pix / rs.screen_w) AS y,"""
_LEAN_FP_OLD = """final_pixels AS (
         SELECT r.x,"""
_LEAN_FP_NEW = """final_pixels AS (
         SELECT r.pix,
            r.x,"""


def frame_lean_view_sql(sql, low=False):
    """Indexed frame view body with the frame tail -> same frame, leaner plan.
    Returns None when the shape is not the expected one."""
    sql = sql.rstrip().rstrip(";")
    if "render_settings AS NOT MATERIALIZED" in sql:      # already applied
        return sql
    if low:
        grid, pix = "generate_series(0, 26879) g(i)", "(((g.i / 160) * 320) + ((g.i % 160) * 2))"
    else:
        grid, pix = "generate_series(0, 53759) g(i)", "g.i"
    fb_old = ("            COALESCE(SUBSTRING(cl.bytes FROM (r.palette_index + 1) FOR 1), '\\x00'::bytea) AS rgb\n"
              f"           FROM (({grid}\n"
              f"             LEFT JOIN final_pixels r ON ((((r.y * 320) + r.x) = {pix})))\n"
              "             LEFT JOIN ( SELECT b.level,\n"
              "                    b.bytes\n"
              "                   FROM (colormap_idx_lvl b\n"
              "                     JOIN active_palette ap ON ((b.pal = ap.pal)))) cl ON ((cl.level = r.light_index)))")
    fb_new = ("            COALESCE(CASE WHEN r.light_index BETWEEN 0 AND 33 THEN SUBSTRING((SELECT string_agg(b.bytes, '\\x'::bytea ORDER BY b.level)\n"
              "                   FROM colormap_idx_lvl b JOIN active_palette ap ON b.pal = ap.pal) FROM r.light_index * 256 + r.palette_index + 1 FOR 1) END, '\\x00'::bytea) AS rgb\n"
              f"           FROM ({grid}\n"
              f"             LEFT JOIN final_pixels r ON ((r.pix = {pix})))")
    pairs = [("\n        ), render_settings AS (", "\n        ), render_settings AS NOT MATERIALIZED ("),
             (_LEAN_RES_OLD, _LEAN_RES_NEW), (_LEAN_FP_OLD, _LEAN_FP_NEW), (fb_old, fb_new)]
    for old, new in pairs:
        if sql.count(old) != 1:
            return None
        sql = sql.replace(old, new)
    if len(re.findall(r"\bplane_tex\b", sql)) == 1:      # defined, never read
        m = re.search(r"\n        \), plane_tex AS \(", sql)
        e = sql.find("\n        ), ", m.end()) if m else -1
        if m and e > 0:
            sql = sql[:m.start()] + sql[e:]
    return sql


# --- per-column occlusion (after frame_lean_view_sql) -------------------------
# The depth sort keeps, per pixel, the fragment with the smallest key; the key
# starts with the depth rounded to 1/4096 (the same expression as _OCC_QD).
# Every wall fragment is opaque. So a fragment certainly loses where a wall
# span of the same screen column, strictly nearer by that rounded depth,
# covers its row (a floor or ceiling also loses at equal depth: walls rank
# first on ties). occ_rows lists the drawn wall spans per column; a wall
# column, or a floor/ceiling span, is cut from the top or the bottom when one
# nearer span covers its first or last row (one pass: what it misses still
# goes through the depth sort). Wall texture rows keep the original start
# (v0 is computed from it), so the bytes cannot change. A floor or ceiling
# span's depth is monotonic on its side of the horizon, so its smallest
# rounded depth over the cut rows is at one of the two ends; sky ranks at
# 1e7 like plane_rays. Only applied to the 320 x 168 scene (cy = 84).
# Measured 2026-11-03 on 8 CU, prepared, best of 3, interleaved:
#   E1M9 full, 44 poses: mean 187.6 -> 182.8 ms, p90 225.1 -> 212.6 ms,
#     median +1.1 ms, overdraw poses -73 to -90 ms;
#   E1M9 low: mean 112.9 -> 110.3, p90 134.1 -> 129.9;
#   E1M1 full, 20 poses: 176.1 -> 166.4; low 96.8 -> 91.9.
# Byte-identical on all 128 frames. All-or-nothing: None on an unknown shape.
_OCC_QD = "((GREATEST((0.0)::double precision, LEAST({d}, (131071.0)::double precision)) * (4096)::double precision))::bigint"
_OCC_FRAG_OLD = """                   FROM clamped_spans_lit s
                  WHERE ((s.tex IS NOT NULL) AND ((s.tex)::text <> '-'::text))
                 OFFSET 0) c
             CROSS JOIN LATERAL generate_series(c.y_start, c.y_end) y(y))"""
_OCC_FRAG_NEW = """                   FROM clamped_spans_lit s
                  WHERE ((s.tex IS NOT NULL) AND ((s.tex)::text <> '-'::text))
                 OFFSET 0) c
             LEFT JOIN wall_trim wt ON ((wt.col_x = c.col_x) AND (wt.seg_id = c.seg_id) AND (wt.part = c.part))
             CROSS JOIN LATERAL generate_series(COALESCE(wt.top_cover + 1, c.y_start), COALESCE(wt.bot_cover - 1, c.y_end)) y(y))"""
_OCC_PP_NEW = """           FROM ((plane_span_rows ps
             LEFT JOIN plane_trim pt ON ((pt.sid = ps.sid)))
             CROSS JOIN LATERAL generate_series(COALESCE(pt.top_cover + 1, ps.y0), COALESCE(pt.bot_cover - 1, ps.y1)) y(y))"""


def _occ_cte_text(sql, name):
    m = re.search(r"\n        \), " + name + r" AS (?:NOT )?(?:MATERIALIZED )?\(", sql)
    if not m:
        return None
    e = sql.find("\n        ), ", m.end())
    return sql[m.start() + 12:e] if e > 0 else None


def _occ_plane_qd(row):
    sky = _OCC_QD.format(d="(10000000.0)::double precision")
    d = f"(ps.k_num / NULLIF(((84.0)::double precision - ({row})::double precision), (0.0)::double precision))"
    return f"CASE WHEN ps.is_sky THEN {sky} ELSE {_OCC_QD.format(d=d)} END"


def _occ_same_side(a, b):
    return (f"(ps.is_sky OR sign((84.0)::double precision - ({a})::double precision) * "
            f"sign((84.0)::double precision - ({b})::double precision) > 0)")


def frame_occlusion_view_sql(sql):
    """Indexed frame view body (full or low, after frame_lean_view_sql) ->
    same frame, hidden wall and floor/ceiling rows not generated.
    Returns None when the shape is not the expected one."""
    sql = sql.rstrip().rstrip(";")
    if "occ_rows AS MATERIALIZED" in sql:                 # already applied
        return sql
    rs = _occ_cte_text(sql, "render_settings")
    cs = _occ_cte_text(sql, "clamped_spans")
    pp = _occ_cte_text(sql, "plane_pixels")
    if not (rs and cs and pp) or "168 AS screen_h" not in rs or "(((168)::numeric / 2.0))::double precision AS cy_f" not in rs:
        return None
    m_ys = re.search(r"\n\s+(\(ceil\(LEAST\(.*?\)\)::integer) AS y_start", cs)
    m_ye = re.search(r"\n\s+(\(floor\(LEAST\(.*?\)\)::integer) AS y_end", cs)
    m_wh = re.search(r"FROM \(vertical v\n\s+CROSS JOIN render_settings rs\)\n\s+WHERE (\(\(LEAST\(v\.y_top_f.*?\)\)\)) t\n", cs, re.S)
    a = pp.find("           FROM (( SELECT s.col_x,")
    b = pp.find("                 OFFSET 0) ps")
    if not (m_ys and m_ye and m_wh) or a < 0 or b < 0:
        return None
    where = m_wh.group(1)[:-1]
    if where.count("(") != where.count(")"):
        return None
    pp_block_old = pp[a:]
    if not pp_block_old.endswith("generate_series(ps.y0, ps.y1) y(y))"):
        return None
    inner = pp[a + len("           FROM (( "):b].rstrip()
    anchor_w, anchor_p = "\n        ), clamped_spans_lit AS (", "\n        ), plane_pixels AS ("
    if (sql.count(_OCC_FRAG_OLD) != 1 or sql.count(pp_block_old) != 1
            or sql.count(anchor_w) != 1 or sql.count(anchor_p) != 1):
        return None
    occ_ctes = f"""
        ), occ_rows AS MATERIALIZED (
         SELECT o.col_x, o.seg_id, o.part, o.y_start, o.y_end, o.qd
           FROM ( SELECT v.col_x, v.seg_id, v.part,
                    {m_ys.group(1)} AS y_start,
                    {m_ye.group(1)} AS y_end,
                    {_OCC_QD.format(d='v.depth_x')} AS qd
                   FROM (vertical v
                     CROSS JOIN render_settings rs)
                  WHERE ({where} AND (v.tex IS NOT NULL) AND ((v.tex)::text <> '-'::text))) o
          WHERE (o.y_end >= o.y_start)
        ), wall_trim AS MATERIALIZED (
         SELECT a.col_x, a.seg_id, a.part,
            max(b.y_end) FILTER (WHERE b.y_start <= a.y_start AND b.y_end >= a.y_start) AS top_cover,
            min(b.y_start) FILTER (WHERE b.y_start <= a.y_end AND b.y_end >= a.y_end) AS bot_cover
           FROM (occ_rows a
             JOIN occ_rows b ON ((b.col_x = a.col_x) AND (b.qd < a.qd)))
          GROUP BY a.col_x, a.seg_id, a.part"""
    top = (f"o.y_start <= ps.y0 AND o.y_end >= ps.y0 AND {_occ_same_side('ps.y0', 'LEAST(ps.y1, o.y_end)')} "
           f"AND o.qd <= LEAST({_occ_plane_qd('ps.y0')}, {_occ_plane_qd('LEAST(ps.y1, o.y_end)')})")
    bot = (f"o.y_start <= ps.y1 AND o.y_end >= ps.y1 AND {_occ_same_side('GREATEST(ps.y0, o.y_start)', 'ps.y1')} "
           f"AND o.qd <= LEAST({_occ_plane_qd('GREATEST(ps.y0, o.y_start)')}, {_occ_plane_qd('ps.y1')})")
    plane_ctes = f"""
        ), plane_span_rows AS MATERIALIZED (
         SELECT row_number() OVER () AS sid, q.*
           FROM ( {inner}) q
        ), plane_trim AS MATERIALIZED (
         SELECT ps.sid,
            max(o.y_end) FILTER (WHERE {top}) AS top_cover,
            min(o.y_start) FILTER (WHERE {bot}) AS bot_cover
           FROM (plane_span_rows ps
             JOIN occ_rows o ON ((o.col_x = ps.col_x) AND (((o.y_start <= ps.y0) AND (o.y_end >= ps.y0)) OR ((o.y_start <= ps.y1) AND (o.y_end >= ps.y1)))))
          GROUP BY ps.sid"""
    sql = sql.replace(anchor_w, occ_ctes + anchor_w, 1).replace(_OCC_FRAG_OLD, _OCC_FRAG_NEW, 1)
    sql = sql.replace(pp_block_old, _OCC_PP_NEW, 1).replace(anchor_p, plane_ctes + anchor_p, 1)
    return sql


# --- sprite occlusion (after frame_occlusion_view_sql) -----------------------
# Same rule for sprites, using occ_rows: a sprite's depth is one value per
# Thing, and a wall wins a tie against a sprite (surface priority), so a
# sprite column is cut at the top or bottom where a wall span of that column
# with rounded depth <= the sprite's covers its first or last row. Rows keep
# their screen y, so texture rows, the mask and fuzz cannot change.
# sprite_trim expands each on-screen Thing to its columns and hash-joins
# occ_rows on the column: a range join (Thing x wall span) was 2 ms slower
# per frame than the pixels it saved. Measured 2026-11-04 on 8 CU, prepared,
# best of 3, interleaved, on top of the wall occlusion:
#   E1M9 full, 44 poses: mean 181.4 -> 177.4 ms, p90 213.9 -> 201.5 ms,
#     median -2.3 ms; low 105.1 -> 103.1 ms, median -1.1 ms;
#   E1M1 full, 20 poses: 186.9 -> 184.0 ms; low 112.7 -> 111.5 ms.
# Byte-identical on all 128 frames. All-or-nothing: None on an unknown shape.
_SPR_YLO = "GREATEST(0, (floor(tb.y_top_f))::integer)"
_SPR_YHI = "LEAST((rs.screen_h - 1), ((ceil(tb.y_bottom_f))::integer - 1))"
_SPR_XLO = "GREATEST(0, (floor(tb.x_left_f))::integer)"
_SPR_XHI = "LEAST((rs.screen_w - 1), ((ceil(tb.x_right_f))::integer - 1))"
_SPR_FROM_OLD = "           FROM (((((((thing_bounds_lit tb\n"
_SPR_FROM_NEW = "           FROM ((((((((thing_bounds_lit tb\n"
_SPR_Y_OLD = f"             CROSS JOIN LATERAL generate_series({_SPR_YLO}, {_SPR_YHI}) screen_y(screen_y))"
_SPR_Y_NEW = ("             LEFT JOIN sprite_trim st ON ((st.thing_id = tb.thing_id) AND (st.col_x = screen_x.screen_x)))\n"
              f"             CROSS JOIN LATERAL generate_series(COALESCE(st.top_cover + 1, {_SPR_YLO}), COALESCE(st.bot_cover - 1, {_SPR_YHI})) screen_y(screen_y))")
_SPR_CTE = f"""
        ), sprite_trim AS MATERIALIZED (
         SELECT t.thing_id, o.col_x,
            max(o.y_end) FILTER (WHERE o.y_start <= t.y_lo AND o.y_end >= t.y_lo) AS top_cover,
            min(o.y_start) FILTER (WHERE o.y_start <= t.y_hi AND o.y_end >= t.y_hi) AS bot_cover
           FROM ((( SELECT tb.thing_id,
                    {_SPR_XLO} AS x_lo,
                    {_SPR_XHI} AS x_hi,
                    {_SPR_YLO} AS y_lo,
                    {_SPR_YHI} AS y_hi,
                    {_OCC_QD.format(d='tb.depth')} AS qd
                   FROM (thing_bounds_lit tb
                     CROSS JOIN render_settings rs)
                  WHERE ((tb.x_right_f > (0)::double precision) AND (tb.x_left_f < (rs.screen_w)::double precision) AND (tb.y_bottom_f > (0)::double precision) AND (tb.y_top_f < (rs.screen_h)::double precision))) t
             CROSS JOIN LATERAL generate_series(t.x_lo, t.x_hi) sx(x))
             JOIN occ_rows o ON (((o.col_x = sx.x) AND (o.qd <= t.qd) AND (((o.y_start <= t.y_lo) AND (o.y_end >= t.y_lo)) OR ((o.y_start <= t.y_hi) AND (o.y_end >= t.y_hi))))))
          GROUP BY t.thing_id, o.col_x"""


def frame_sprite_occlusion_view_sql(sql):
    """Indexed frame view body with occ_rows -> same frame, hidden sprite rows
    not generated. Returns None when the shape is not the expected one."""
    sql = sql.rstrip().rstrip(";")
    if "sprite_trim AS MATERIALIZED" in sql:              # already applied
        return sql
    if "occ_rows AS MATERIALIZED" not in sql:
        return None
    tp = _occ_cte_text(sql, "thing_pixels")
    anchor = "\n        ), thing_pixels AS ("
    if (not tp or tp.count(_SPR_FROM_OLD) != 1 or tp.count(_SPR_Y_OLD) != 1
            or sql.count(tp) != 1 or sql.count(anchor) != 1):
        return None
    tp_new = tp.replace(_SPR_FROM_OLD, _SPR_FROM_NEW, 1).replace(_SPR_Y_OLD, _SPR_Y_NEW, 1)
    return sql.replace(tp, tp_new, 1).replace(anchor, _SPR_CTE + anchor, 1)


# --- low-detail frame views (api_frame_idx_slotN_mM_low) --------------------
# Same renderer, every other screen column: each column generate_series (alias
# x(x), screen_x(screen_x) or sx(x); 7 in the indexed view) counts by 2 from
# an even start. Scene rows come out 160 wide, the status bar stays 320; the
# frame is 1 + 168*160 + 32*320 = 37121 bytes and the page doubles the scene
# columns. Byte-identical to the full frame's even columns (14 E1M1 poses).
# Do NOT filter with WHERE x % 2 = 0 instead: Postgres estimates that at 0.5%
# of the rows, turns panel_clips into a nested loop over 3.1M rows, and the
# low view gets 48% SLOWER than the full one (2026-10-22). With steps of 2 the
# row estimates stay those of the full view and frames are ~29% faster.
LOWDETAIL_X_ALIASES = (" x(x)", " screen_x(screen_x)", " sx(x)")


def _close_paren(s, i):
    depth = 0
    for j in range(i, len(s)):
        if s[j] == "(":
            depth += 1
        elif s[j] == ")":
            depth -= 1
            if depth == 0:
                return j
    raise ValueError("unbalanced parentheses")


def _split_top_level(s):
    parts, depth, cur = [], 0, ""
    for ch in s:
        depth += (ch == "(") - (ch == ")")
        if ch == "," and depth == 0:
            parts.append(cur)
            cur = ""
        else:
            cur += ch
    parts.append(cur)
    return parts


def lowdetail_view_sql(sql, expect=7):
    """Full-detail indexed frame view body -> low-detail body (see above)."""
    out, i, n = [], 0, 0
    while True:
        j = sql.find("generate_series(", i)
        if j < 0:
            out.append(sql[i:])
            break
        k = _close_paren(sql, j + len("generate_series"))
        args = _split_top_level(sql[j + len("generate_series("):k])
        if len(args) == 2 and any(sql.startswith(a, k + 1) for a in LOWDETAIL_X_ALIASES):
            lo, hi = args[0].strip(), args[1].strip()
            out.append(sql[i:j] + f"generate_series((({lo}) + (({lo}) & 1)), {hi}, 2)")
            n += 1
        else:
            out.append(sql[i:k + 1])
        i = k + 1
    if n != expect:
        raise ValueError(f"low-detail: {n} column series rewritten, expected {expect}")
    out = "".join(out)
    # The pickup / HUD message text (message_pixels) is drawn from font
    # patches, not from a column series: keep only its even columns, or a
    # message adds odd-x pixels and the frame is no longer 37121 bytes.
    msg_re = re.compile(r"(FROM message_pixels m\s+WHERE )")
    if len(msg_re.findall(out)) != 1:
        raise ValueError("low-detail: message_pixels filter anchor not found exactly once")
    return msg_re.sub(r"\1((m.x & 1) = 0) AND ", out)


# --------------------------------------------------------------------------
# Status-bar cache for the indexed frame views (pg_get_viewdef text in, as for
# lowdetail_view_sql). The status bar (rows 168..199, 10240 bytes) is drawn
# from ui_layers (digits, keys, weapons, face) over a static background with
# the frame's palette; it changes only when one of those does. hud_key is an
# md5 of exactly those inputs (palette + every ui_layers row). The frame takes
# the bar from hud_cache when the key matches and draws it itself otherwise,
# so a stale or missing cache row only costs the old price, never a wrong
# frame. The cache is written on the primary by the referee's HUD worker
# (doom_hud_slot<n>_m<map>); replicas read it like any table.
# Verified on 30 random HUD states, full and low detail: byte-identical
# frames on cache miss and hit; frame -10 ms (155 -> 146 ms at 1 CU).
# --------------------------------------------------------------------------
_HUD_UI_BRANCH = ("        UNION ALL\n         SELECT ui_colored.x,\n            ui_colored.y,\n"
                  "            ((ui_colored.y * 4096) + ui_colored.x) AS pix,\n            ui_colored.rgb\n"
                  "           FROM ui_colored\n        )")
_HUD_KEY_CTE = (", hud_key AS (\n         SELECT md5((SELECT (ap.pal)::text FROM active_palette ap) || '|' ||\n"
                "                COALESCE(string_agg(concat_ws(',', l.layer, l.patch, l.x, l.y), ';' "
                "ORDER BY l.layer, l.patch, l.x, l.y), '')) AS k\n           FROM ui_layers l\n        )")
_HUD_BAR = "(SELECT string_agg(u.rgb, '\\x'::bytea ORDER BY ((u.y * 4096) + u.x)) FROM ui_colored u)"
_HUD_GATE_RE = re.compile(r"WHERE \(EXISTS \( SELECT 1\s+FROM mp_players mp\s+WHERE \(\(mp\.map_id = (\d+)\) "
                          r"AND \(mp\.slot = (\d+)\) AND \(mp\.role_name = doom_caller\(\)\)\)\)\);?\s*$")


def hudcache_view_sql(vdef):
    """Indexed frame view definition -> (map_id, slot, frame_sql, hud_sql,
    hudkey_sql): the frame view with the cached status bar, and the two
    ungated views the HUD worker reads (key + bar, key only)."""
    cut = vdef.rfind("\n SELECT (( SELECT set_byte(")
    g = _HUD_GATE_RE.search(vdef[cut:]) if cut >= 0 else None
    if not g or vdef.count(_HUD_UI_BRANCH) != 1 or "hud_cache" in vdef:
        raise ValueError("status-bar cache: frame view shape not recognised")
    map_id, slot = int(g.group(1)), int(g.group(2))
    body = vdef[:cut]
    frame = (body.replace(_HUD_UI_BRANCH, "        )") + _HUD_KEY_CTE
             + "\n SELECT ((( SELECT set_byte('\\x00'::bytea, 0, (ap.pal)::integer) FROM active_palette ap)"
               " || string_agg(rgb, '\\x'::bytea ORDER BY pix))\n"
             + f"    || COALESCE((SELECT c.bar FROM hud_cache c WHERE c.map_id = {map_id} AND c.slot = {slot}"
               " AND c.key = (SELECT hk.k FROM hud_key hk)),\n"
             + f"                {_HUD_BAR})) AS frame_rgb\n   FROM framebuffer\n  "
             + g.group(0).rstrip().rstrip(";"))
    hud = body + _HUD_KEY_CTE + f"\n SELECT (SELECT hk.k FROM hud_key hk) AS key, {_HUD_BAR} AS bar"
    hudkey = body + _HUD_KEY_CTE + "\n SELECT hk.k AS key FROM hud_key hk"
    return map_id, slot, frame, hud, hudkey


def apply_targeted_fixes(sql):
    for fn, old, new, _why in TARGETED_FIXES:
        if re.search(rf"FUNCTION\s+{fn}\s*\(", sql, re.I):
            n = sql.count(old)
            if n != 1:
                if n == 0:
                    continue   # anchor not found: already applied or source changed
                raise TranspileError(f"targeted fix for {fn} expected 1 match, found {n}")
            sql = sql.replace(old, new)
    if _RENDERER_MARKER in sql and "panel_carry AS (" not in sql:
        # The indexed frame views (cedarscript_runtime.frame_view_body with
        # indexed=True) replace '\x000000'::bytea with '\x00'::bytea everywhere
        # in the renderer body, including inside the CedarDB optimizer-hack
        # branch.  Normalize the indexed variant back to the RGB one so the
        # hack-removal pattern in RENDERER_FIXES matches both shapes.
        sql = sql.replace(
            "  SELECT g AS x, 0 AS y, g AS pix, '\\x00'::bytea AS rgb\n"
            "  FROM generate_series(0, 255999) AS g WHERE g + 0 < 0\n",
            "  SELECT g AS x, 0 AS y, g AS pix, '\\x000000'::bytea AS rgb\n"
            "  FROM generate_series(0, 255999) AS g WHERE g + 0 < 0\n")
        for old, new in RENDERER_FIXES:
            n = sql.count(old)
            if n != 1:
                raise TranspileError(f"renderer fix expected 1 match, found {n}: {old[:40]!r}")
            sql = sql.replace(old, new)
    return sql


_JOIN_KW = {"join", "left", "right", "full", "inner", "cross", "natural"}
_CLAUSE_END = {"where", "returning", "group", "order", "limit", "window", "having"}


def rewrite_dml_target_joins(sql, report=None):
    """UPDATE t .. FROM a JOIN b ON (..t.x..)  /  DELETE FROM t .. USING a JOIN b ON (..t.x..)

    Postgres cannot see the DML target inside a JOIN's ON in FROM/USING; CedarDB can.
    For INNER joins the condition is moved to WHERE (ON TRUE left behind), which
    is equivalent. Outer joins referencing the target raise TranspileError.
    """
    if not re.search(r"\b(update|delete)\b", sql, re.I):
        return sql
    toks = tokenize(sql)
    out = [t.text for t in toks]
    sig = [i for i, t in enumerate(toks) if t.kind not in TRIVIA]
    S = [toks[i] for i in sig]
    depth, d = [], 0
    for t in S:
        if t.text == ")":
            d -= 1
        depth.append(d)
        if t.text == "(":
            d += 1
    N = len(S)

    def stop_at(n, d0, words):
        while n < N:
            if depth[n] < d0 or (depth[n] == d0 and (S[n].text in (";", "{", "}") or
                                                     (S[n].kind == "id" and S[n].low in words))):
                return n
            n += 1
        return N

    for n0 in range(N):
        t0 = S[n0]
        if t0.kind != "id" or t0.low not in ("update", "delete"):
            continue
        d0 = depth[n0]
        n = n0 + 1
        if t0.low == "delete":
            if n >= N or S[n].low != "from":
                continue
            n += 1
        if n < N and S[n].low == "only":
            n += 1
        if n >= N or S[n].kind not in ("id", "qid"):
            continue
        table = S[n].low
        n += 1
        while n + 1 < N and S[n].text == ".":
            table = S[n + 1].low
            n += 2
        if n < N and S[n].low == "as":
            n += 1
        alias = S[n].low if n < N and S[n].kind == "id" and S[n].low not in ("set", "using", "where") else table
        kw = "from" if t0.low == "update" else "using"
        f = stop_at(n, d0, {kw, "where", "returning"})
        if f >= N or S[f].low != kw:
            continue
        e = stop_at(f + 1, d0, _CLAUSE_END)
        moved = []
        m = f + 1
        while m < e:
            if depth[m] == d0 and S[m].low == "on":
                # join type: scan back to the JOIN keyword run
                k = m - 1
                while k > f and not (depth[k] == d0 and S[k].low == "join"):
                    k -= 1
                jt = set()
                kk = k - 1
                while kk > f and depth[kk] == d0 and S[kk].low in _JOIN_KW | {"outer"}:
                    jt.add(S[kk].low)
                    kk -= 1
                c_end = m + 1
                while c_end < e and not (depth[c_end] == d0 and (S[c_end].text == "," or S[c_end].low in _JOIN_KW)):
                    c_end += 1
                refs = any(S[q].low == alias and q + 1 < N and S[q + 1].text == "." for q in range(m + 1, c_end))
                if refs:
                    if jt & {"left", "right", "full"}:
                        raise TranspileError(f"outer JOIN references DML target {alias!r}")
                    a, b = sig[m + 1], sig[c_end - 1]
                    moved.append("".join(out[a:b + 1]).strip())
                    out[a] = "TRUE"
                    for q in range(a + 1, b + 1):
                        out[q] = ""
                m = c_end
                continue
            m += 1
        if not moved:
            continue
        conds = " AND ".join(f"({c})" for c in moved)
        if report is not None:
            report.append((t0.low, alias, len(moved)))
        if e < N and S[e].low == "where":
            w_end = stop_at(e + 1, d0, {"returning"})
            out[sig[e]] = f"WHERE {conds} AND ("
            if w_end < N:
                out[sig[w_end]] = ") " + out[sig[w_end]]
            else:
                out.append(")")
        else:
            if e < N:
                out[sig[e]] = f" WHERE {conds} " + out[sig[e]]
            else:
                out.append(f" WHERE {conds}")
    return "".join(out)


CALLER_RE = re.compile(r"\bsession_user::text\b")
# Tic functions: the one-row `params` CTE (the function's arguments) is read
# by several parts of a statement, so Postgres stores it, and the map and
# player ids no longer reach the index conditions (seq scans over every map's
# rows). NOT MATERIALIZED inlines it. From an external performance review, measured 2026-10-28
# on 8 CU, E1M1 Nightmare, 4 players, 28 monsters awake: tic mean 49.0 ->
# 41.6 ms, p90 65 -> 45 ms; game state identical (240 combat + 240 idle tics,
# 36 tables hashed every 10 tics). 15 functions.
PARAMS_CTE_RE = re.compile(r"\bparams AS \(")
# Empty slots: doom_server passes all 4 slots to every tic, seated or not, so
# a solo game ran the per-player stages (plan, use, move, death, secrets,
# weapon, sound, sector effects) 4 times, about 8 ms of a 37 ms E1M9 tic
# (8 CU). A slot whose player is neither seated nor alive has nothing to do
# there; doom_slot_active() (postgres_compat.sql) gates those stages. Kept
# for every slot: the clock (level_tics stays in step), the deathmatch-only
# world work (item respawn, the player the world sees, frags, respawns).
_TIC_SLOT_RE = re.compile(
    r"IF _cs\.(deathmatch|has3|has4) THEN (?!PERFORM doom_cs_clock\(|PERFORM doom_tic_dm_player\(|"
    r"PERFORM doom_cs_item_respawn\()(?=\w)")
_TIC_SLOT_ANCHOR = "has4 := doom_run_tic_core.p4 IS NOT NULL;"


def tic_core_slot_gates(sql):
    """doom_run_tic_core text -> same with per-player stages gated on
    doom_slot_active; None when the shape is not the expected one."""
    if "act2 boolean" in sql:
        return sql
    if sql.count(_TIC_SLOT_ANCHOR) != 1 or sql.count("<<_cs>>\nDECLARE\n") != 1:
        return None
    n = len(_TIC_SLOT_RE.findall(sql))
    if n != 30:                       # 10 per-player calls (plan x4) x 3 slots
        return None
    flag = {"deathmatch": "act2", "has3": "act3", "has4": "act4"}
    sql = _TIC_SLOT_RE.sub(lambda m: f"IF _cs.{flag[m.group(1)]} THEN ", sql)
    sql = sql.replace("<<_cs>>\nDECLARE\n", "<<_cs>>\nDECLARE\n  act2 boolean;\n  act3 boolean;\n  act4 boolean;\n", 1)
    return sql.replace(_TIC_SLOT_ANCHOR, _TIC_SLOT_ANCHOR + "\n"
        "act2 := _cs.deathmatch AND doom_slot_active(doom_run_tic_core.p_map_id, doom_run_tic_core.p2);\n"
        "act3 := _cs.has3 AND doom_slot_active(doom_run_tic_core.p_map_id, doom_run_tic_core.p3);\n"
        "act4 := _cs.has4 AND doom_slot_active(doom_run_tic_core.p_map_id, doom_run_tic_core.p4);", 1)


# --- tic statement fixes applied in place at referee start --------------------
# Same idea as tic_core_slot_gates: the stored functions come from the loader,
# so the referee rewrites them with these (old, new) pairs at every start.
# Each entry: (signature, marker that says it is applied, pairs). A function
# whose text does not contain each `old` exactly once is left alone.
# Measured with generic plans (plan_cache_mode = force_generic_plan on the
# tic), 8 CU, committed tics, statements timed in place. Every rewritten
# statement returned the same rows as the original on 40-60 forced states
# (909 door-use and 188 monster-crossing rows), and 16 tables hashed every 20
# tics were identical over the runs.
#   chase door use   E1M1 0.86 -> 0.33 ms (needs linedef_geom (map_id, special))
#   doors            E1M1 0.97 -> 0.34 ms, E1M9 2.11 -> 1.04 ms (in the statements)
#   player crossing  0.28 -> 0.10-0.16 ms
#   monster crossing E1M1 0.40 -> 0.33 ms, E1M9 0.95 -> 0.85 ms
_CHASE_OLD1 = """INSERT INTO line_special_events
  (map_id,player_thing_id,line_id,trigger_type,from_front)
SELECT DISTINCT doom_cs_monster_chase.p_map_id::int, ai.thing_id, ld.linedef_id, 'use', TRUE
FROM monster_ai ai
JOIN things t ON t.map_id = ai.map_id AND t.id = ai.thing_id
JOIN thing_combat_defs cd ON cd.thing_type = t.type
JOIN things pt ON pt.map_id = ai.map_id AND pt.id = doom_cs_monster_chase.p_player_thing_id::int
JOIN linedef_geom ld ON ld.map_id = ai.map_id
JOIN line_special_defs d ON d.special = ld.special AND d.monster_usable
CROSS JOIN LATERAL (
  SELECT SQRT(POWER(pt.x - t.x, 2) + POWER(pt.y - t.y, 2))::double precision AS dist
) toward
CROSS JOIN LATERAL (
  SELECT t.x + 8.0 * (pt.x - t.x) / NULLIF(toward.dist, 0) AS sx,
         t.y + 8.0 * (pt.y - t.y) / NULLIF(toward.dist, 0) AS sy
) step
"""
_CHASE_NEW1 = """-- Chasers and monster-usable lines first, then their pairs: the generic plan
-- of the one-join form tested every door line against every Thing on the map.
WITH chasers AS MATERIALIZED (
  SELECT ai.map_id, ai.thing_id, t.x, t.y, cd.radius, pt.x AS px, pt.y AS py
  FROM monster_ai ai
  JOIN things t ON t.map_id = ai.map_id AND t.id = ai.thing_id
  JOIN thing_combat_defs cd ON cd.thing_type = t.type
  JOIN things pt ON pt.map_id = ai.map_id AND pt.id = doom_cs_monster_chase.p_player_thing_id::int
  WHERE ai.map_id = doom_cs_monster_chase.p_map_id::int
    AND ai.state = 'see'
    AND NOT cd.explodes
),
door_lines AS MATERIALIZED (
  SELECT ld.map_id, ld.linedef_id, ld.x1, ld.y1, ld.x2, ld.y2, ld.left_sd_id
  FROM linedef_geom ld
  WHERE ld.map_id = doom_cs_monster_chase.p_map_id::int
    AND (ld.flags & 32) = 0
    AND ld.special = ANY (ARRAY(SELECT d.special FROM line_special_defs d WHERE d.monster_usable))
)
INSERT INTO line_special_events
  (map_id,player_thing_id,line_id,trigger_type,from_front)
SELECT DISTINCT doom_cs_monster_chase.p_map_id::int, t.thing_id, ld.linedef_id, 'use', TRUE
FROM chasers t
JOIN door_lines ld ON ld.map_id = t.map_id
CROSS JOIN LATERAL (
  SELECT SQRT(POWER(t.px - t.x, 2) + POWER(t.py - t.y, 2))::double precision AS dist
) toward
CROSS JOIN LATERAL (
  SELECT t.x + 8.0 * (t.px - t.x) / NULLIF(toward.dist, 0) AS sx,
         t.y + 8.0 * (t.py - t.y) / NULLIF(toward.dist, 0) AS sy
) step
"""
_CHASE_OLD2 = """WHERE ai.map_id = doom_cs_monster_chase.p_map_id::int
  AND ai.state = 'see'
  AND NOT cd.explodes
  AND (ld.flags & 32) = 0
  AND near.gap < cd.radius
"""
_CHASE_NEW2 = """WHERE near.gap < t.radius
"""
_CHASE_OLD3 = """      && box(point(t.x - cd.radius - 9.0, t.y - cd.radius - 9.0),
             point(t.x + cd.radius + 9.0, t.y + cd.radius + 9.0))
ON CONFLICT"""
_CHASE_NEW3 = """      && box(point(t.x - t.radius - 9.0, t.y - t.radius - 9.0),
             point(t.x + t.radius + 9.0, t.y + t.radius + 9.0))
ON CONFLICT"""
_DOORS_OLD1 = """
WITH
params AS NOT MATERIALIZED (
  SELECT t.map_id,t.x::float8 AS px,t.y::float8 AS py
  FROM things t
  WHERE t.map_id=doom_cs_doors.p_map_id::int AND t.id=doom_cs_doors.p_player_thing_id::int
),
player_sector AS ("""
_DOORS_NEW1 = """
-- Nothing below can change a row unless a mover is under way or moved last
-- tic: every statement joins a mover with direction <> 2 or moved_this_tick.
IF EXISTS (SELECT 1 FROM sector_movers WHERE map_id=doom_cs_doors.p_map_id
           AND (direction<>2 OR moved_this_tick)) THEN
WITH
params AS NOT MATERIALIZED (
  SELECT t.map_id,t.x::float8 AS px,t.y::float8 AS py
  FROM things t
  WHERE t.map_id=doom_cs_doors.p_map_id::int AND t.id=doom_cs_doors.p_player_thing_id::int
),
player_sector AS ("""
_DOORS_OLD2 = """RETURN;
END _cs;"""
_DOORS_NEW2 = """END IF;
RETURN;
END _cs;"""
_CROSS_OLD1 = """  JOIN vertexes v1 ON v1.map_id=ld.map_id AND v1.id=ld.v1_id
  JOIN vertexes v2 ON v2.map_id=ld.map_id AND v2.id=ld.v2_id
  WHERE ld.cross_activated
"""
_CROSS_NEW1 = """  -- One index probe per crossable line (a handful); a generic plan hashed
  -- every vertex of the map twice instead. OFFSET 0 keeps the probes.
  CROSS JOIN LATERAL (SELECT v.x, v.y FROM vertexes v
                      WHERE v.map_id=ld.map_id AND v.id=ld.v1_id OFFSET 0) v1
  CROSS JOIN LATERAL (SELECT v.x, v.y FROM vertexes v
                      WHERE v.map_id=ld.map_id AND v.id=ld.v2_id OFFSET 0) v2
  WHERE ld.cross_activated
"""
_MCROSS_OLD1 = """-- monster-crossable walk-over lines
--  a monster trips only the teleports, the down-wait-up lifts and the plain raise-door, and nothing else.
INSERT INTO line_special_events
"""
_MCROSS_NEW1 = """-- monster-crossable walk-over lines
--  a monster trips only the teleports, the down-wait-up lifts and the plain raise-door, and nothing else.
-- The map's crossable lines with their vertices, once (a handful of index
-- probes); a generic plan hashed every vertex of the map twice instead.
WITH crossable AS MATERIALIZED (
  SELECT ld.map_id, ld.id, ld.cross_once,
         v1.x AS v1x, v1.y AS v1y, v2.x AS v2x, v2.y AS v2y
  FROM linedefs ld
  CROSS JOIN LATERAL (SELECT v.x, v.y FROM vertexes v
                      WHERE v.map_id=ld.map_id AND v.id=ld.v1_id OFFSET 0) v1
  CROSS JOIN LATERAL (SELECT v.x, v.y FROM vertexes v
                      WHERE v.map_id=ld.map_id AND v.id=ld.v2_id OFFSET 0) v2
  WHERE ld.map_id = doom_cs_monster_move.p_map_id AND ld.monster_crossable
)
INSERT INTO line_special_events
"""
_MCROSS_OLD2 = """    JOIN linedefs ld ON ld.map_id = ms.map_id AND ld.monster_crossable
    JOIN vertexes v1 ON v1.map_id=ld.map_id AND v1.id=ld.v1_id
    JOIN vertexes v2 ON v2.map_id=ld.map_id AND v2.id=ld.v2_id
"""
_MCROSS_NEW2 = """    JOIN crossable ld ON ld.map_id = ms.map_id
    CROSS JOIN LATERAL (SELECT ld.v1x AS x, ld.v1y AS y) v1
    CROSS JOIN LATERAL (SELECT ld.v2x AS x, ld.v2y AS y) v2
"""
LIVE_TIC_FIXES = [
    ('doom_cs_monster_chase(integer,integer)', 'WITH chasers AS MATERIALIZED',
     [(_CHASE_OLD1, _CHASE_NEW1), (_CHASE_OLD2, _CHASE_NEW2), (_CHASE_OLD3, _CHASE_NEW3)]),
    ('doom_cs_doors(integer,integer)', 'IF EXISTS (SELECT 1 FROM sector_movers WHERE map_id=doom_cs_doors.p_map_id',
     [(_DOORS_OLD1, _DOORS_NEW1), (_DOORS_OLD2, _DOORS_NEW2)]),
    ('doom_cs_cross(integer,integer)', 'One index probe per crossable line',
     [(_CROSS_OLD1, _CROSS_NEW1)]),
    ('doom_cs_monster_move(integer,integer)', 'WITH crossable AS MATERIALIZED',
     [(_MCROSS_OLD1, _MCROSS_NEW1), (_MCROSS_OLD2, _MCROSS_NEW2)]),
]

# Monster plan flags in one pass over monster_ai (seven EXISTS before), and
# the pre-think call, which only reads the noise bit, asks for that bit alone:
# E1M1 0.85 -> 0.25 ms, E1M9 0.96 -> 0.37 ms (250 random states, same flags).
# Sound: firing monsters, uncued sights and deaths, and the active-sound draw
# filtered before the sound pick: E1M1 1.31 -> 0.86 ms, E1M9 2.01 -> 1.28 ms
# (350 random states, 2,467 events of every kind, same rows).
_PLAN_OLD1 = """SELECT
  EXISTS (SELECT 1 FROM player_weapons pw
          WHERE pw.map_id=doom_cs_monster_plan.p_map_id AND pw.fired_this_tick) AS noise_due,
  EXISTS (
    SELECT 1 FROM monster_ai ai
    JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
    JOIN thing_ai_frames f ON f.thing_type=t.type AND f.state='see'
      AND f.seq_index=ai.seq_index
    JOIN thing_combat_defs cd ON cd.thing_type=t.type AND NOT cd.explodes
    WHERE ai.map_id=doom_cs_monster_plan.p_map_id AND ai.state='see'
      AND (ai.state_tics=f.tics OR ai.state_tics=FLOOR(f.tics/2.0)::int)
  ) AS stepping_due,
  EXISTS (
    SELECT 1 FROM monster_ai ai
    JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
    JOIN thing_combat_defs d ON d.thing_type=t.type
    WHERE ai.map_id=doom_cs_monster_plan.p_map_id AND d.floats AND ai.state IN ('see','missile')
  ) AS floater_due,
  EXISTS (SELECT 1 FROM monster_ai
          WHERE map_id=doom_cs_monster_plan.p_map_id AND state='see') AS chasing_due,
  EXISTS (SELECT 1 FROM monster_ai
          WHERE map_id=doom_cs_monster_plan.p_map_id AND fired_this_tick) AS attacking_due,
  EXISTS (
    SELECT 1 FROM monster_ai ai
    JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
    JOIN thing_combat_defs cd ON cd.thing_type=t.type AND cd.explodes
    WHERE ai.map_id=doom_cs_monster_plan.p_map_id AND ai.fired_this_tick
  ) AS barrel_due,
  EXISTS (SELECT 1 FROM projectile_impacts
          WHERE map_id=doom_cs_monster_plan.p_map_id AND projectile_type='rocket') AS rocket_due"""
_PLAN_NEW1 = """SELECT
  EXISTS (SELECT 1 FROM player_weapons pw
          WHERE pw.map_id=doom_cs_monster_plan.p_map_id AND pw.fired_this_tick) AS noise_due,
  COALESCE(bool_or(ai.state='see' AND f.seq_index IS NOT NULL AND cd.thing_type IS NOT NULL AND NOT cd.explodes
                   AND (ai.state_tics=f.tics OR ai.state_tics=FLOOR(f.tics/2.0)::int)), FALSE) AS stepping_due,
  COALESCE(bool_or(ai.state IN ('see','missile') AND cd.floats), FALSE) AS floater_due,
  COALESCE(bool_or(ai.state='see'), FALSE) AS chasing_due,
  COALESCE(bool_or(ai.fired_this_tick), FALSE) AS attacking_due,
  COALESCE(bool_or(ai.fired_this_tick AND cd.explodes), FALSE) AS barrel_due,
  EXISTS (SELECT 1 FROM projectile_impacts
          WHERE map_id=doom_cs_monster_plan.p_map_id AND projectile_type='rocket') AS rocket_due
FROM monster_ai ai
LEFT JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
LEFT JOIN thing_combat_defs cd ON cd.thing_type=t.type
LEFT JOIN thing_ai_frames f ON f.thing_type=t.type AND f.state='see' AND f.seq_index=ai.seq_index
WHERE ai.map_id=doom_cs_monster_plan.p_map_id"""
_MONSTERS_OLD1 = """pre := doom_cs_monster_plan(doom_cs_monsters.p_map_id);
"""
_MONSTERS_NEW1 = """-- Only the noise bit of the plan is read before think: ask for it alone.
pre := CASE WHEN EXISTS (SELECT 1 FROM player_weapons pw WHERE pw.map_id=doom_cs_monsters.p_map_id
                         AND pw.fired_this_tick) THEN 1 ELSE 0 END;
"""
_SOUND_OLD1 = """  FROM world_pos p JOIN monster_ai ai ON ai.map_id=p.map_id
  JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
  JOIN thing_combat_defs d ON d.thing_type=t.type
  WHERE ai.fired_this_tick
"""
_SOUND_NEW1 = """  -- Firing monsters first (a few), not every Thing of the map.
  FROM world_pos p JOIN (SELECT ai0.* FROM monster_ai ai0
                         WHERE ai0.map_id=doom_cs_sound.p_map_id::int AND ai0.fired_this_tick
                         OFFSET 0) ai ON ai.map_id=p.map_id
  JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
  JOIN thing_combat_defs d ON d.thing_type=t.type
"""
_SOUND_OLD2 = """  FROM world_pos p
  JOIN monster_ai ai ON ai.map_id=p.map_id AND ai.state <> 'stand'
"""
_SOUND_NEW2 = """  -- Only monsters whose sight cue is not out yet: the same key test as the
  -- final NOT EXISTS, before the sound pick, not after.
  FROM world_pos p
  JOIN (SELECT ai0.* FROM monster_ai ai0
        WHERE ai0.map_id=doom_cs_sound.p_map_id::int AND ai0.state <> 'stand'
          AND NOT EXISTS (SELECT 1 FROM sound_events s0 WHERE s0.map_id=ai0.map_id
                          AND s0.event_key='mon-sight:'||ai0.thing_id::text)
        OFFSET 0) ai ON ai.map_id=p.map_id
"""
_SOUND_OLD3 = """  FROM world_pos p
  JOIN monster_ai ai ON ai.map_id=p.map_id
  JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
  JOIN thing_health h ON h.map_id=ai.map_id AND h.thing_id=ai.thing_id
   AND NOT h.alive
"""
_SOUND_NEW3 = """  -- Only monsters whose death cue is not out yet (same key test as below).
  FROM world_pos p
  JOIN (SELECT ai0.* FROM monster_ai ai0
        JOIN thing_health h0 ON h0.map_id=ai0.map_id AND h0.thing_id=ai0.thing_id AND NOT h0.alive
        WHERE ai0.map_id=doom_cs_sound.p_map_id::int
          AND NOT EXISTS (SELECT 1 FROM sound_events s0 WHERE s0.map_id=ai0.map_id
                          AND s0.event_key='mon-death:'||ai0.thing_id::text)
        OFFSET 0) ai ON ai.map_id=p.map_id
  JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
  JOIN thing_health h ON h.map_id=ai.map_id AND h.thing_id=ai.thing_id
   AND NOT h.alive
"""
_SOUND_OLD4 = """  FROM world_pos p
  JOIN monster_ai ai ON ai.map_id=p.map_id AND ai.state='see'
  JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
  JOIN thing_health h ON h.map_id=ai.map_id AND h.thing_id=ai.thing_id
   AND h.alive
  JOIN sound_pick sp ON sp.thing_type=t.type AND sp.cue='active'
   AND sp.variant = doom_prandom(ai.thing_id, 0, 60) % sp.n
  WHERE (doom_prandom(ai.thing_id, p.level_tic, 61) * 256
         + doom_prandom(ai.thing_id, p.level_tic, 62)) % _cs.active_sound_odds = 0
"""
_SOUND_NEW4 = """  -- The 1-in-ACTIVE_SOUND_ODDS draw first, per chaser, then the rest.
  FROM world_pos p
  CROSS JOIN LATERAL (SELECT ai0.* FROM monster_ai ai0
        WHERE ai0.map_id=p.map_id AND ai0.state='see'
          AND (doom_prandom(ai0.thing_id, p.level_tic, 61) * 256
               + doom_prandom(ai0.thing_id, p.level_tic, 62)) % _cs.active_sound_odds = 0
        OFFSET 0) ai
  JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
  JOIN thing_health h ON h.map_id=ai.map_id AND h.thing_id=ai.thing_id
   AND h.alive
  JOIN sound_pick sp ON sp.thing_type=t.type AND sp.cue='active'
   AND sp.variant = doom_prandom(ai.thing_id, 0, 60) % sp.n
"""
LIVE_TIC_FIXES += [
    ('doom_cs_monster_plan(integer)', "COALESCE(bool_or(ai.state='see' AND f.seq_index",
     [(_PLAN_OLD1, _PLAN_NEW1)]),
    ('doom_cs_monsters(integer,integer)', 'Only the noise bit of the plan',
     [(_MONSTERS_OLD1, _MONSTERS_NEW1)]),
    ('doom_cs_sound(integer,integer)', 'Firing monsters first',
     [(_SOUND_OLD1, _SOUND_NEW1), (_SOUND_OLD2, _SOUND_NEW2), (_SOUND_OLD3, _SOUND_NEW3), (_SOUND_OLD4, _SOUND_NEW4)]),
]


def live_tic_fix(ddl, marker, pairs):
    """Apply one LIVE_TIC_FIXES entry to a stored function's DDL (pg_get_functiondef).
    Returns the DDL unchanged when already applied, None when its text differs."""
    if marker in ddl:
        return ddl
    for old, new in pairs:
        if ddl.count(old) != 1:
            return None
        ddl = ddl.replace(old, new)
    return ddl


FUNCTION_DDL_RE = re.compile(r"\bCREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\b", re.I)
PUBLIC_SCHEMA_RE = re.compile(r"\b((?:\w+\.)?(?:table_schema|schemaname|nspname))\s*=\s*'public'", re.I)


def postgres_rewrites(sql, columns=frozenset(), report=None):
    """All CedarDB->Postgres SQL dialect rewrites (not cedarscript)."""
    sql = PUBLIC_SCHEMA_RE.sub(r"\1 = current_schema()", sql)
    # The player API resolves the caller by session_user; the app names the
    # player per browser tab instead (doom_caller(), postgres_compat.sql).
    sql = CALLER_RE.sub("doom_caller()", sql)
    sql = apply_targeted_fixes(sql)
    if FUNCTION_DDL_RE.search(sql):
        sql = PARAMS_CTE_RE.sub("params AS NOT MATERIALIZED (", sql)
    return apply_renderer_post_fixes(rewrite_dollar_bodies(
        sql,
        lambda x: rewrite_dml_target_joins(
            rewrite_arg_max(inline_lateral_aliases(x, report, columns), packed=True), report),
        lambda x: rewrite_dml_target_joins(
            rewrite_arg_max(inline_lateral_aliases(x, report, columns), packed=False), report)), report)


# --------------------------------------------------------------------------
# Cursor shim: lets the unmodified SQLDoom Python install code run on Postgres
# --------------------------------------------------------------------------
CEDAR_ONLY_SETTINGS = re.compile(r"^\s*SET\s+(debug\.|optimizer\.)", re.I)


_COLUMNS_SQL = ("SELECT DISTINCT column_name FROM information_schema.columns "
                "WHERE table_schema = current_schema()")


class ShimCursor:
    """Wraps a DB-API cursor. On execute(): CedarDB dialect rewrites (ARG_MAX,
    lateral column aliases -- guarded by real column names, which win), then
    cedarscript -> PL/pgSQL, and CedarDB-only SET statements are dropped."""

    def __init__(self, cur, transpiler):
        self._cur, self._t = cur, transpiler

    def _columns(self):
        # Real table columns take precedence over select-list aliases. Re-read
        # while the schema is still being created.
        cached = getattr(self._t, "_columns", None)
        if cached:
            return cached
        self._cur.execute(_COLUMNS_SQL)
        cols = frozenset(r[0].lower() for r in self._cur.fetchall())
        if len(cols) > 50:
            self._t._columns = cols
        return cols

    def execute(self, sql, *args, **kw):
        if isinstance(sql, str):
            if CEDAR_ONLY_SETTINGS.match(sql):
                return None
            if (re.search(r"\barg_max\s*\(|\bselect\b|\bupdate\b|\bdelete\b", sql, re.I)
                    and not re.match(r"\s*(INSERT|COPY)\b", sql, re.I)):
                sql = postgres_rewrites(sql, columns=self._columns())
            if re.search(r"LANGUAGE\s+cedarscript", sql, re.I):
                sql = self._t.transpile_sql(sql)
            enum = re.match(r"\s*CREATE\s+TYPE\s+([\w.]+)\s+AS\s+ENUM\b", sql, re.I)
            if enum:
                res = self._cur.execute(sql, *args, **kw)
                # CedarDB assigns text to enums implicitly; Postgres needs a cast.
                self._cur.execute(f"CREATE CAST (text AS {enum.group(1)}) WITH INOUT AS ASSIGNMENT")
                return res
        return self._cur.execute(sql, *args, **kw)

    def __getattr__(self, k):
        return getattr(self._cur, k)

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return self._cur.__exit__(*a)

    def __iter__(self):
        return iter(self._cur)
