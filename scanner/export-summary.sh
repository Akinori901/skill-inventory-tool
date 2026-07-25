#!/usr/bin/env bash
# =====================================================================
# export-summary.sh — 案件レポートを案件単位の技術サマリに集約する。
#
# 台帳(ledger/projects.yaml)の案件ごとに repos を見て、各リポの技術メタを
# 案件単位に集約した career-feed（JSON）を出力する。職務経歴書の技術欄や、
# 経歴管理アプリへの取り込みなど、下流で「案件ごとに何をどれだけやったか」を
# 使いたいときの供給元になる。
#
# ハイブリッド集約:
#   各リポについて「GitHub 走査レポート優先、無ければローカル走査レポート」を使う。
#     - GitHub 走査(output/reports/github/<owner>__<repo>.json)は
#       関与コミット数(author_commits)がログイン名で正確に名寄せされている。
#     - 自分の GitHub org に無いリポ（顧客 org 等）はローカル走査にフォールバック。
#
# 出力: output/career-feed.json（案件単位・L1 メタのみ・コード実体なし）
#
# 使い方: export-summary.sh --owner <gh-owner> [--out <path>]
# =====================================================================
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OWNER=""
OUT="$ROOT/output/career-feed.json"
while [ $# -gt 0 ]; do
  case "$1" in
    --owner) OWNER="${2:?}"; shift 2 ;;
    --out) OUT="${2:?}"; shift 2 ;;
    *) shift ;;
  esac
done

# owner は GitHub 走査レポートのファイル名(<owner>__<repo>.json)照合に使う。
# 未指定でもローカル走査レポートだけで集約できる（GitHub 優先はスキップ）。

python3 - "$ROOT" "$OWNER" "$OUT" <<'PY'
import sys, json, os, glob, collections, re

root, owner, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
reports = os.path.join(root, "output", "reports")
gh_dir = os.path.join(reports, "github")
ledger = os.path.join(root, "ledger", "projects.yaml")


def parse_ledger(path):
    """依存ゼロの最小 YAML パース（projects[].key/decision/display_name/repos）。"""
    projects, cur = [], None
    if not os.path.exists(path):
        return projects
    in_proj = False
    for line in open(path, encoding="utf-8"):
        s = line.rstrip("\n")
        if re.match(r"^projects:", s):
            in_proj = True; continue
        if in_proj and re.match(r"^[A-Za-z]", s):
            in_proj = False
        if not in_proj:
            continue
        m = re.match(r"^  - key:\s*(.+?)\s*(#.*)?$", s)
        if m:
            if cur: projects.append(cur)
            cur = {"key": m.group(1).strip().strip('"'), "decision": "pending",
                   "display_name": "", "repos": []}
            continue
        if cur is None:
            continue
        m = re.match(r"^    decision:\s*(.+?)\s*(#.*)?$", s)
        if m: cur["decision"] = m.group(1).strip().strip('"'); continue
        m = re.match(r"^    display_name:\s*(.+?)\s*(#.*)?$", s)
        if m: cur["display_name"] = m.group(1).strip().strip('"'); continue
        m = re.match(r"^      - (.+?)\s*$", s)
        if m: cur["repos"].append(m.group(1).strip()); continue
    if cur: projects.append(cur)
    return projects


def load_json(path):
    try:
        return json.load(open(path, encoding="utf-8"))
    except Exception:
        return None


# ローカル走査レポート（案件単位）を key で引けるように
local_reports = {}
for p in glob.glob(os.path.join(reports, "*.json")):
    d = load_json(p)
    if d and "scanned_repos" in d:
        local_reports[d.get("key")] = d

projects = parse_ledger(ledger)
engagements = []

for proj in projects:
    key = proj["key"]
    lang_bytes = collections.Counter()
    lang_files = collections.Counter()
    fws, manifests = set(), set()
    total_files = total_commits = my_commits = 0
    firsts, lasts = [], []
    repo_count = 0
    sources = []  # どのソースを使ったか（github/local）

    for repo_path in proj["repos"]:
        repo_name = repo_path.rstrip("/").split("/")[-1]
        gh_file = os.path.join(gh_dir, f"{owner}__{repo_name}.json") if owner else ""
        r = load_json(gh_file) if gh_file and os.path.exists(gh_file) else None
        src = "github"
        if r is None or r.get("error"):
            # フォールバック: ローカル走査レポート内の同名リポ
            r = None
            lr = local_reports.get(key)
            if lr:
                for sr in lr.get("scanned_repos", []):
                    if sr.get("repo_path", "").rstrip("/").split("/")[-1] == repo_name:
                        r = sr; src = "local"; break
        if r is None or r.get("error"):
            continue

        repo_count += 1
        sources.append(f"{repo_name}:{src}")
        for l in r.get("languages", []):
            if "bytes" in l: lang_bytes[l["language"]] += l["bytes"]
            if "files" in l: lang_files[l["language"]] += l["files"]
        fws.update(r.get("frameworks", []))
        manifests.update(r.get("manifests", []))
        total_files += r.get("file_count", 0) or 0
        g = r.get("git", {})
        total_commits += g.get("commits", 0) or 0
        my_commits += g.get("author_commits", 0) or 0
        if g.get("first_commit"): firsts.append(g["first_commit"])
        if g.get("last_commit"): lasts.append(g["last_commit"])

    base = lang_bytes if lang_bytes else lang_files
    total = sum(base.values()) or 1
    languages = [{"language": n, "pct": round(v * 100.0 / total, 1)} for n, v in base.most_common()]

    engagements.append({
        "source_key": key,
        "display_name": proj["display_name"] or key,
        "decision": proj["decision"],
        "repo_count": repo_count,
        "sources": sources,
        "languages": languages,
        "frameworks": sorted(fws),
        "manifests": sorted(manifests),
        "period_start": min(firsts) if firsts else "",
        "period_end": max(lasts) if lasts else "",
        "file_count": total_files,
        "total_commits": total_commits,
        "my_commits": my_commits,
    })

feed = {
    "schema": "career-feed/v1",
    "note": "L1 metadata summary per engagement (hybrid: github-scan preferred, local fallback). No code.",
    "engagements": engagements,
}
json.dump(feed, open(out_path, "w"), ensure_ascii=False, indent=2)
print(f"wrote {out_path}  ({len(engagements)} engagements)", file=sys.stderr)
PY
