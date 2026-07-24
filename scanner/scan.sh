#!/usr/bin/env bash
# =====================================================================
# scan.sh — 依存ゼロの案件スキャナ（git + 標準 find/grep/awk のみ）
#
# 1リポジトリを走査して技術メタデータ JSON を stdout に出す。
#   - 言語比率（拡張子ベースのファイル数）
#   - マニフェスト検出（package.json / go.mod / requirements.txt ...）
#   - 依存ライブラリの粗い抽出（マニフェストから）
#   - git 集計（初回/最終コミット、コミット数、自分の関与コミット数）
#   - 規模（追跡ファイル数）
#
# コード実体は一切出力しない（L1 メタデータのみ）。
#
# 使い方:
#   scan.sh <repo_path> [--author <email_or_name>]
#
# 判定(decision)による分岐は呼び出し側（スキル / run-all）で行う。
# このスクリプト自体は「読むだけ」で、常にメタデータのみを出す安全な部品。
# =====================================================================
# pipefail はあえて付けない: head -1 等でパイプ先頭が SIGPIPE 終了すると
# 「読むだけ」の集計が誤って失敗扱いになるため。scan は非破壊なので -eu で十分。
set -eu

REPO="${1:?usage: scan.sh <repo_path> [--author <who>]}"
AUTHOR=""
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --author) AUTHOR="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

[ -d "$REPO" ] || { echo "{\"error\":\"not a directory: $REPO\"}"; exit 0; }

json_escape() { sed 's/\\/\\\\/g; s/"/\\"/g' <<<"$1"; }

# --- git がある場合の追跡ファイル一覧、無ければ find フォールバック ---
is_git=false
if git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  is_git=true
fi

list_files() {
  if $is_git; then
    git -C "$REPO" ls-files
  else
    ( cd "$REPO" && find . -type f \
        -not -path '*/node_modules/*' -not -path '*/.git/*' \
        -not -path '*/vendor/*' -not -path '*/dist/*' -not -path '*/build/*' \
        | sed 's|^\./||' )
  fi
}

FILES="$(list_files || true)"
FILE_COUNT="$(printf '%s\n' "$FILES" | grep -c . || true)"
: "${FILE_COUNT:=0}"

# --- 言語比率（拡張子 → 言語名。判定できない拡張子は集計外）---
declare_lang() { # ext -> lang
  case "$1" in
    ts|tsx) echo TypeScript ;;
    js|jsx|mjs|cjs) echo JavaScript ;;
    py) echo Python ;;
    go) echo Go ;;
    rb) echo Ruby ;;
    php) echo PHP ;;
    java) echo Java ;;
    kt) echo Kotlin ;;
    swift) echo Swift ;;
    cs) echo "C#" ;;
    rs) echo Rust ;;
    c|h) echo C ;;
    cpp|cc|hpp) echo "C++" ;;
    sql) echo SQL ;;
    sh|bash|zsh) echo Shell ;;
    vue) echo Vue ;;
    scss|sass|css) echo CSS ;;
    html|htm) echo HTML ;;
    tf) echo Terraform ;;
    yml|yaml) echo YAML ;;
    *) echo "" ;;
  esac
}

# 拡張子ごとの件数を集計
lang_counts="$(
  printf '%s\n' "$FILES" | while IFS= read -r f; do
    [ -n "$f" ] || continue
    ext="${f##*.}"
    [ "$ext" != "$f" ] || continue
    lang="$(declare_lang "$ext")"
    [ -n "$lang" ] && echo "$lang"
  done | sort | uniq -c | sort -rn
)"

lang_total="$(printf '%s\n' "$lang_counts" | awk '{s+=$1} END{print s+0}')"
lang_json="$(
  printf '%s\n' "$lang_counts" | awk -v total="$lang_total" '
    NF>=2 {
      cnt=$1; $1=""; sub(/^ /,""); name=$0
      pct = (total>0)? (cnt*100.0/total) : 0
      printf "%s{\"language\":\"%s\",\"files\":%d,\"pct\":%.1f}", (NR>1?",":""), name, cnt, pct
    }'
)"

# --- マニフェスト検出 ---
detect() { printf '%s\n' "$FILES" | grep -qiE "(^|/)$1$" && echo "$2" || true; }
manifests="$(
  { detect 'package\.json' package.json
    detect 'go\.mod' go.mod
    detect 'requirements\.txt' requirements.txt
    detect 'pyproject\.toml' pyproject.toml
    detect 'Gemfile' Gemfile
    detect 'composer\.json' composer.json
    detect 'pom\.xml' pom.xml
    detect 'build\.gradle' build.gradle
    detect 'Cargo\.toml' Cargo.toml
    detect '.*\.csproj' csproj
    detect 'Dockerfile' Dockerfile
    detect 'docker-compose\.ya?ml' docker-compose
  } | grep . || true
)"
manifest_json="$(printf '%s\n' "$manifests" | awk 'NF{printf "%s\"%s\"",(c++?",":""),$0}')"

# --- 主要フレームワーク/ライブラリの粗い検出（マニフェスト中の名前を grep）---
frameworks=""
pkg="$REPO/package.json"
if [ -f "$pkg" ]; then
  for fw in next react vue nuxt express nestjs prisma typeorm tailwindcss vite webpack jest vitest playwright; do
    grep -qiE "\"$fw" "$pkg" && frameworks="$frameworks $fw"
  done
fi
[ -f "$REPO/go.mod" ] && { grep -qi 'gin-gonic' "$REPO/go.mod" && frameworks="$frameworks gin"; grep -qi 'gorm' "$REPO/go.mod" && frameworks="$frameworks gorm"; }
for pyf in "$REPO/requirements.txt" "$REPO/pyproject.toml"; do
  [ -f "$pyf" ] || continue
  for fw in django fastapi flask sqlalchemy pandas numpy; do
    grep -qiE "$fw" "$pyf" && frameworks="$frameworks $fw"
  done
done
fw_json="$(printf '%s\n' $frameworks | awk 'NF{printf "%s\"%s\"",(c++?",":""),$0}')"

# --- git 集計 ---
first_commit=""; last_commit=""; commits=0; my_commits=0
if $is_git; then
  first_commit="$(git -C "$REPO" log --reverse --format=%as 2>/dev/null | head -1 || true)"
  last_commit="$(git -C "$REPO" log -1 --format=%as 2>/dev/null || true)"
  commits="$(git -C "$REPO" rev-list --count HEAD 2>/dev/null || echo 0)"
  if [ -n "$AUTHOR" ]; then
    my_commits="$(git -C "$REPO" rev-list --count --author="$AUTHOR" HEAD 2>/dev/null || echo 0)"
  fi
fi

remote="$(git -C "$REPO" remote get-url origin 2>/dev/null || echo "")"

# --- 出力 ---
cat <<EOF
{
  "repo_path": "$(json_escape "$REPO")",
  "remote": "$(json_escape "$remote")",
  "is_git": $is_git,
  "file_count": ${FILE_COUNT:-0},
  "languages": [${lang_json}],
  "manifests": [${manifest_json}],
  "frameworks": [${fw_json}],
  "git": {
    "first_commit": "$(json_escape "$first_commit")",
    "last_commit": "$(json_escape "$last_commit")",
    "commits": ${commits:-0},
    "author_filter": "$(json_escape "$AUTHOR")",
    "author_commits": ${my_commits:-0}
  }
}
EOF
