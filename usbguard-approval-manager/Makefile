PYTHON ?= python3
BASH ?= bash

.PHONY: test check-shell test-shell test-python integration

test: check-shell test-shell test-python

check-shell:
	@set -eu; for file in deploy.sh deploy-lib.sh deploy-uninstall.sh validate_all.sh scripts/*.sh scripts/lib/*.sh tests/unit/*.sh tests/integration/*.sh tests/quick/*.sh; do $(BASH) -n "$$file"; done

test-shell:
	@set -eu; for test in tests/unit/test_*.sh; do $(BASH) "$$test"; done

test-python:
	$(PYTHON) -m unittest discover -s tests/unit -p 'test_*.py'

integration:
	$(BASH) tests/integration/run_integration_tests.sh
