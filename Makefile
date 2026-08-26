.PHONY: check test

check:
	@sh tests/smoke.sh

test: check
