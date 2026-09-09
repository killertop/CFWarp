.PHONY: check test integration

check:
	@sh tests/smoke.sh

test: check
	@python3 tests/regression.py
	@sh tests/runtime-regression.sh

integration: test
	@sudo sh tests/network-regression.sh --live
	@sudo sh tests/install-regression.sh --live
