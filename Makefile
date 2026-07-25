# skill-inventory — 依存ゼロ運用
# SKILL_INV_AUTHOR に自分の git author 名/メールを入れると関与コミット数が出る。

AUTHOR ?= $(SKILL_INV_AUTHOR)

.PHONY: scan scan-one scan-github summary link help

help:
	@echo "make scan                        台帳の全案件をローカル走査し output/reports/*.json を更新"
	@echo "make scan-one REPO=<path>        単一リポ(ローカル)のメタデータを表示"
	@echo "make scan-github OWNER=<login>   GitHub の全リポ(Private含む/fork除外)を API 走査 (要 gh CLI)"
	@echo "make summary OWNER=<login>       案件サマリに集約 → output/career-feed.json"
	@echo "make link                        skill/ を ~/.claude/skills/ にシンボリックリンク"
	@echo "  (AUTHOR=<name> で関与コミット数を集計)"

scan:
	@SKILL_INV_AUTHOR="$(AUTHOR)" bash scanner/run-all.sh

scan-one:
	@bash scanner/scan.sh "$(REPO)" $(if $(AUTHOR),--author "$(AUTHOR)",)

scan-github:
	@bash scanner/run-all-github.sh "$(OWNER)" --token-user "$(OWNER)" $(if $(AUTHOR),--author "$(AUTHOR)",--author "$(OWNER)")

summary:
	@bash scanner/export-summary.sh --owner "$(OWNER)"

link:
	@ln -sfn "$(CURDIR)/skill" "$(HOME)/.claude/skills/skill-inventory" \
	  && echo "linked -> $(HOME)/.claude/skills/skill-inventory"
