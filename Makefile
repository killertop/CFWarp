.PHONY: check test integration

check:
	@sh tests/smoke.sh

test: check
	@python3 tests/regression.py
	@sh tests/runtime-regression.sh
	@sh tests/network-lock-regression.sh
	@sh tests/network-refcount-regression.sh
	@sh tests/install-refusal-regression.sh
	@sh tests/install-upgrade-regression.sh
	@sh tests/refresh-recovery-regression.sh

integration: test
	@sudo sh tests/network-regression.sh --live
	@sudo python3 tests/network-egress-regression.py --live
	@sudo sh tests/install-regression.sh --live
