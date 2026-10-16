#!/usr/bin/env bash
# scanner のテスト。依存ゼロ（bash / git / python3 の json だけ）。
#   bash tests/run.sh
# GitHub API を叩く scan-github.sh は対象外（ネットワークと認証が要るため）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scanner/lib.sh
. "$ROOT/scanner/lib.sh"

pass=0; fail=0
ok()   { pass=$((pass + 1)); echo "  ok   $1"; }
ng()   { fail=$((fail + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else ng "$1"; fi; }
json_get() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {}, {"d": d}))' "$@"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

echo "lib.sh"
v="$(json_escape "$(printf 'a"b\\c\td\ne\001f')")"
printf '{"v":"%s"}' "$v" > "$TMP/esc.json"
check "json_escape の結果が JSON として読める" "python3 -m json.tool '$TMP/esc.json' >/dev/null"
check "タブと改行が保たれ、制御文字は落ちる" "[ \"\$(json_get '$TMP/esc.json' 'repr(d[\"v\"])')\" = \"'a\\\"b\\\\\\\\c\\\\td\\\\nef'\" ]"
check "https の userinfo を除く" "[ \"\$(strip_url_credentials 'https://u:tok@github.com/o/r.git')\" = 'https://github.com/o/r.git' ]"
check "ssh 形式はそのまま" "[ \"\$(strip_url_credentials 'git@github.com:o/r.git')\" = 'git@github.com:o/r.git' ]"
check "正しい key は通す" "is_valid_key acme-1.v2"
for bad in '../x' 'a/b' '.hidden' ''; do
  check "不正な key を弾く: '$bad'" "! is_valid_key '$bad'"
done

echo "scan.sh"
git init -q "$TMP/repo"
printf 'print(1)\n' > "$TMP/repo/main.py"
printf '{"dependencies":{"react":"18"}}\n' > "$TMP/repo/package.json"
git -C "$TMP/repo" add . && git -C "$TMP/repo" commit -qm init
git -C "$TMP/repo" remote add origin "https://someone:FAKE_TOKEN@github.com/org/repo.git"
bash "$ROOT/scanner/scan.sh" "$TMP/repo" --author t@example.com > "$TMP/scan.json"
check "出力が JSON として読める" "python3 -m json.tool '$TMP/scan.json' >/dev/null"
check "remote に認証情報が残らない" "[ \"\$(json_get '$TMP/scan.json' 'd[\"remote\"]')\" = 'https://github.com/org/repo.git' ]"
check "言語・FW・関与コミットを数える" "[ \"\$(json_get '$TMP/scan.json' '(d[\"file_count\"], \"react\" in d[\"frameworks\"], d[\"git\"][\"author_commits\"])')\" = '(2, True, 1)' ]"

echo "run-all.sh"
mkdir -p "$TMP/tool/ledger" "$TMP/tool/scanner"
cp "$ROOT"/scanner/*.sh "$TMP/tool/scanner/"
printf 'projects:\n  - key: good-one\n    decision: anonymize\n    display_name: "Tab\there \\"q\\""\n    repos:\n      - %s\n      - /no/such/repo\n  - key: ../../escaped\n    decision: as_is\n    repos:\n      - %s\n' \
  "$TMP/repo" "$TMP/repo" > "$TMP/tool/ledger/projects.yaml"
bash "$TMP/tool/scanner/run-all.sh" 2>/dev/null
R="$TMP/tool/output/reports/good-one.json"
check "レポートが JSON として読める" "python3 -m json.tool '$R' >/dev/null"
check "display_name のタブで列がずれない" "[ \"\$(json_get '$R' '(d[\"display_name\"].startswith(\"Tab\\there\"), len(d[\"scanned_repos\"]))')\" = '(True, 2)' ]"
check "存在しないリポは error として残る" "[ \"\$(json_get '$R' 'd[\"scanned_repos\"][1][\"error\"]')\" = 'missing on this machine' ]"
check "anonymize はコード生成可" "[ \"\$(json_get '$R' 'd[\"code_generation_allowed\"]')\" = 'True' ]"
check "不正な key では output/reports の外に書かない" "[ -z \"\$(find '$TMP' -name 'escaped.json')\" ]"

echo ".gitignore"
for f in ledger/projects.yaml output/career-feed.json output/reports/x.json nda/contract.pdf output/publishable/x.ts; do
  check "$f は追跡されない" "git -C '$ROOT' check-ignore -q '$f'"
done
for f in ledger/projects.example.yaml nda/README.md output/reports/.gitkeep; do
  check "$f は追跡される" "! git -C '$ROOT' check-ignore -q '$f'"
done

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
