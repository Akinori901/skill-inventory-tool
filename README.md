# skill-inventory

過去に関わった案件を **安全に棚卸し** するためのツール。

1. **技術スキルを機械集計** — 各リポの言語比率・フレームワーク・規模・期間を JSON 化
2. **NDA/契約を読解して掲載可否を判定** — 「自分のリポジトリに何をどう載せてよいか（帰属・複製可否・匿名化要否）」を、契約に基づいて判断
3. **載せてよい形に変換した公開可能コードを生成** — 自社帰属はそのまま、留保された汎用部品は切り出して

**外部ツール依存ゼロ**（`git` と標準 `find`/`grep` のみ）。どのマシンでも `git clone` するだけで動く。

> ⚠️ このツールは棚卸しの**判断を支援**するもので、帰属や複製可否の**最終的な法的判断を代替しません**。
> 契約の解釈に迷う場合は必ず専門家に確認してください。実案件データ・契約書・顧客名は
> **絶対にこのリポジトリ（や公開先）にコミットしないでください**（`.gitignore` で保護済み）。

---

## 中核の考え方：NDAが正、台帳はそのキャッシュ

「顧客帰属か自社帰属か」「複製してよいか」「匿名化が要るか」は、
**NDA・受託開発契約・秘密保持条項が唯一の根拠**。
このツールはコードの中身から帰属を推測しない。まず契約を読み、判定を台帳に固定し、以降はその台帳に従う。

```
NDA/契約書 (nda/<案件>/*)                          ← 一次情報（gitignore。リポには載せない）
      │  Claude が読解（skill/SKILL.md）
      ▼
判定 (ledger/projects.yaml の各案件エントリ)         ← 判定のキャッシュ。人間が最終承認
      │
      ├─ metadata_only  → 技術メタデータのみ（コードは一切載せない）
      ├─ anonymize      → 匿名化・秘匿除去した公開用コードを生成して載せる
      └─ as_is          → 自社帰属。コードごと載せてよい
      ▼
scanner/scan.sh                                    ← 台帳に従い L1 メタデータを抽出
      ▼
output/reports/<案件>.json                         ← 技術集計
output/publishable/<案件>/                         ← 載せてよい形に変換されたコード
```

## 3層モデル（何を外に出すか）

| 層 | 中身 | metadata_only | anonymize | as_is |
|---|---|:---:|:---:|:---:|
| L1 メタデータ | 言語比率・FW・ライブラリ・規模・期間 | ✅ | ✅ | ✅ |
| L2 知見/パターン | 匿名化した設計判断・ハマりどころ | ✅(匿名) | ✅ | ✅ |
| L3 コード実体 | ソースそのもの | ❌ | 変換後のみ | ✅ |

**顧客帰属コードを丸ごと公開リポに置くことは、このツールは決してしない。**
どうしてもバックアップが要る顧客帰属コードは、公開/第三者クラウドではなく
**暗号化ローカルバックアップ**へ（契約の「第三者環境への複製」に触れないため）。

## セットアップ

```bash
git clone <this-repo>
cd skill-inventory
cp ledger/projects.example.yaml ledger/projects.yaml   # 台帳を作る（実データはgitignore）
ln -s "$PWD/skill" ~/.claude/skills/skill-inventory     # Claude Code スキルとして有効化（任意）
```

## 使い方

### 技術メタデータを集計（いつでも安全・コードを出さない）
```bash
export SKILL_INV_AUTHOR="<自分の git author 名 or email>"   # 関与コミット数を出す場合
make scan                              # 台帳の全案件をスキャン → output/reports/*.json
make scan-one REPO=/path/to/repo       # 単一リポのメタデータを表示
```

### NDA読解 → 判定 → 掲載用コード生成（Claude Code スキル）
`skill/SKILL.md` を `~/.claude/skills/` にリンクすると、Claude Code から
「NDA読解 → 判定を台帳に記録（要人間承認）→ スキャン → 集計/公開コード生成」まで対話で進む。
詳細は [skill/SKILL.md](skill/SKILL.md) を参照。

## ディレクトリ

```
skill/           Claude Code スキル本体（SKILL.md）
ledger/          projects.example.yaml（雛形）。実体 projects.yaml は各自作成・gitignore
nda/             NDA/契約書の原本置き場（gitignore。リポには載らない）
scanner/         依存ゼロのスキャナ scan.sh / run-all.sh
output/reports/  技術メタデータ JSON（gitignore）
output/publishable/  載せてよい形に変換されたコード（gitignore）
```

## 安全装置

- `ledger/projects.yaml`・`nda/`・`output/` の実データは `.gitignore` で追跡対象外。
- 台帳 `decision` が `as_is`/`anonymize` 以外の案件は、scan がメタデータJSONを出すだけでコードに触れない（fail-safe）。
- 判定は必ず人間が承認。Claude の読解は下書きであり、最終責任は人間。

## ライセンス

MIT License（[LICENSE](LICENSE)）。ツール部分の利用は自由。
生成される棚卸し結果・判定の正しさは保証しません（免責は上記および LICENSE を参照）。
