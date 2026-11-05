NVIM ?= nvim

.PHONY: test contract fmt

test:
	$(NVIM) -n --clean -l tests/run.lua

# Talks to Claude Code; costs a few small API calls. Run manually.
contract:
	tests/contract/run.sh

fmt:
	stylua lua/ tests/ prototype/
