.PHONY: lint test

lint:
	shellcheck install-zrok.sh ddns-update.sh setup-gateway.sh

test: lint
	@if command -v bats >/dev/null 2>&1; then \
		bats tests/; \
	else \
		echo "bats not installed — skipping tests"; \
	fi
