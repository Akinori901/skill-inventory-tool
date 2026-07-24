#!/usr/bin/env bash
# =====================================================================
# run-all.sh — 台帳(ledger/projects.yaml)に従い全案件をスキャン。
#
# 各案件の repos を scan.sh でメタデータ化し、
#   output/reports/<key>.json にまとめて書く（コード実体は含まない）。
#
# decision による安全ゲート:
#   pending / metadata_only  → メタデータJSONのみ（コードには一切触れない）
#   anonymize / as_is        → メタデータJSON + 「コード生成が許可されている」旨のフラグ。
#                              実際のコード生成はスキル側の責務（人間承認前提）。
#
# 依存ゼロ（bash + awk + scan.sh）。YAML は必要な最小フィールドだけを awk で読む。
# =====================================================================
set -eu   # pipefail は付けない（scan.sh と同じ理由: 非破壊な集計を誤失敗させない）

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LEDGER="$ROOT/ledger/projects.yaml"
OUT="$ROOT/output/reports"
AUTHOR="${SKILL_INV_AUTHOR:-}"   # 自分の関与コミット数を出したい場合に export
mkdir -p "$OUT"

[ -f "$LEDGER" ] || { echo "ledger not found: $LEDGER" >&2; exit 1; }

# --- projects.yaml から key / decision / repos を最小パース ---
# 想定フォーマットは projects.yaml のテンプレに準拠（2スペースインデントの projects: 配下）。
awk '
  /^projects:/ {inproj=1; next}
  inproj && /^[a-zA-Z]/ {inproj=0}                 # 別トップレベルキーで終了
  inproj && /^  - key:/ {
    if (key!="") flush()
    key=trim($0, "key:"); decision="pending"; repos=""
    next
  }
  inproj && /^    decision:/ {decision=trim($0,"decision:"); next}
  inproj && /^    display_name:/ {dn=trim($0,"display_name:"); next}
  inproj && /^      - \// {
    r=$0; sub(/^      - /,"",r); repos=repos (repos==""?"":"|") r
    next
  }
  END { if (key!="") flush() }
  function trim(line, label,   v){ sub(".*"label,"",line); sub(/[ \t]*#.*/,"",line); gsub(/^[ \t]+|[ \t]+$/,"",line); gsub(/^"|"$/,"",line); return line }
  function flush(){ print key "\t" decision "\t" dn "\t" repos; key=""; dn="" }
' "$LEDGER" | while IFS=$'\t' read -r key decision dn repos; do
  [ -n "$key" ] || continue
  echo ">> $key  (decision=$decision)  $dn" >&2

  # コード生成が許可されているか
  case "$decision" in
    anonymize|as_is) code_allowed=true ;;
    *)               code_allowed=false ;;
  esac

  repo_json=""
  IFS='|'; for repo in $repos; do
    [ -n "$repo" ] || continue
    if [ -d "$repo" ]; then
      one="$(bash "$HERE/scan.sh" "$repo" ${AUTHOR:+--author "$AUTHOR"})"
    else
      one="{\"repo_path\":\"$repo\",\"error\":\"missing on this machine\"}"
    fi
    repo_json="$repo_json${repo_json:+,}$one"
  done; unset IFS

  cat > "$OUT/$key.json" <<EOF
{
  "key": "$key",
  "display_name": "$dn",
  "decision": "$decision",
  "code_generation_allowed": $code_allowed,
  "scanned_repos": [${repo_json}]
}
EOF
  echo "   wrote $OUT/$key.json" >&2
done

echo "done. reports in $OUT" >&2
