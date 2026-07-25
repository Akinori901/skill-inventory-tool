#!/usr/bin/env bash
# =====================================================================
# run-all-github.sh — GitHub アカウントの全リポ（Private 含む）を
# API 経由で列挙し、scan-github.sh でまとめてメタデータ化する。
#
# 手元に clone していないリポも対象にできる「発見的・網羅的」な棚卸し。
# 出力は output/reports/github/<owner>__<repo>.json（コード実体は含まない）。
#
# ⚠️ 重要（安全設計）:
#   これは Step 2（技術メタデータ集計）専用。コード実体は取得せず、L1 メタデータのみ。
#   顧客帰属リポが混じっても「メタデータのみ」なので安全だが、
#   ここで出た結果を根拠に「コードを公開してよい」と判断してはいけない。
#   コード掲載可否は必ず台帳(ledger/projects.yaml)の decision と NDA 読解で決める。
#
# 使い方:
#   run-all-github.sh <owner> [--token-user <gh-account>] [--author <who>]
#                             [--include-forks] [--public-only|--private-only]
#
# 例:
#   run-all-github.sh <your-gh-login> --token-user <your-gh-login> --author <your-gh-login>
# =====================================================================
set -eu

OWNER="${1:?usage: run-all-github.sh <owner> [--token-user <gh>] [--author <who>] [--include-forks] [--public-only|--private-only]}"
shift || true
TOKEN_USER=""
AUTHOR=""
INCLUDE_FORKS=false
VIS_FILTER=""   # "", public, private
while [ $# -gt 0 ]; do
  case "$1" in
    --token-user) TOKEN_USER="${2:-}"; shift 2 ;;
    --author) AUTHOR="${2:-}"; shift 2 ;;
    --include-forks) INCLUDE_FORKS=true; shift ;;
    --public-only) VIS_FILTER="public"; shift ;;
    --private-only) VIS_FILTER="private"; shift ;;
    *) shift ;;
  esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="$ROOT/output/reports/github"
mkdir -p "$OUT"

if [ -n "$TOKEN_USER" ]; then
  GH_TOKEN="$(gh auth token -u "$TOKEN_USER" 2>/dev/null || true)"
  export GH_TOKEN
fi

# --- リポ一覧を取得（visibility / fork でフィルタ）---
echo ">> listing repos for $OWNER ..." >&2
repos="$(
  gh repo list "$OWNER" --limit 200 --json name,visibility,isFork \
    --jq '.[] | [.name, (.visibility|ascii_downcase), (.isFork|tostring)] | @tsv' 2>/dev/null || true
)"

[ -n "$repos" ] || { echo "no repos found (or no permission) for $OWNER" >&2; exit 1; }

count=0
index_entries=""
while IFS=$'\t' read -r name vis is_fork; do
  [ -n "$name" ] || continue
  [ "$INCLUDE_FORKS" = true ] || [ "$is_fork" != "true" ] || { echo "   skip fork: $name" >&2; continue; }
  [ -z "$VIS_FILTER" ] || [ "$vis" = "$VIS_FILTER" ] || continue

  full="$OWNER/$name"
  echo ">> scan $full ($vis)" >&2
  out_file="$OUT/${OWNER}__${name}.json"
  bash "$HERE/scan-github.sh" "$full" \
    ${AUTHOR:+--author "$AUTHOR"} \
    ${TOKEN_USER:+--token-user "$TOKEN_USER"} \
    > "$out_file" 2>/dev/null || echo "{\"repo\":\"$full\",\"error\":\"scan failed\"}" > "$out_file"

  count=$((count + 1))
  index_entries="$index_entries${index_entries:+,}{\"repo\":\"$full\",\"visibility\":\"$vis\",\"report\":\"github/${OWNER}__${name}.json\"}"
done <<< "$repos"

# --- インデックス（一覧）を書き出す ---
cat > "$OUT/_index.json" <<EOF
{
  "owner": "$OWNER",
  "scanned_count": $count,
  "author_filter": "$AUTHOR",
  "note": "L1 metadata only. Code publication requires ledger decision + NDA review.",
  "repos": [${index_entries}]
}
EOF

echo "done. $count reports in $OUT (index: $OUT/_index.json)" >&2
