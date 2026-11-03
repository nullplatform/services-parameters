.PHONY: test test-all test-unit test-worker test-bash test-tofu test-integration help

# Default test target - shows available options
test:
	@echo "Usage: make test-<level>"
	@echo ""
	@echo "Available test levels:"
	@echo "  make test-all          Run all tests"
	@echo "  make test-unit         Run the worker's checks and the bash package's BATS tests"
	@echo "  make test-worker       Type-check, lint, format-check and test the worker (bun)"
	@echo "  make test-bash         Run the bash package's BATS tests"
	@echo "  make test-tofu         Run OpenTofu tests"
	@echo "  make test-integration  Run integration tests"

# Run all tests
test-all: test-unit test-tofu test-integration

# Both runtimes' unit tests.
test-unit: test-worker test-bash

# The worker: type-check, lint, format check, and every provider against fakes of its backend, no network.
test-worker:
	@bun install --frozen-lockfile
	@bun run check

# The bash package: its scripts against mocked commands. The assertions come from
# the testing/ submodule (git submodule update --init --recursive).
test-bash:
	@bats -r parameters/tests

# Run OpenTofu tests (provider install specs) via the shared runner
test-tofu:
ifdef MODULE
	@./testing/run_tofu_tests.sh $(MODULE)
else
	@./testing/run_tofu_tests.sh
endif

# Run integration tests via the shared runner
test-integration:
ifdef MODULE
	@./testing/run_integration_tests.sh $(MODULE) $(if $(VERBOSE),-v)
else
	@./testing/run_integration_tests.sh $(if $(VERBOSE),-v)
endif

# Help
help:
	@echo "Test targets:"
	@echo "  test              Show available test options"
	@echo "  test-all          Run all tests"
	@echo "  test-unit         Run the worker's checks and the bash package's BATS tests"
	@echo "  test-worker       Type-check, lint, format-check and test the worker"
	@echo "  test-bash         Run the bash package's BATS tests"
	@echo "  test-tofu         Run OpenTofu tests"
	@echo "  test-integration  Run integration tests"
	@echo ""
	@echo "Options:"
	@echo "  MODULE=<name>     Run tofu/integration tests for a specific module"
	@echo "  VERBOSE=1         Show output of passing tests (integration tests only)"
