.PHONY: test test-all test-unit test-tofu test-integration help

# Default test target - shows available options
test:
	@echo "Usage: make test-<level>"
	@echo ""
	@echo "Available test levels:"
	@echo "  make test-all          Run all tests"
	@echo "  make test-unit         Run the worker's tests (bun) and type-check"
	@echo "  make test-tofu         Run OpenTofu tests"
	@echo "  make test-integration  Run integration tests"

# Run all tests
test-all: test-unit test-tofu test-integration

# The worker's tests: every provider against fakes of its backend, no network.
test-unit:
	@bun install --frozen-lockfile
	@bunx tsc --noEmit -p .
	@bun test

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
	@echo "  test-unit         Run the worker's tests and type-check"
	@echo "  test-tofu         Run OpenTofu tests"
	@echo "  test-integration  Run integration tests"
	@echo ""
	@echo "Options:"
	@echo "  MODULE=<name>     Run tofu/integration tests for a specific module"
	@echo "  VERBOSE=1         Show output of passing tests (integration tests only)"
