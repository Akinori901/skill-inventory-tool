# nda/ — 契約書・NDA 原本の置き場（このリポには push されない）

案件ごとにサブディレクトリを作り、NDA・受託開発契約・秘密保持覚書などの
原本（PDF/テキスト）をここに置く。`.gitignore` により追跡対象外。

```
nda/
  client_a/      契約書PDF, NDA など
  client_b/
  ...
```

スキル `/skill-inventory` はここのファイルを Claude に読ませ、
「帰属 / 複製可否 / 匿名化要否」を判定して `ledger/projects.yaml` に下書きする。
判定は必ず人間が承認すること。原本はローカルにのみ存在させる。
