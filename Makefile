NVIM ?= nvim

.PHONY: test contract handoff verify fmt

test:
	$(NVIM) -n --clean -l tests/run.lua

# Talks to Claude Code; costs a few small API calls. Run manually.
contract:
	tests/contract/run.sh

# End-to-end Ctrl+G handoff through vergil; also talks to Claude Code.
handoff:
	tests/contract/handoff.sh

# Both of the above, then record the Claude Code version they passed with
# (shown by :checkhealth vergil).
verify: contract handoff
	scripts/stamp-verified.sh

fmt:
	stylua lua/ plugin/ tests/
