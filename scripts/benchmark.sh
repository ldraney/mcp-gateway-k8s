#!/usr/bin/env bash
set -euo pipefail

# benchmark.sh — Run Pal-E benchmark suite via OpenClaw CLI in K8s
# Usage: bash scripts/benchmark.sh [--timeout 300] [--tests-file path] [--output-dir path] [--filter id]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_FILE="${SCRIPT_DIR}/benchmark-tests.json"
OUTPUT_DIR="results"
TIMEOUT=300
FILTER=""
NAMESPACE="openclaw"
POD_LABEL="app=openclaw-gateway"
AGENT="pal-e"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Run the Pal-E benchmark suite against the OpenClaw gateway pod.

Options:
  --timeout SEC       Per-test timeout in seconds (default: $TIMEOUT)
  --tests-file PATH   Path to test definitions JSON (default: scripts/benchmark-tests.json)
  --output-dir DIR    Directory for results (default: results/)
  --filter ID         Run only tests matching this ID substring
  -h, --help          Show this help
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --timeout)    TIMEOUT="$2"; shift 2 ;;
        --tests-file) TESTS_FILE="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --filter)     FILTER="$2"; shift 2 ;;
        -h|--help)    usage ;;
        *)            echo "Unknown option: $1"; usage ;;
    esac
done

# --- Prereq checks ---

check_prereqs() {
    local missing=()
    for cmd in kubectl jq uuidgen; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing required commands: ${missing[*]}" >&2
        exit 1
    fi

    if [[ ! -f "$TESTS_FILE" ]]; then
        echo "ERROR: Tests file not found: $TESTS_FILE" >&2
        exit 1
    fi

    POD=$(kubectl get pods -n "$NAMESPACE" -l "$POD_LABEL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -z "$POD" ]]; then
        echo "ERROR: No running pod with label $POD_LABEL in namespace $NAMESPACE" >&2
        exit 1
    fi
    echo "Using pod: $POD"
}

# --- Run a single test ---

run_test() {
    local id="$1" prompt="$2" test_dir="$3"
    local session_id
    session_id="$(uuidgen)"

    echo -n "  Running... "

    # Execute the CLI command inside the pod
    # Filter out plugin log lines (start with [) and stderr noise
    local raw_output
    raw_output=$(kubectl exec -n "$NAMESPACE" "$POD" -- \
        node openclaw.mjs agent \
        --agent "$AGENT" \
        --session-id "$session_id" \
        --message "$prompt" \
        --json \
        --timeout "$TIMEOUT" \
        2>/dev/null | grep -v '^\[' || true)

    # Save raw output
    echo "$raw_output" > "$test_dir/raw.json"
    echo "$session_id" > "$test_dir/session-id"

    # Extract response text from JSON
    local response_text=""
    local duration_ms="N/A"

    if echo "$raw_output" | jq -e '.result' &>/dev/null; then
        response_text=$(echo "$raw_output" | jq -r '.result.payloads[0].text // ""' 2>/dev/null || echo "")
        duration_ms=$(echo "$raw_output" | jq -r '.result.meta.durationMs // "N/A"' 2>/dev/null || echo "N/A")
    else
        # Fallback: try to extract text from any valid JSON
        response_text=$(echo "$raw_output" | jq -r '.text // .message // .content // ""' 2>/dev/null || echo "$raw_output")
    fi

    echo "$response_text" > "$test_dir/response.txt"

    # Fetch session JSONL from the pod
    # Agent ID for pal-e is determined by OpenClaw's agent config
    local agent_id
    agent_id=$(kubectl exec -n "$NAMESPACE" "$POD" -- \
        node openclaw.mjs agent --json 2>/dev/null \
        | grep -v '^\[' \
        | jq -r '.[] | select(.name == "'"$AGENT"'") | .id // empty' 2>/dev/null || echo "")

    local jsonl_content=""
    if [[ -n "$agent_id" ]]; then
        local session_path="/home/node/.openclaw/agents/${agent_id}/sessions/${session_id}.jsonl"
        jsonl_content=$(kubectl exec -n "$NAMESPACE" "$POD" -- cat "$session_path" 2>/dev/null || echo "")
    fi

    if [[ -n "$jsonl_content" ]]; then
        echo "$jsonl_content" > "$test_dir/session.jsonl"
    fi

    # --- Scoring ---

    # Check for tool_use in session JSONL (assistant messages with tool_use content blocks)
    local tool_called="false"
    local tool_name=""
    if [[ -n "$jsonl_content" ]]; then
        tool_name=$(echo "$jsonl_content" \
            | jq -r 'select(.role == "assistant") | .content[]? | select(.type == "tool_use") | .name' 2>/dev/null \
            | head -1 || echo "")
        if [[ -n "$tool_name" ]]; then
            tool_called="true"
        fi
    fi

    # Check for sessions_spawn (agent routing)
    local spawn_detected="false"
    local spawned_agent=""
    if [[ -n "$jsonl_content" ]]; then
        spawned_agent=$(echo "$jsonl_content" \
            | jq -r 'select(.role == "assistant") | .content[]? | select(.type == "tool_use" and .name == "sessions_spawn") | .input.agentId // .input.agent // ""' 2>/dev/null \
            | head -1 || echo "")
        if [[ -n "$spawned_agent" ]]; then
            spawn_detected="true"
        fi
    fi

    # Quality checks
    local no_xml_leak="true"
    if echo "$response_text" | grep -qiE '<工具>|</工具>|<tool>|</tool>|<tool_call>|</tool_call>'; then
        no_xml_leak="false"
    fi

    local no_empty="true"
    if [[ -z "$response_text" || "$response_text" == "null" ]]; then
        no_empty="false"
    fi

    local no_json_leak="true"
    if echo "$response_text" | grep -qE '\{"name":\s*"[^"]+",\s*"(arguments|input)"'; then
        no_json_leak="false"
    fi

    # Write score file
    jq -n \
        --arg id "$id" \
        --arg duration "$duration_ms" \
        --arg tool_called "$tool_called" \
        --arg tool_name "$tool_name" \
        --arg spawn_detected "$spawn_detected" \
        --arg spawned_agent "$spawned_agent" \
        --arg no_xml_leak "$no_xml_leak" \
        --arg no_empty "$no_empty" \
        --arg no_json_leak "$no_json_leak" \
        --arg response_preview "${response_text:0:100}" \
        '{
            id: $id,
            duration_ms: $duration,
            tool_called: ($tool_called == "true"),
            tool_name: ($tool_name // null),
            spawn_detected: ($spawn_detected == "true"),
            spawned_agent: ($spawned_agent // null),
            no_xml_leak: ($no_xml_leak == "true"),
            no_empty: ($no_empty == "true"),
            no_json_leak: ($no_json_leak == "true"),
            response_preview: $response_preview
        }' > "$test_dir/score.json"

    echo "done (${duration_ms}ms)"
}

# --- Score a test against expectations ---

score_test() {
    local test_json="$1" score_file="$2"

    local expect_spawn expect_agent expect_tool
    expect_spawn=$(echo "$test_json" | jq -r '.expect_spawn')
    expect_agent=$(echo "$test_json" | jq -r '.expect_agent // ""')
    expect_tool=$(echo "$test_json" | jq -r '.expect_tool // ""')

    local spawn_detected spawned_agent tool_called tool_name
    spawn_detected=$(jq -r '.spawn_detected' "$score_file")
    spawned_agent=$(jq -r '.spawned_agent // ""' "$score_file")
    tool_called=$(jq -r '.tool_called' "$score_file")
    tool_name=$(jq -r '.tool_name // ""' "$score_file")

    # Routing score: did spawn match expectation?
    local routing_pass="false"
    if [[ "$expect_spawn" == "true" ]]; then
        if [[ "$spawn_detected" == "true" ]]; then
            # Check if agent matches (partial match for flexibility)
            if [[ -z "$expect_agent" || "$spawned_agent" == *"$expect_agent"* ]]; then
                routing_pass="true"
            fi
        fi
    else
        # Expected no spawn
        if [[ "$spawn_detected" == "false" ]]; then
            routing_pass="true"
        fi
    fi

    # Tool execution score
    local tool_pass="false"
    if [[ "$expect_spawn" == "true" ]]; then
        if [[ "$tool_called" == "true" ]]; then
            if [[ -z "$expect_tool" || "$tool_name" == *"$expect_tool"* ]]; then
                tool_pass="true"
            fi
        fi
    else
        # No tool expected — pass if no tool called
        tool_pass="true"
    fi

    # Quality score
    local quality_pass="true"
    local no_xml no_empty no_json
    no_xml=$(jq -r '.no_xml_leak' "$score_file")
    no_empty=$(jq -r '.no_empty' "$score_file")
    no_json=$(jq -r '.no_json_leak' "$score_file")
    if [[ "$no_xml" != "true" || "$no_empty" != "true" || "$no_json" != "true" ]]; then
        quality_pass="false"
    fi

    echo "${routing_pass}|${tool_pass}|${quality_pass}"
}

# --- Build scorecard ---

build_scorecard() {
    local results_dir="$1"
    local scorecard="$results_dir/scorecard.md"
    local timestamp
    timestamp=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

    local total=0 routing_ok=0 tool_ok=0 quality_ok=0

    {
        echo "# Pal-E Benchmark Scorecard"
        echo ""
        echo "**Date**: $timestamp"
        echo "**Agent**: $AGENT"
        echo "**Timeout**: ${TIMEOUT}s per test"
        echo ""
        echo "## Results"
        echo ""
        echo "| ID | Category | Routing | Tool Exec | Quality | Duration | Response Preview |"
        echo "|:---|:---------|:-------:|:---------:|:-------:|:--------:|:-----------------|"
    } > "$scorecard"

    # Read test definitions
    local test_count
    test_count=$(jq length "$TESTS_FILE")

    for i in $(seq 0 $((test_count - 1))); do
        local test_json
        test_json=$(jq ".[$i]" "$TESTS_FILE")
        local id category
        id=$(echo "$test_json" | jq -r '.id')
        category=$(echo "$test_json" | jq -r '.category')

        # Skip filtered tests
        if [[ -n "$FILTER" && "$id" != *"$FILTER"* ]]; then
            continue
        fi

        local test_dir="$results_dir/$id"
        if [[ ! -f "$test_dir/score.json" ]]; then
            continue
        fi

        local scores
        scores=$(score_test "$test_json" "$test_dir/score.json")
        local routing tool quality
        routing=$(echo "$scores" | cut -d'|' -f1)
        tool=$(echo "$scores" | cut -d'|' -f2)
        quality=$(echo "$scores" | cut -d'|' -f3)

        local duration response_preview
        duration=$(jq -r '.duration_ms' "$test_dir/score.json")
        response_preview=$(jq -r '.response_preview' "$test_dir/score.json" | tr '|' '/' | tr '\n' ' ' | head -c 60)

        local r_icon t_icon q_icon
        r_icon=$( [[ "$routing" == "true" ]] && echo "PASS" || echo "FAIL" )
        t_icon=$( [[ "$tool" == "true" ]] && echo "PASS" || echo "FAIL" )
        q_icon=$( [[ "$quality" == "true" ]] && echo "PASS" || echo "FAIL" )

        echo "| $id | $category | $r_icon | $t_icon | $q_icon | ${duration}ms | ${response_preview}... |" >> "$scorecard"

        total=$((total + 1))
        [[ "$routing" == "true" ]] && routing_ok=$((routing_ok + 1))
        [[ "$tool" == "true" ]] && tool_ok=$((tool_ok + 1))
        [[ "$quality" == "true" ]] && quality_ok=$((quality_ok + 1))
    done

    {
        echo ""
        echo "## Summary"
        echo ""
        if [[ $total -gt 0 ]]; then
            local routing_pct tool_pct quality_pct
            routing_pct=$((routing_ok * 100 / total))
            tool_pct=$((tool_ok * 100 / total))
            quality_pct=$((quality_ok * 100 / total))
            echo "| Metric | Score |"
            echo "|:-------|:------|"
            echo "| Routing accuracy | ${routing_ok}/${total} (${routing_pct}%) |"
            echo "| Tool execution | ${tool_ok}/${total} (${tool_pct}%) |"
            echo "| Response quality | ${quality_ok}/${total} (${quality_pct}%) |"
            echo "| Total tests | ${total} |"
        else
            echo "No tests executed."
        fi
    } >> "$scorecard"

    echo ""
    echo "===== SCORECARD ====="
    cat "$scorecard"
}

# --- Main ---

main() {
    echo "Pal-E Benchmark Harness"
    echo "======================"
    echo ""

    check_prereqs

    mkdir -p "$OUTPUT_DIR"

    local test_count
    test_count=$(jq length "$TESTS_FILE")
    echo "Loaded $test_count test cases from $TESTS_FILE"
    echo ""

    for i in $(seq 0 $((test_count - 1))); do
        local test_json
        test_json=$(jq ".[$i]" "$TESTS_FILE")
        local id prompt category
        id=$(echo "$test_json" | jq -r '.id')
        prompt=$(echo "$test_json" | jq -r '.prompt')
        category=$(echo "$test_json" | jq -r '.category')

        # Apply filter
        if [[ -n "$FILTER" && "$id" != *"$FILTER"* ]]; then
            continue
        fi

        local test_dir="$OUTPUT_DIR/$id"
        mkdir -p "$test_dir"

        echo "[$((i + 1))/$test_count] $id ($category): \"$prompt\""
        run_test "$id" "$prompt" "$test_dir"
    done

    echo ""
    build_scorecard "$OUTPUT_DIR"
}

main
