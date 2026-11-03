PYTHON ?= python3
BASH ?= bash

.PHONY: test check-shell test-shell test-python

test: check-shell test-shell test-python

check-shell:
	@set -eu; for file in scripts/lib/*.sh tests/unit/*.sh tests/integration/*.sh tests/quick/*.sh; do $(BASH) -n "$$file"; done

test-shell:
	@set -eu; for test in tests/unit/test_*.sh; do $(BASH) "$$test"; done

test-python:
	$(PYTHON) -m unittest discover -s tests/unit -p 'test_*.py'
