#!/usr/bin/env bash
# =====================================================================
# scan-github.sh — GitHub API 経由の案件スキャナ（gh + 標準ツールのみ）
#
# 手元に clone していないリポジトリ（Private 含む）を GitHub API 経由で走査し、
# scan.sh と互換の技術メタデータ JSON を stdout に出す。
#   - 言語比率（GitHub Linguist のバイト数ベース。拡張子推定より正確）
#   - マニフェスト検出（ツリー API でファイル名を検出）
#   - 依存ライブラリの粗い抽出（package.json 等の中身のみ取得して grep）
#   - git 集計（初回/最終コミット日・コミット数・自分の関与コミット数）
#   - 規模（ツリーの blob 数 = 追跡ファイル数）
#
# コード実体は一切 stdout に出さない（L1 メタデータのみ）。
# マニフェストの中身は framework 判定のためだけに一時取得し、出力には含めない。
#
# 使い方:
#   scan-github.sh <owner/repo> [--author <login_or_email>] [--token-user <gh-account>]
#
# 認証: gh の既定トークン、または --token-user で指定した gh アカウントのトークンを使う。
# 判定(decision)による分岐は呼び出し側（スキル / run-all-github）で行う。常に読むだけ。
# =====================================================================
set -eu

FULL="${1:?usage: scan-github.sh <owner/repo> [--author <who>] [--token-user <gh-account>]}"
AUTHOR=""
TOKEN_USER=""
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --author) AUTHOR="${2:-}"; shift 2 ;;
    --token-user) TOKEN_USER="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

# --- 認証トークンの解決（gh CLI 経由。トークン文字列は出力しない）---
if [ -n "$TOKEN_USER" ]; then
  GH_TOKEN="$(gh auth token -u "$TOKEN_USER" 2>/dev/null || true)"
  export GH_TOKEN
fi

# --- author 未指定なら token-user（GitHub ログイン名）で名寄せする ---
# GitHub の commits?author= はログイン名で正確に名寄せする。メールだと
# noreply/別メールのコミットを取りこぼすため、ログイン名を既定にする。
if [ -z "$AUTHOR" ] && [ -n "$TOKEN_USER" ]; then
  AUTHOR="$TOKEN_USER"
fi

api() { gh api -H "Accept: application/vnd.github+json" "$@" 2>/dev/null; }

json_escape() { sed 's/\\/\\\\/g; s/"/\\"/g' <<<"$1"; }

# --- リポ存在チェック（無ければ error JSON を出して正常終了）---
if ! api "repos/$FULL" >/tmp/_si_repo.json 2>/dev/null; then
  echo "{\"repo\":\"$(json_escape "$FULL")\",\"error\":\"not accessible (missing or no permission)\"}"
  exit 0
fi

default_branch="$(gh api "repos/$FULL" --jq '.default_branch' 2>/dev/null || echo main)"
remote="https://github.com/$FULL"

# --- GitHub 固有メタ（star / fork / 公開URL / 公開可否）---
# repos/$FULL のレスポンスは上で /tmp/_si_repo.json に保存済み。そこから拾う。
stargazers="$(gh api "repos/$FULL" --jq '.stargazers_count' 2>/dev/null || echo 0)"
forks="$(gh api "repos/$FULL" --jq '.forks_count' 2>/dev/null || echo 0)"
html_url="$(gh api "repos/$FULL" --jq '.html_url' 2>/dev/null || echo "$remote")"
# private=true/false → is_public は否定。空や取得失敗時は false 扱い（安全側）。
is_private="$(gh api "repos/$FULL" --jq '.private' 2>/dev/null || echo true)"
[ "$is_private" = "false" ] && repo_is_public=true || repo_is_public=false
: "${stargazers:=0}"; : "${forks:=0}"
# contributor 数（anon 含む）。Link ヘッダの last ページ番号＝総数。取れなければ 1。
contributors="$(
  gh api "repos/$FULL/contributors?per_page=1&anon=true" --include 2>/dev/null \
    | grep -i '^link:' | grep -oE 'page=[0-9]+>; rel="last"' | grep -oE '[0-9]+' | head -1
)"
if [ -z "$contributors" ]; then
  contributors="$(gh api "repos/$FULL/contributors?per_page=100&anon=true" --jq 'length' 2>/dev/null || echo 1)"
fi
: "${contributors:=1}"

# --- 言語比率（Linguist: バイト数ベース）---
# /languages は {"TypeScript": 12345, "Python": 678, ...}
# gh api の --jq（内蔵 jq）でバイト数→比率つき配列に整形する。
lang_json="$(
  gh api "repos/$FULL/languages" --jq '
    (to_entries | map(.value) | add) as $total
    | to_entries
    | sort_by(-.value)
    | map(
        "{\"language\":\"\(.key)\",\"bytes\":\(.value),\"pct\":\(if $total>0 then (.value*1000/$total|floor/10) else 0 end)}"
      )
    | join(",")
  ' 2>/dev/null || true
)"

# --- ツリー（追跡ファイル一覧。blob のみ）---
tree_paths="$(
  gh api "repos/$FULL/git/trees/$default_branch?recursive=1" \
    --jq '.tree[] | select(.type=="blob") | .path' 2>/dev/null || true
)"
file_count="$(printf '%s\n' "$tree_paths" | grep -c . || true)"
: "${file_count:=0}"

# --- マニフェスト検出（ファイル名ベース）---
detect() { printf '%s\n' "$tree_paths" | grep -qiE "(^|/)$1$" && echo "$2" || true; }
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

# --- framework 検出（該当マニフェストの中身だけ一時取得して grep。出力には含めない）---
fetch_content() { # path -> stdout（base64 デコード済み中身）
  gh api "repos/$FULL/contents/$1?ref=$default_branch" --jq '.content' 2>/dev/null \
    | base64 --decode 2>/dev/null || true
}
frameworks=""
if printf '%s\n' "$tree_paths" | grep -qiE '(^|/)package\.json$'; then
  pj_path="$(printf '%s\n' "$tree_paths" | grep -iE '(^|/)package\.json$' | head -1)"
  pj="$(fetch_content "$pj_path")"
  for fw in next react vue nuxt express nestjs prisma typeorm tailwindcss vite webpack jest vitest playwright; do
    printf '%s' "$pj" | grep -qiE "\"$fw" && frameworks="$frameworks $fw"
  done
fi
if printf '%s\n' "$tree_paths" | grep -qiE '(^|/)go\.mod$'; then
  gm="$(fetch_content "$(printf '%s\n' "$tree_paths" | grep -iE '(^|/)go\.mod$' | head -1)")"
  printf '%s' "$gm" | grep -qi 'gin-gonic' && frameworks="$frameworks gin"
  printf '%s' "$gm" | grep -qi 'gorm' && frameworks="$frameworks gorm"
fi
for pyf in requirements.txt pyproject.toml; do
  if printf '%s\n' "$tree_paths" | grep -qiE "(^|/)$pyf$"; then
    c="$(fetch_content "$(printf '%s\n' "$tree_paths" | grep -iE "(^|/)$pyf$" | head -1)")"
    for fw in django fastapi flask sqlalchemy pandas numpy; do
      printf '%s' "$c" | grep -qiE "$fw" && frameworks="$frameworks $fw"
    done
  fi
done
fw_json="$(printf '%s\n' $frameworks | awk 'NF{printf "%s\"%s\"",(c++?",":""),$0}')"

# --- git 集計（commits API）---
commits="$(gh api "repos/$FULL/commits?sha=$default_branch&per_page=1" --jq 'length' 2>/dev/null || echo 0)"
# 総コミット数は Link ヘッダの last ページ番号で得る（per_page=1 で末尾ページ = 総数）
total_commits="$(
  gh api "repos/$FULL/commits?sha=$default_branch&per_page=1" --include 2>/dev/null \
    | grep -i '^link:' | grep -oE 'page=[0-9]+>; rel="last"' | grep -oE '[0-9]+' | head -1
)"
: "${total_commits:=$commits}"
last_commit="$(gh api "repos/$FULL/commits?sha=$default_branch&per_page=1" --jq '.[0].commit.author.date' 2>/dev/null | cut -c1-10 || true)"

# 初回コミット日: per_page=1 の最終ページ（= 最古のコミット）を取る。
first_commit=""
if [ -n "$total_commits" ] && [ "$total_commits" -gt 0 ] 2>/dev/null; then
  first_commit="$(
    gh api "repos/$FULL/commits?sha=$default_branch&per_page=1&page=$total_commits" \
      --jq '.[0].commit.author.date' 2>/dev/null | cut -c1-10 || true
  )"
fi

my_commits=0
if [ -n "$AUTHOR" ]; then
  my_commits="$(
    gh api "repos/$FULL/commits?sha=$default_branch&author=$AUTHOR&per_page=1" --include 2>/dev/null \
      | grep -i '^link:' | grep -oE 'page=[0-9]+>; rel="last"' | grep -oE '[0-9]+' | head -1
  )"
  if [ -z "$my_commits" ]; then
    my_commits="$(gh api "repos/$FULL/commits?sha=$default_branch&author=$AUTHOR&per_page=1" --jq 'length' 2>/dev/null || echo 0)"
  fi
fi
: "${my_commits:=0}"

# --- 出力（scan.sh と互換の形。source を github にして区別）---
cat <<EOF
{
  "repo": "$(json_escape "$FULL")",
  "source": "github",
  "remote": "$(json_escape "$remote")",
  "html_url": "$(json_escape "$html_url")",
  "default_branch": "$(json_escape "$default_branch")",
  "stargazers": ${stargazers:-0},
  "forks": ${forks:-0},
  "contributors": ${contributors:-1},
  "is_public": ${repo_is_public:-false},
  "file_count": ${file_count:-0},
  "languages": [${lang_json}],
  "manifests": [${manifest_json}],
  "frameworks": [${fw_json}],
  "git": {
    "first_commit": "$(json_escape "$first_commit")",
    "last_commit": "$(json_escape "$last_commit")",
    "commits": ${total_commits:-0},
    "author_filter": "$(json_escape "$AUTHOR")",
    "author_commits": ${my_commits:-0}
  }
}
EOF

rm -f /tmp/_si_repo.json 2>/dev/null || true
