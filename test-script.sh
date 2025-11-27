#!/bin/bash
# Test script for deploy-operator.sh
# This script can be run locally or in CI to test various scenarios

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASSED=0
FAILED=0

test_case() {
    local test_name="$1"
    local command="$2"
    local expected_pattern="${3:-}"
    
    echo -e "\n${YELLOW}Testing: $test_name${NC}"
    echo "Command: $command"
    
    if eval "$command" 2>&1 | grep -q "${expected_pattern:-.}"; then
        echo -e "${GREEN}✓ PASSED${NC}"
        ((PASSED++))
        return 0
    else
        echo -e "${RED}✗ FAILED${NC}"
        ((FAILED++))
        return 1
    fi
}

test_case_exact() {
    local test_name="$1"
    local command="$2"
    local expected_output="${3:-}"
    
    echo -e "\n${YELLOW}Testing: $test_name${NC}"
    echo "Command: $command"
    
    local actual_output=$(eval "$command" 2>&1 || true)
    if echo "$actual_output" | grep -qF "$expected_output"; then
        echo -e "${GREEN}✓ PASSED${NC}"
        ((PASSED++))
        return 0
    else
        echo -e "${RED}✗ FAILED${NC}"
        echo "Expected: $expected_output"
        echo "Got: $actual_output"
        ((FAILED++))
        return 1
    fi
}

echo "=========================================="
echo "Testing deploy-operator.sh"
echo "=========================================="

# Test 1: Missing arguments
test_case "Missing arguments" \
    "./deploy-operator.sh 2>&1" \
    "Provide either"

# Test 2: Both --operator and --fbc-tag
test_case "Both --operator and --fbc-tag" \
    "./deploy-operator.sh --operator sriov --fbc-tag test 2>&1" \
    "not both"

# Test 3: Invalid operator
test_case "Invalid operator" \
    "./deploy-operator.sh --operator invalid-operator 2>&1" \
    "Invalid operator"

# Test 4: Valid operator (skip deployment)
test_case "Valid operator (skip deployment)" \
    "KONFLUX_SKIP_DEPLOYMENT=true ./deploy-operator.sh --operator sriov 2>&1" \
    "Skipping deployment"

# Test 5: Multiple operators (skip deployment)
test_case "Multiple operators (skip deployment)" \
    "KONFLUX_SKIP_DEPLOYMENT=true ./deploy-operator.sh --operator sriov,metallb 2>&1" \
    "Skipping deployment"

# Test 6: FBC tag (skip deployment)
test_case "FBC tag (skip deployment)" \
    "KONFLUX_SKIP_DEPLOYMENT=true ./deploy-operator.sh --fbc-tag ocp__4.15__metallb-rhel9-operator 2>&1" \
    "Skipping deployment"

# Test 7: KONFLUX_SKIP_DEPLOYMENT
test_case "KONFLUX_SKIP_DEPLOYMENT=true" \
    "KONFLUX_SKIP_DEPLOYMENT=true ./deploy-operator.sh --operator sriov 2>&1" \
    "Skipping deployment"

# Test 8: KONFLUX_DEPLOY_CATALOG_SOURCE=false
test_case "KONFLUX_DEPLOY_CATALOG_SOURCE=false" \
    "KONFLUX_SKIP_DEPLOYMENT=true KONFLUX_DEPLOY_CATALOG_SOURCE=false KONFLUX_DEPLOY_OPERATOR=false ./deploy-operator.sh --operator sriov 2>&1" \
    "Skipping deployment"

# Test 9: Script is executable
test_case "Script is executable" \
    "test -x ./deploy-operator.sh" \
    ""

# Test 10: Script has shebang
test_case "Script has shebang" \
    "head -1 ./deploy-operator.sh | grep -q '^#!/bin/bash'" \
    ""

echo ""
echo "=========================================="
echo "Test Summary"
echo "=========================================="
echo -e "${GREEN}Passed: $PASSED${NC}"
echo -e "${RED}Failed: $FAILED${NC}"
echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi

