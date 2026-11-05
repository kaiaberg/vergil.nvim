NVIM ?= nvim

.PHONY: test contract handoff fmt

test:
	$(NVIM) -n --clean -l tests/run.lua

# Talks to Claude Code; costs a few small API calls. Run manually.
contract:
	tests/contract/run.sh

# End-to-end Ctrl+G handoff through vergil; also talks to Claude Code.
handoff:
	tests/contract/handoff.sh

fmt:
	stylua lua/ tests/ prototype/
