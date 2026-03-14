#!/bin/bash
set -e

CI_MODE=${CI:-false}

if [ "$CI_MODE" = "true" ]; then
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
else
    RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' BLUE='\033[0;34m' NC='\033[0m'
fi

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

CONTAINER="slurm"

print_header() { echo -e "${BLUE}================================${NC}\n${BLUE}$1${NC}\n${BLUE}================================${NC}"; }
print_test() { echo -e "${YELLOW}[TEST]${NC} $1"; TESTS_RUN=$((TESTS_RUN + 1)); }
print_pass() { echo -e "${GREEN}[PASS]${NC} $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
print_fail() { echo -e "${RED}[FAIL]${NC} $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }

test_container_running() {
    print_test "Container is running..."
    if docker compose ps "$CONTAINER" 2>/dev/null | grep -q "Up"; then
        print_pass "Container is running"
    else
        print_fail "Container is not running"
        return 1
    fi
}

test_munge_auth() {
    print_test "MUNGE authentication..."
    if docker exec "$CONTAINER" bash -c "munge -n | unmunge" >/dev/null 2>&1; then
        print_pass "MUNGE authentication works"
    else
        print_fail "MUNGE authentication failed"
        return 1
    fi
}

test_mysql_connection() {
    print_test "MySQL database connection..."
    if docker exec "$CONTAINER" bash -c "echo 'SELECT 1' | mysql -u\${MYSQL_USER} -p\${MYSQL_PASSWORD} 2>/dev/null" >/dev/null; then
        print_pass "MySQL connection successful"
    else
        print_fail "MySQL connection failed"
        return 1
    fi
}

test_slurmdbd() {
    print_test "slurmdbd daemon..."
    if docker exec "$CONTAINER" sacctmgr list cluster -n 2>/dev/null | grep -q "linux"; then
        print_pass "slurmdbd responding, cluster registered"
    else
        print_fail "slurmdbd not responding or cluster not registered"
        return 1
    fi
}

test_slurmctld() {
    print_test "slurmctld daemon..."
    if docker exec "$CONTAINER" scontrol ping >/dev/null 2>&1; then
        print_pass "slurmctld responding"
    else
        print_fail "slurmctld not responding"
        return 1
    fi
}

test_compute_nodes() {
    print_test "Compute nodes availability..."
    NODE_COUNT=$(docker exec "$CONTAINER" sinfo -N -h 2>/dev/null | wc -l)
    if [ "$NODE_COUNT" -eq 3 ]; then
        print_pass "3 compute nodes available"
    else
        print_fail "Expected 3 compute nodes, found $NODE_COUNT"
        return 1
    fi
}

test_nodes_idle() {
    print_test "Compute nodes idle state..."
    IDLE_NODES=$(docker exec "$CONTAINER" sinfo -h -o "%T" 2>/dev/null | grep -c "idle" || echo "0")
    if [ "$IDLE_NODES" -ge 1 ]; then
        print_pass "Nodes in idle state ($IDLE_NODES partitions)"
    else
        print_fail "No nodes in idle state"
        docker exec "$CONTAINER" sinfo 2>/dev/null || true
        return 1
    fi
}

test_partition() {
    print_test "Partition configuration..."
    if docker exec "$CONTAINER" sinfo -h 2>/dev/null | grep -q "normal"; then
        print_pass "Partition 'normal' exists"
    else
        print_fail "Partition 'normal' not found"
        return 1
    fi
}

test_job_submission() {
    print_test "Job submission..."
    JOB_ID=$(docker exec "$CONTAINER" bash -c "cd /data && sbatch --wrap='hostname' 2>&1" | sed -n 's/.*Submitted batch job \([0-9][0-9]*\).*/\1/p')
    if [ -n "$JOB_ID" ]; then
        print_info "  Job ID: $JOB_ID"
        for i in $(seq 1 30); do
            JOB_STATE=$(docker exec "$CONTAINER" squeue -j "$JOB_ID" -h -o "%T" 2>/dev/null || echo "COMPLETED")
            [ "$JOB_STATE" = "COMPLETED" ] || [ -z "$JOB_STATE" ] && break
            sleep 1
        done
        print_pass "Job submitted (ID: $JOB_ID)"
    else
        print_fail "Job submission failed"
        return 1
    fi
}

test_job_execution() {
    print_test "Job execution and output..."
    OUTPUT=$(docker exec "$CONTAINER" bash -c "cd /data && sbatch --wrap='echo SUCCESS_TEST_\$SLURM_JOB_ID' --wait 2>&1 && sleep 2 && cat slurm-*.out | grep SUCCESS_TEST" 2>/dev/null || echo "")
    if echo "$OUTPUT" | grep -q "SUCCESS_TEST"; then
        print_pass "Job executed with output"
    else
        print_fail "Job execution failed"
        return 1
    fi
}

test_job_accounting() {
    print_test "Job accounting..."
    if docker exec "$CONTAINER" sacct -n --format=JobID -X 2>/dev/null | grep -q "[0-9]"; then
        print_pass "Job accounting works"
    else
        print_fail "No jobs in accounting"
        return 1
    fi
}

test_resource_tracking() {
    print_test "Resource tracking (jobacct_gather/linux)..."
    JOB_OUTPUT=$(docker exec "$CONTAINER" bash -c "sbatch --wrap='sleep 8' --wait" 2>&1)
    JOB_ID=$(echo "$JOB_OUTPUT" | sed -n 's/.*Submitted batch job \([0-9][0-9]*\).*/\1/p')
    if [ -z "$JOB_ID" ]; then
        print_fail "Could not submit resource tracking job"
        return 1
    fi
    sleep 3
    MAX_RSS=$(docker exec "$CONTAINER" sacct -j "$JOB_ID.batch" -n -o MaxRSS 2>/dev/null | tr -d '[:space:]')
    if [ -n "$MAX_RSS" ] && [ "$MAX_RSS" != "0" ]; then
        print_pass "Resource tracking works (MaxRSS: $MAX_RSS)"
    else
        print_fail "No resource usage recorded (MaxRSS: '$MAX_RSS')"
        docker exec "$CONTAINER" sacct -j "$JOB_ID" -o JobID,MaxRSS,State 2>/dev/null || true
        return 1
    fi
}

test_multi_node_job() {
    print_test "Multi-node job allocation..."
    JOB_OUTPUT=$(docker exec "$CONTAINER" bash -c "srun -N 2 hostname" 2>&1 || echo "FAILED")
    OUTPUT_LINES=$(echo "$JOB_OUTPUT" | grep -v "^$" | wc -l)
    if [ "$OUTPUT_LINES" -eq 2 ]; then
        print_pass "Multi-node job ran on 2 nodes"
    else
        print_fail "Multi-node job failed"
        print_info "  Output: $JOB_OUTPUT"
        return 1
    fi
}

test_rest_api() {
    print_test "REST API (slurmrestd)..."

    # Auto-detect API version from Slurm version
    SLURM_VER=$(docker exec "$CONTAINER" scontrol version 2>/dev/null | head -1 | grep -oP '\d+\.\d+' || echo "25.11")
    case "$SLURM_VER" in
        24.11) API_VERSION="v0.0.41" ;;
        25.05) API_VERSION="v0.0.42" ;;
        *)     API_VERSION="v0.0.42" ;;
    esac

    if docker exec "$CONTAINER" curl -sf --unix-socket /var/run/slurmrestd/slurmrestd.socket \
        "http://localhost/slurm/${API_VERSION}/ping" >/dev/null 2>&1; then
        print_pass "REST API responding (${API_VERSION})"
    else
        print_fail "REST API not responding"
        return 1
    fi
}

main() {
    if [ -f .env ]; then
        SLURM_VERSION=$(grep SLURM_VERSION .env | cut -d= -f2)
    else
        SLURM_VERSION=$(docker exec "$CONTAINER" scontrol version 2>/dev/null | head -1 | grep -oP '[\d.]+' || echo "unknown")
    fi

    print_header "Slurm Docker Test Suite (v${SLURM_VERSION})"
    echo ""

    test_container_running || true
    test_munge_auth || true
    test_mysql_connection || true
    test_slurmdbd || true
    test_slurmctld || true
    test_compute_nodes || true
    test_nodes_idle || true
    test_partition || true
    test_job_submission || true
    test_job_execution || true
    test_job_accounting || true
    test_resource_tracking || true
    test_multi_node_job || true
    test_rest_api || true

    echo ""
    print_header "Test Summary"
    echo -e "Run: ${BLUE}$TESTS_RUN${NC}  Passed: ${GREEN}$TESTS_PASSED${NC}  Failed: ${RED}$TESTS_FAILED${NC}"
    echo ""

    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "${GREEN}All tests passed${NC}"
        [ "$CI_MODE" = "true" ] && echo "::notice title=Tests::All $TESTS_RUN tests passed"
        exit 0
    else
        echo -e "${RED}$TESTS_FAILED test(s) failed${NC}"
        [ "$CI_MODE" = "true" ] && echo "::error title=Tests::$TESTS_FAILED/$TESTS_RUN failed"
        exit 1
    fi
}

main
