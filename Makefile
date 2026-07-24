# skill-inventory — 依存ゼロ運用
# SKILL_INV_AUTHOR に自分の git author 名/メールを入れると関与コミット数が出る。

AUTHOR ?= $(SKILL_INV_AUTHOR)

.PHONY: scan scan-one link help

help:
	@echo "make scan                 台帳の全案件をスキャンし output/reports/*.json を更新"
	@echo "make scan-one REPO=<path>  単一リポのメタデータを表示"
	@echo "make link                 このリポの skill/ を ~/.claude/skills/ にシンボリックリンク"
	@echo "  (AUTHOR=<name> で関与コミット数を集計)"

scan:
	@SKILL_INV_AUTHOR="$(AUTHOR)" bash scanner/run-all.sh

scan-one:
	@bash scanner/scan.sh "$(REPO)" $(if $(AUTHOR),--author "$(AUTHOR)",)

link:
	@ln -sfn "$(CURDIR)/skill" "$(HOME)/.claude/skills/skill-inventory" \
	  && echo "linked -> $(HOME)/.claude/skills/skill-inventory"
