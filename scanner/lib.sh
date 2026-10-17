# shellcheck shell=bash
# scanner/*.sh 共通の小道具。依存ゼロ（bash と tr だけ）。

# JSON 文字列の中身としてエスケープする。
# 台帳の display_name やリポのパスは人が書く値なので、" \ だけでなく
# タブ・改行・制御文字も来うる。そのまま埋めると壊れた JSON になる。
json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/\\r}
  s=${s//$'\n'/\\n}
  # 残りの制御文字（JSON で生のまま置けないもの）は落とす
  printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037'
}

# URL に埋め込まれた認証情報（https://user:token@host/...）を取り除く。
# remote URL はレポートにそのまま出るため。ssh 形式（git@host:org/repo）はそのまま。
strip_url_credentials() {
  printf '%s' "$1" | sed -E 's#^(https?://)[^/@]+@#\1#'
}

# 台帳の key として受け付ける形。key は出力ファイル名にも使うので、
# "/" や ".." を含むと output/reports の外に書けてしまう。
is_valid_key() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]
}
