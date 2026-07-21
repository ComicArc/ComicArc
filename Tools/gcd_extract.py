# Builds the offline comics reference database ComicArc downloads once during setup
# (see Services/OfflineMetadataStore.swift). Source: the Grand Comics Database public
# data dump (CC BY-SA 4.0 — https://creativecommons.org/licenses/by-sa/4.0/), downloadable
# with no account/registration from https://archive.org/details/gcd-YYYY-MM-DD (search for
# the latest snapshot there, or use https://www.comics.org/download/ for a current dump,
# which requires a free GCD account).
#
# Usage:
#   python3 gcd_extract.py <path-to-dump.sql>
# Produces gcd_lookup.sqlite in the current directory (~90s for a ~1.6GB dump). Upload the
# result to GitHub Releases (or wherever GCDDatabaseDownloader.hostedURL points) and update
# that constant. Ship credit for "Grand Comics Database" somewhere in the app per the license
# (already added to Settings > About).
import re
import sqlite3
import sys
import time

DUMP_PATH = sys.argv[1] if len(sys.argv) > 1 else "2021-05-29.sql"
OUT_PATH = "gcd_lookup.sqlite"

_YEAR_PAREN = re.compile(r"\s*\((?:19|20)\d{2}(?:-(?:19|20)?\d{2,4})?\)\s*$")
_VOL_SUFFIX = re.compile(r"\s*,?\s*vol(?:ume)?\.?\s*\d+\s*$", re.IGNORECASE)
_NON_ALNUM = re.compile(r"[^a-z0-9 ]")
_WS = re.compile(r"\s+")


def normalize_series_name(name):
    """Must exactly mirror ReadingOrderMatcher.normalizeSeriesName in Swift."""
    s = name.strip()
    s = _YEAR_PAREN.sub("", s)
    s = _VOL_SUFFIX.sub("", s)
    s = s.lower()
    if s.startswith("the "):
        s = s[4:]
    s = _NON_ALNUM.sub(" ", s)
    s = _WS.sub(" ", s).strip()
    return s

ESCAPES = {'n': '\n', 'r': '\r', 't': '\t', '0': '\0', '\\': '\\',
           "'": "'", '"': '"', 'Z': '\x1a', 'b': '\b'}


def parse_tuple(s, i):
    assert s[i] == '('
    i += 1
    n = len(s)
    vals = []
    while True:
        while s[i] in ' \t\n\r':
            i += 1
        if s[i] == "'":
            i += 1
            buf = []
            while True:
                c = s[i]
                if c == '\\':
                    nxt = s[i + 1]
                    buf.append(ESCAPES.get(nxt, nxt))
                    i += 2
                    continue
                if c == "'":
                    if i + 1 < n and s[i + 1] == "'":
                        buf.append("'")
                        i += 2
                        continue
                    i += 1
                    break
                buf.append(c)
                i += 1
            vals.append(''.join(buf))
        elif s[i:i + 4] == 'NULL':
            vals.append(None)
            i += 4
        else:
            j = i
            while s[j] not in ',)':
                j += 1
            vals.append(s[i:j])
            i = j
        while s[i] in ' \t\n\r':
            i += 1
        if s[i] == ',':
            i += 1
            continue
        elif s[i] == ')':
            i += 1
            break
    return tuple(vals), i


def parse_insert_line(line, prefix):
    i = len(prefix)
    n = len(line)
    rows = []
    while i < n:
        while line[i] in ' \t\n\r':
            i += 1
        if line[i] != '(':
            break
        tup, i = parse_tuple(line, i)
        rows.append(tup)
        while i < n and line[i] in ' \t\n\r':
            i += 1
        if i < n and line[i] == ',':
            i += 1
            continue
        else:
            break
    return rows


def to_int(v):
    if v is None:
        return None
    try:
        return int(v)
    except ValueError:
        return None


def main():
    t0 = time.time()
    conn = sqlite3.connect(OUT_PATH)
    c = conn.cursor()
    c.executescript("""
        DROP TABLE IF EXISTS series;
        DROP TABLE IF EXISTS issue;
        DROP TABLE IF EXISTS publisher;
        DROP TABLE IF EXISTS series_bond;
        DROP TABLE IF EXISTS series_bond_type;
        CREATE TABLE series (
            id INTEGER PRIMARY KEY, name TEXT, sort_name TEXT,
            year_began INTEGER, year_ended INTEGER, publisher_id INTEGER,
            issue_count INTEGER, deleted INTEGER, norm_name TEXT
        );
        CREATE TABLE issue (
            id INTEGER PRIMARY KEY, series_id INTEGER, number TEXT,
            key_date TEXT, sort_code INTEGER, title TEXT,
            variant_of_id INTEGER, deleted INTEGER
        );
        CREATE TABLE publisher (
            id INTEGER PRIMARY KEY, name TEXT, deleted INTEGER
        );
        CREATE TABLE series_bond (
            id INTEGER PRIMARY KEY, origin_id INTEGER, target_id INTEGER,
            origin_issue_id INTEGER, target_issue_id INTEGER, bond_type_id INTEGER
        );
        CREATE TABLE series_bond_type (
            id INTEGER PRIMARY KEY, name TEXT
        );
    """)
    conn.commit()

    counts = {"series": 0, "issue": 0, "publisher": 0, "series_bond": 0, "series_bond_type": 0}

    prefixes = {
        "gcd_series`": ("gcd_series", "series"),
        "gcd_issue`": ("gcd_issue", "issue"),
        "gcd_publisher`": ("gcd_publisher", "publisher"),
        "gcd_series_bond`": ("gcd_series_bond", "series_bond"),
        "gcd_series_bond_type`": ("gcd_series_bond_type", "series_bond_type"),
    }

    with open(DUMP_PATH, "r", encoding="utf-8", errors="replace") as f:
        lineno = 0
        for line in f:
            lineno += 1
            if not line.startswith("INSERT INTO"):
                continue
            # Disambiguate gcd_series` vs gcd_series_bond`/gcd_series_bond_type` by exact match
            matched = None
            for key, (tbl, dest) in prefixes.items():
                marker = f"INSERT INTO `{tbl}` VALUES"
                if line.startswith(marker):
                    matched = (tbl, dest, marker)
                    break
            if not matched:
                continue
            tbl, dest, marker = matched
            rows = parse_insert_line(line, marker)

            if dest == "series":
                batch = [(to_int(r[0]), r[1], r[2], to_int(r[4]), to_int(r[6]),
                          to_int(r[12]), to_int(r[18]), to_int(r[21]), normalize_series_name(r[1] or ""))
                         for r in rows]
                c.executemany("INSERT OR REPLACE INTO series VALUES (?,?,?,?,?,?,?,?,?)", batch)
            elif dest == "issue":
                batch = [(to_int(r[0]), to_int(r[5]), r[1], r[11], to_int(r[12]),
                          r[32], to_int(r[28]), to_int(r[23]))
                         for r in rows]
                c.executemany("INSERT OR REPLACE INTO issue VALUES (?,?,?,?,?,?,?,?)", batch)
            elif dest == "publisher":
                batch = [(to_int(r[0]), r[1], to_int(r[13])) for r in rows]
                c.executemany("INSERT OR REPLACE INTO publisher VALUES (?,?,?)", batch)
            elif dest == "series_bond":
                batch = [(to_int(r[0]), to_int(r[1]), to_int(r[2]),
                          to_int(r[3]), to_int(r[4]), to_int(r[5]))
                         for r in rows]
                c.executemany("INSERT OR REPLACE INTO series_bond VALUES (?,?,?,?,?,?)", batch)
            elif dest == "series_bond_type":
                batch = [(to_int(r[0]), r[1]) for r in rows]
                c.executemany("INSERT OR REPLACE INTO series_bond_type VALUES (?,?)", batch)

            counts[dest] += len(rows)
            print(f"[{time.time()-t0:6.1f}s] line {lineno}: {dest} +{len(rows)} (total {counts[dest]})", flush=True)
            conn.commit()

    print("Creating indexes...", flush=True)
    c.executescript("""
        CREATE INDEX idx_issue_series ON issue(series_id);
        CREATE INDEX idx_series_name ON series(sort_name);
        CREATE INDEX idx_series_norm_name ON series(norm_name);
        CREATE INDEX idx_bond_origin ON series_bond(origin_id);
        CREATE INDEX idx_bond_target ON series_bond(target_id);
    """)
    conn.commit()
    conn.close()
    print(f"Done in {time.time()-t0:.1f}s. Counts: {counts}", flush=True)


if __name__ == "__main__":
    main()
