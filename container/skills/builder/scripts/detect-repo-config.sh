#!/bin/bash

# Repository Configuration Detection Script
# Automatically detects package manager, monorepo setup, changesets, and available scripts

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration variables (will be exported)
PACKAGE_MANAGER=""
HAS_CHANGESETS=false
IS_MONOREPO=false
IS_JAVASCRIPT_PROJECT=false
MONOREPO_TOOL=""
CURRENT_PACKAGE=""
REPO_ROOT=""
SCRIPTS_AVAILABLE=""
BUILD_SCRIPT=""
LINT_SCRIPT=""
TEST_SCRIPT=""
FORMAT_SCRIPT=""

# Functions
debug_log() {
    if [ "${DEBUG:-false}" = "true" ]; then
        echo -e "${CYAN}[DEBUG] $1${NC}" >&2
    fi
}

find_repo_root() {
    local dir="$PWD"
    while [ "$dir" != "/" ]; do
        if [ -f "$dir/package.json" ] || [ -d "$dir/.git" ]; then
            REPO_ROOT="$dir"
            debug_log "Found repo root: $REPO_ROOT"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    REPO_ROOT="$PWD"
    debug_log "Using current directory as repo root: $REPO_ROOT"
    return 0
}

detect_package_manager() {
    debug_log "Detecting package manager..."

    # Check for lock files in repo root
    if [ -f "$REPO_ROOT/pnpm-lock.yaml" ]; then
        PACKAGE_MANAGER="pnpm"
    elif [ -f "$REPO_ROOT/yarn.lock" ]; then
        PACKAGE_MANAGER="yarn"
    elif [ -f "$REPO_ROOT/package-lock.json" ]; then
        PACKAGE_MANAGER="npm"
    elif [ -f "$REPO_ROOT/package.json" ]; then
        # Check packageManager field in package.json
        local pkg_mgr=$(grep -o '"packageManager":[[:space:]]*"[^"]*"' "$REPO_ROOT/package.json" 2>/dev/null | cut -d'"' -f4 | cut -d'@' -f1)
        if [ -n "$pkg_mgr" ]; then
            PACKAGE_MANAGER="$pkg_mgr"
        else
            # Default to npm if package.json exists but no lock file
            PACKAGE_MANAGER="npm"
        fi
    fi

    debug_log "Detected package manager: $PACKAGE_MANAGER"
}

check_javascript_project() {
    debug_log "Checking for JavaScript/TypeScript project..."

    if [ ! -f "$REPO_ROOT/package.json" ]; then
        debug_log "Not a JavaScript/TypeScript project - skipping validation"
        return 1  # false - not a JS project
    fi

    debug_log "JavaScript/TypeScript project detected"
    return 0  # true - is a JS project
}

detect_changesets() {
    debug_log "Checking for changesets..."

    if [ -f "$REPO_ROOT/.changeset/config.json" ]; then
        HAS_CHANGESETS=true
        debug_log "Changesets configuration found"
    else
        debug_log "No changesets configuration"
    fi
}

detect_monorepo() {
    debug_log "Detecting monorepo setup..."

    # Check for pnpm workspace
    if [ -f "$REPO_ROOT/pnpm-workspace.yaml" ]; then
        IS_MONOREPO=true
        MONOREPO_TOOL="pnpm-workspace"
        debug_log "pnpm workspace detected"
        return
    fi

    # Check for yarn workspaces
    if [ -f "$REPO_ROOT/package.json" ]; then
        if grep -q '"workspaces"' "$REPO_ROOT/package.json" 2>/dev/null; then
            IS_MONOREPO=true
            MONOREPO_TOOL="workspaces"
            debug_log "Workspaces configuration detected"
        fi

        # Check for specific monorepo tools
        if [ -f "$REPO_ROOT/turbo.json" ]; then
            MONOREPO_TOOL="${MONOREPO_TOOL:+$MONOREPO_TOOL+}turbo"
            debug_log "Turbo detected"
        fi

        if [ -f "$REPO_ROOT/lerna.json" ]; then
            IS_MONOREPO=true
            MONOREPO_TOOL="${MONOREPO_TOOL:+$MONOREPO_TOOL+}lerna"
            debug_log "Lerna detected"
        fi

        if [ -f "$REPO_ROOT/nx.json" ]; then
            IS_MONOREPO=true
            MONOREPO_TOOL="${MONOREPO_TOOL:+$MONOREPO_TOOL+}nx"
            debug_log "Nx detected"
        fi
    fi
}

detect_current_package() {
    debug_log "Detecting current package..."

    if [ "$IS_MONOREPO" = "false" ]; then
        CURRENT_PACKAGE="root"
        return
    fi

    # Check if we're in a subdirectory with its own package.json
    local current_dir="$PWD"
    while [ "$current_dir" != "$REPO_ROOT" ] && [ "$current_dir" != "/" ]; do
        if [ -f "$current_dir/package.json" ] && [ "$current_dir" != "$REPO_ROOT" ]; then
            # Extract package name from package.json
            CURRENT_PACKAGE=$(grep -o '"name":[[:space:]]*"[^"]*"' "$current_dir/package.json" 2>/dev/null | head -1 | cut -d'"' -f4)
            if [ -z "$CURRENT_PACKAGE" ]; then
                # Fallback to directory name
                CURRENT_PACKAGE=$(basename "$current_dir")
            fi
            debug_log "Current package: $CURRENT_PACKAGE"
            return
        fi
        current_dir="$(dirname "$current_dir")"
    done

    CURRENT_PACKAGE="root"
    debug_log "At monorepo root"
}

detect_scripts() {
    debug_log "Detecting available scripts..."

    if [ ! -f "$REPO_ROOT/package.json" ]; then
        debug_log "No package.json found"
        return
    fi

    # Extract scripts section from package.json
    local scripts=$(sed -n '/"scripts":/,/^[[:space:]]*}/p' "$REPO_ROOT/package.json" 2>/dev/null)

    # Detect build script
    if echo "$scripts" | grep -q '"build"' 2>/dev/null; then
        BUILD_SCRIPT="build"
    elif echo "$scripts" | grep -q '"build:all"' 2>/dev/null; then
        BUILD_SCRIPT="build:all"
    elif echo "$scripts" | grep -q '"compile"' 2>/dev/null; then
        BUILD_SCRIPT="compile"
    fi

    # Detect lint script
    if echo "$scripts" | grep -q '"lint"' 2>/dev/null; then
        LINT_SCRIPT="lint"
    elif echo "$scripts" | grep -q '"lint:all"' 2>/dev/null; then
        LINT_SCRIPT="lint:all"
    elif echo "$scripts" | grep -q '"eslint"' 2>/dev/null; then
        LINT_SCRIPT="eslint"
    fi

    # Detect test script
    if echo "$scripts" | grep -q '"test"' 2>/dev/null; then
        TEST_SCRIPT="test"
    elif echo "$scripts" | grep -q '"test:all"' 2>/dev/null; then
        TEST_SCRIPT="test:all"
    elif echo "$scripts" | grep -q '"test:unit"' 2>/dev/null; then
        TEST_SCRIPT="test:unit"
    fi

    # Detect format script
    if echo "$scripts" | grep -q '"format"' 2>/dev/null; then
        FORMAT_SCRIPT="format"
    elif echo "$scripts" | grep -q '"prettier"' 2>/dev/null; then
        FORMAT_SCRIPT="prettier"
    fi

    debug_log "Scripts detected - Build: $BUILD_SCRIPT, Lint: $LINT_SCRIPT, Test: $TEST_SCRIPT, Format: $FORMAT_SCRIPT"
}

get_filter_flag() {
    # Returns the appropriate filter flag for monorepo commands
    if [ "$IS_MONOREPO" = "false" ] || [ "$CURRENT_PACKAGE" = "root" ]; then
        echo ""
        return
    fi

    if [ "$PACKAGE_MANAGER" = "pnpm" ]; then
        echo "--filter $CURRENT_PACKAGE"
    elif [ "$PACKAGE_MANAGER" = "yarn" ] && [[ "$MONOREPO_TOOL" == *"workspaces"* ]]; then
        echo "workspace $CURRENT_PACKAGE"
    elif [[ "$MONOREPO_TOOL" == *"lerna"* ]]; then
        echo "--scope $CURRENT_PACKAGE"
    else
        echo ""
    fi
}

build_command() {
    local script="$1"
    local skip_filter="${2:-false}"

    if [ -z "$script" ]; then
        echo ""
        return
    fi

    if [ -z "$PACKAGE_MANAGER" ]; then
        echo ""
        return
    fi

    local filter=""
    if [ "$skip_filter" = "false" ] && [ "$IS_MONOREPO" = "true" ] && [ "$CURRENT_PACKAGE" != "root" ]; then
        filter=$(get_filter_flag)
    fi

    # Special handling for turbo
    if [[ "$MONOREPO_TOOL" == *"turbo"* ]] && [ "$CURRENT_PACKAGE" = "root" ]; then
        echo "$PACKAGE_MANAGER run $script"
    else
        echo "$PACKAGE_MANAGER ${filter:+$filter }run $script"
    fi
}

# Main detection flow
main() {
    find_repo_root

    # Check if it's a JavaScript project - exit if not
    if ! check_javascript_project; then
        echo -e "${YELLOW}⚠️  Not a JavaScript/TypeScript project - skipping validation${NC}"
        export IS_JAVASCRIPT_PROJECT=false
        return 1
    fi

    export IS_JAVASCRIPT_PROJECT=true

    detect_package_manager
    detect_changesets
    detect_monorepo
    detect_current_package
    detect_scripts

    # Export results
    export REPO_ROOT
    export PACKAGE_MANAGER
    export HAS_CHANGESETS
    export IS_MONOREPO
    export MONOREPO_TOOL
    export CURRENT_PACKAGE
    export BUILD_SCRIPT
    export LINT_SCRIPT
    export TEST_SCRIPT
    export FORMAT_SCRIPT

    # Print summary if running standalone
    if [ "${1:-}" = "--summary" ]; then
        echo -e "${BLUE}Repository Configuration Summary:${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "📁 Repo Root:        $REPO_ROOT"
        echo -e "📦 Package Manager:  ${PACKAGE_MANAGER:-Not detected}"
        echo -e "🔄 Changesets:       $([ "$HAS_CHANGESETS" = "true" ] && echo "Yes" || echo "No")"
        echo -e "🏗️  Monorepo:         $([ "$IS_MONOREPO" = "true" ] && echo "Yes ($MONOREPO_TOOL)" || echo "No")"
        if [ "$IS_MONOREPO" = "true" ]; then
            echo -e "📍 Current Package:  $CURRENT_PACKAGE"
        fi
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}Available Scripts:${NC}"
        [ -n "$BUILD_SCRIPT" ] && echo -e "  🔨 Build:  $(build_command "$BUILD_SCRIPT")"
        [ -n "$LINT_SCRIPT" ] && echo -e "  🔍 Lint:   $(build_command "$LINT_SCRIPT")"
        [ -n "$TEST_SCRIPT" ] && echo -e "  🧪 Test:   $(build_command "$TEST_SCRIPT")"
        [ -n "$FORMAT_SCRIPT" ] && echo -e "  💅 Format: $(build_command "$FORMAT_SCRIPT")"
    fi
}

# Run main function
main "$@"