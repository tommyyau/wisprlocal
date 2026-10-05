#!/usr/bin/env python3
"""Score hyps against Fixtures/manifest.json (or a --my-voice transcripts file).

Normalisation (applied to ref and hyp identically): emails spelled out (". -> dot", "@ -> at"),
"$N" -> "N dollars", "%" -> " percent", times "7:30" -> "seven thirty", ordinals/integers/decimals to words,
"-" and "/" -> space, then lowercase and strip all other punctuation, collapse whitespace.
A few spelling equivalences are folded (licence/license, okay/ok) so they don't count as errors.

Usage:
  score.py wer   results/raw/hyps_<m>.jsonl [...]          -> per-condition WER + jargon accuracy table
  score.py vocab results/raw/vocab_<m>.jsonl [...]         -> biasing table
  score.py myvoice <transcripts.txt> results/raw/myvoice_<m>.jsonl [...]
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ONES = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()
ORD = {"one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth", "nine": "ninth", "twelve": "twelfth"}


def n2w(n):
    n = int(n)
    if n < 20: return ONES[n]
    if n < 100: return TENS[n // 10] + ("" if n % 10 == 0 else " " + ONES[n % 10])
    if n < 1000: return ONES[n // 100] + " hundred" + ("" if n % 100 == 0 else " " + n2w(n % 100))
    if n < 1_000_000: return n2w(n // 1000) + " thousand" + ("" if n % 1000 == 0 else " " + n2w(n % 1000))
    return " ".join(ONES[int(d)] for d in str(n))


def ordinal(n):
    w = n2w(n).split()
    last = w[-1]
    if last in ORD: w[-1] = ORD[last]
    elif last.endswith("y"): w[-1] = last[:-1] + "ieth"
    else: w[-1] = last + "th"
    return " ".join(w)


def norm(s):
    s = s.replace("’", "'")
    s = re.sub(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+",
               lambda m: " " + m.group(0).replace("@", " at ").replace(".", " dot ") + " ", s)
    # model-style partial emails ("alex at example.com"): dots between letters -> " dot "
    s = re.sub(r"(?<=[A-Za-z])\.(?=[A-Za-z])", " dot ", s)
    # British-style clock times "7.30" == "7:30" (only :00/:15/:30/:45 so version numbers like 1.31 stay decimals)
    s = re.sub(r"\b(\d{1,2})\.(00|15|30|45)\b", r"\1:\2", s)
    s = re.sub(r"\$(\d+)", r"\1 dollars", s)
    s = s.replace("%", " percent")
    s = re.sub(r"\b(\d{1,2}):(\d{2})\b", lambda m: n2w(m.group(1)) + ("" if m.group(2) == "00" else " " + n2w(m.group(2))), s)
    s = re.sub(r"\b(\d+)(st|nd|rd|th)\b", lambda m: ordinal(m.group(1)), s)
    s = re.sub(r"\b(\d+)\.(\d+)\b", lambda m: n2w(m.group(1)) + " point " + " ".join(n2w(d) for d in m.group(2)), s)
    s = re.sub(r"\b\d+\b", lambda m: n2w(m.group(0)), s)
    s = s.lower().replace("-", " ").replace("/", " ")
    s = re.sub(r"[^\w\s']", "", s).replace("'", "")
    w = s.split()
    fold = {"license": "licence", "ok": "okay", "a hundred": "one hundred"}
    s = " ".join(w)
    for a, b in fold.items():
        s = re.sub(rf"\b{a}\b", b, s)
    s = re.sub(r"\ba hundred\b", "one hundred", s)
    return s.split()


def align(r, h):
    """Levenshtein with backtrace -> (S, D, I, ops)."""
    n, m = len(r), len(h)
    d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1): d[i][0] = i
    for j in range(m + 1): d[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (r[i - 1] != h[j - 1]))
    i, j, ops = n, m, []
    while i > 0 or j > 0:
        if i > 0 and j > 0 and d[i][j] == d[i - 1][j - 1] + (r[i - 1] != h[j - 1]):
            ops.append(("C" if r[i - 1] == h[j - 1] else "S", r[i - 1], h[j - 1])); i -= 1; j -= 1
        elif i > 0 and d[i][j] == d[i - 1][j] + 1:
            ops.append(("D", r[i - 1], None)); i -= 1
        else:
            ops.append(("I", None, h[j - 1])); j -= 1
    ops.reverse()
    S = sum(o[0] == "S" for o in ops); D = sum(o[0] == "D" for o in ops); I = sum(o[0] == "I" for o in ops)
    return S, D, I, ops


def contains(words, term):
    t = norm(term)
    return any(words[k:k + len(t)] == t for k in range(len(words) - len(t) + 1))


def load_jsonl(p):
    return [json.loads(l) for l in open(p) if l.strip()]


def manifest():
    return {m["id"]: m for m in json.load(open(os.path.join(ROOT, "Fixtures", "manifest.json")))}


def wer_table(paths):
    man = manifest()
    groups = [("clean (S1 + 22 utt)", lambda m: m["cond"] == "clean" and m["set"] in ("s1", "utt")),
              ("clean utt only (22)", lambda m: m["cond"] == "clean" and m["set"] == "utt"),
              ("tv -10 dB", lambda m: m["cond"] == "tv10"), ("tv -6 dB", lambda m: m["cond"] == "tv6"),
              ("music -10 dB", lambda m: m["cond"] == "music10"), ("long 3.4 min", lambda m: m["set"] == "long")]
    res = {}
    for p in paths:
        hy = load_jsonl(p)
        model = hy[0]["model"]
        row = {}
        for gname, pred in groups:
            E = N = 0; jh = jt = 0
            for h in hy:
                m = man[h["id"]]
                if not pred(m): continue
                r, w = norm(m["ref"]), norm(h["hyp"])
                S, D, I, _ = align(r, w); E += S + D + I; N += len(r)
                for t in m["jargon"]:
                    jt += 1; jh += contains(w, t)
            row[gname] = (100.0 * E / max(N, 1), jh, jt)
        # duplicated adjacent words in long clip (FluidAudio #954)
        for h in hy:
            if man[h["id"]]["set"] == "long":
                w = norm(h["hyp"]); rw = norm(man[h["id"]]["ref"])
                dup = sum(1 for k in range(1, len(w)) if w[k] == w[k - 1])
                rdup = sum(1 for k in range(1, len(rw)) if rw[k] == rw[k - 1])
                row["long_dups"] = (dup, rdup)
        res[model] = row
    print("| Condition | " + " | ".join(f"{m} WER" for m in res) + " | " + " | ".join(f"{m} jargon" for m in res) + " |")
    print("|---" * (1 + 2 * len(res)) + "|")
    for gname, _ in groups:
        print(f"| {gname} | " + " | ".join(f"{res[m][gname][0]:.2f} %" for m in res) + " | "
              + " | ".join(f"{res[m][gname][1]}/{res[m][gname][2]}" for m in res) + " |")
    for m in res:
        if "long_dups" in res[m]:
            print(f"long-form adjacent duplicate words ({m}): hyp={res[m]['long_dups'][0]} ref={res[m]['long_dups'][1]}")
    # per-term accuracy, all conditions
    terms = {}
    for p in paths:
        hy = load_jsonl(p); model = hy[0]["model"]
        for h in hy:
            m = man[h["id"]]
            w = norm(h["hyp"])
            for t in m["jargon"]:
                terms.setdefault(t, {}).setdefault(model, [0, 0])
                terms[t][model][0] += contains(w, t); terms[t][model][1] += 1
    print("\n| Term (all conditions) | " + " | ".join(res) + " |")
    print("|---" * (1 + len(res)) + "|")
    for t in sorted(terms):
        print(f"| {t} | " + " | ".join(f"{terms[t].get(m, [0, 0])[0]}/{terms[t].get(m, [0, 0])[1]}" for m in res) + " |")


def vocab_table(paths):
    man = manifest()
    target = ["Wispr Flow", "Tailscale", "Kubernetes", "Grafana"]
    print("| Model | Config | WER base -> boosted | target-term hits base -> boosted | deleted/changed non-target words | median extra ms |")
    print("|---|---|---|---|---|---|")
    examples = []
    neutral_rows = []
    for p in paths:
        rows = load_jsonl(p)
        model = rows[0]["model"]
        neutral = [r for r in rows if not any(t in target for t in man[r["id"]]["jargon"])]
        rows = [r for r in rows if any(t in target for t in man[r["id"]]["jargon"])]
        for cfg in ("default", "norescue", "norescue_sim070"):
            changed = sum(1 for r in neutral if r[cfg] != r["base"])
            En = Nn = 0
            for r in neutral:
                ref = norm(man[r["id"]]["ref"]); S, D, I, _ = align(ref, norm(r[cfg])); En += S + D + I; Nn += len(ref)
            neutral_rows.append(f"| {model} | {cfg} | {len(neutral)} | {changed} | {100 * En / max(Nn, 1):.2f} % |")
            Eb = Ev = N = hb = hv = ht = 0; collateral = 0; ms = []
            for r in rows:
                m = man[r["id"]]
                ref = norm(m["ref"]); b = norm(r["base"]); v = norm(r[cfg])
                Sb, Db, Ib, opsb = align(ref, b); Sv, Dv, Iv, opsv = align(ref, v)
                Eb += Sb + Db + Ib; Ev += Sv + Dv + Iv; N += len(ref); ms.append(r[cfg + "_ms"])
                for t in m["jargon"]:
                    if t in target:
                        ht += 1; hb += contains(b, t); hv += contains(v, t)
                # collateral: reference words (not part of a target term) correct in base but wrong in boosted
                tw = set(sum((norm(t) for t in target), []))
                okb = {k for k, o in enumerate([o for o in opsb if o[0] != "I"]) if o[0] == "C"}
                okv = {k for k, o in enumerate([o for o in opsv if o[0] != "I"]) if o[0] == "C"}
                lost = [ref[k] for k in okb - okv if ref[k] not in tw]
                collateral += len(lost)
                if lost and len(examples) < 12:
                    examples.append(f"{model}/{cfg}/{r['id']}: lost {lost}: \"{r[cfg]}\"")
            ms.sort()
            print(f"| {model} | {cfg} | {100 * Eb / N:.2f} % -> {100 * Ev / N:.2f} % | {hb}/{ht} -> {hv}/{ht} | {collateral} | {ms[len(ms) // 2]:.0f} |")
    print("\nFalse-fire check on clips containing none of the 4 target terms:")
    print("| Model | Config | clips | transcripts changed | WER after |")
    print("|---|---|---|---|---|")
    for l in neutral_rows: print(l)
    print("\nCollateral examples:")
    for e in examples: print("- " + e)


def myvoice(tpath, paths):
    refs = {}
    for line in open(tpath):
        line = line.strip()
        if not line or line.startswith("#"): continue
        k, _, t = line.partition("\t") if "\t" in line else line.partition(" ")
        refs[os.path.splitext(os.path.basename(k.strip()))[0]] = t.strip()
    for p in paths:
        hy = load_jsonl(p); E = N = 0
        for h in hy:
            if h["id"] not in refs: continue
            r = norm(refs[h["id"]]); S, D, I, _ = align(r, norm(h["hyp"])); E += S + D + I; N += len(r)
            print(f"  {h['model']} {h['id']}: {h['hyp']}")
        print(f"MYVOICE {hy[0]['model']} files={len([h for h in hy if h['id'] in refs])} words={N} WER={100 * E / max(N, 1):.2f} %")


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "wer": wer_table(sys.argv[2:])
    elif cmd == "vocab": vocab_table(sys.argv[2:])
    elif cmd == "myvoice": myvoice(sys.argv[2], sys.argv[3:])
