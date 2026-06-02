#!/bin/bash
# Scribeflow Daily Agent Runner
# Usage: ./run_agent.sh [--no-commit]

set -euo pipefail

PROJECT_DIR="/Users/jaskaransingh/Projects/prev/Scribeflow"
AGENT_DIR="$PROJECT_DIR/.agent"
LOG_DIR="$AGENT_DIR/logs"
PROMPT_FILE="$AGENT_DIR/prompts/daily_agent_prompt.md"
DATE=$(date +%Y-%m-%d)
TIME=$(date +%H%M)
LOG_FILE="$LOG_DIR/${DATE}_${TIME}.md"
NO_COMMIT=false

for arg in "$@"; do
    case $arg in
        --no-commit) NO_COMMIT=true ;;
    esac
done

mkdir -p "$LOG_DIR"

cd "$PROJECT_DIR"

echo "=== Scribeflow Agent Run: $DATE $TIME ==="
echo "Project: $PROJECT_DIR"
echo "Prompt: $PROMPT_FILE"
echo "Log: $LOG_FILE"
echo ""

export PATH="/Users/jaskaransingh/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

if ! command -v claude &> /dev/null; then
    echo "Error: claude CLI not found. Install Claude Code first."
    exit 1
fi

if [ ! -f "$PROMPT_FILE" ]; then
    echo "Error: Prompt file not found at $PROMPT_FILE"
    exit 1
fi

PROMPT=$(cat "$PROMPT_FILE")

echo "Starting Claude Code agent..."
echo ""

claude -p "$PROMPT" --output-format text 2>&1 | tee "$LOG_FILE"

AGENT_EXIT=$?

if [ $AGENT_EXIT -ne 0 ]; then
    echo ""
    echo "Agent exited with code $AGENT_EXIT"
fi

# Auto-commit if files changed
if [ "$NO_COMMIT" = false ]; then
    cd "$PROJECT_DIR"
    if [ -n "$(git status --porcelain)" ]; then
        echo ""
        echo "=== Changes detected, committing ==="
        git add -A
        git commit -m "agent($DATE): daily improvement

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
        echo "Committed."
    else
        echo ""
        echo "No changes to commit."
    fi
fi

echo ""
echo "=== Agent run complete ==="
echo "Log saved: $LOG_FILE"
