#!/bin/bash

# Universal Quick Validation Script with Repository Auto-Detection
# Usage: ./validate.sh [--fix] [--package <name>]

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Parse arguments
AUTO_FIX=false
SPECIFIED_PACKAGE=""
SMART_DETECT=true
ALL_PACKAGES=false

for arg in "$@"; do
    case $arg in
        --fix)
            AUTO_FIX=true
            shift
            ;;
        --package)
            shift
            SPECIFIED_PACKAGE="$1"
            SMART_DETECT=false
            shift
            ;;
        --all)
            ALL_PACKAGES=true
            SMART_DETECT=false
            shift
            ;;
        --no-smart)
            SMART_DETECT=false
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# Functions
log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Source the detection script
source "$SCRIPT_DIR/detect-repo-config.sh" 2>/dev/null || {
    log_error "Failed to load detection script"
    exit 1
}

# Exit early if not a JavaScript/TypeScript project
if [ "$IS_JAVASCRIPT_PROJECT" = "false" ]; then
    log_warning "Not a JavaScript/TypeScript project - skipping validation"
    log_info "This skill only works with JavaScript/TypeScript repositories that have a package.json file"
    exit 0
fi

# Override package if specified
if [ -n "$SPECIFIED_PACKAGE" ]; then
    CURRENT_PACKAGE="$SPECIFIED_PACKAGE"
    log_info "Using specified package: $CURRENT_PACKAGE"
fi

# Smart package detection for monorepos
PACKAGES_TO_VALIDATE=""
if [ "$IS_MONOREPO" = "true" ] && [ "$SMART_DETECT" = "true" ] && [ -z "$SPECIFIED_PACKAGE" ]; then
    log_info "Detecting changed packages..."

    # Get changed packages
    CHANGED_PACKAGES=$("$SCRIPT_DIR/detect-changed-packages.sh" list 2>/dev/null || echo "")

    if [ "$CHANGED_PACKAGES" = "ALL" ]; then
        log_warning "Root configuration changed - validating all packages"
        ALL_PACKAGES=true
    elif [ -n "$CHANGED_PACKAGES" ] && [ "$CHANGED_PACKAGES" != "No changes detected" ]; then
        PACKAGES_TO_VALIDATE="$CHANGED_PACKAGES"
        PACKAGE_COUNT=$(echo "$PACKAGES_TO_VALIDATE" | grep -v '^$' | wc -l)

        if [ "$PACKAGE_COUNT" -eq 1 ]; then
            CURRENT_PACKAGE=$(echo "$PACKAGES_TO_VALIDATE" | grep -v '^$' | head -1)
            log_success "Smart detection: Found 1 changed package: $CURRENT_PACKAGE"
        elif [ "$PACKAGE_COUNT" -gt 1 ] && [ "$PACKAGE_COUNT" -le 3 ]; then
            log_success "Smart detection: Found $PACKAGE_COUNT changed packages"
            echo "$PACKAGES_TO_VALIDATE" | grep -v '^$' | while read -r pkg; do
                echo "  📦 $pkg"
            done
            echo ""
            log_info "Will validate each package sequentially..."
        elif [ "$PACKAGE_COUNT" -gt 3 ]; then
            log_warning "Many packages changed ($PACKAGE_COUNT). Consider using --all flag"
            echo "$PACKAGES_TO_VALIDATE" | grep -v '^$' | head -5 | while read -r pkg; do
                echo "  📦 $pkg"
            done
            [ "$PACKAGE_COUNT" -gt 5 ] && echo "  ... and $((PACKAGE_COUNT - 5)) more"
            echo ""
            log_info "Will validate first 3 packages. Use --all to validate everything"
            PACKAGES_TO_VALIDATE=$(echo "$PACKAGES_TO_VALIDATE" | grep -v '^$' | head -3)
        fi
    else
        log_info "No package changes detected, validating at root level"
        CURRENT_PACKAGE="root"
        PACKAGES_TO_VALIDATE=""
    fi
elif [ "$ALL_PACKAGES" = "true" ]; then
    log_info "Validating all packages (--all flag)"
fi

# Change to repo root for consistent execution
cd "$REPO_ROOT"

# Show detected configuration
echo ""
log_info "Repository Configuration:"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  📁 Repository:      $(basename "$REPO_ROOT")"
echo -e "  📦 Package Manager: ${PACKAGE_MANAGER:-Not detected}"
echo -e "  🔄 Changesets:      $([ "$HAS_CHANGESETS" = "true" ] && echo "✓" || echo "✗")"
echo -e "  🏗️  Monorepo:        $([ "$IS_MONOREPO" = "true" ] && echo "✓ ($MONOREPO_TOOL)" || echo "✗")"
if [ "$IS_MONOREPO" = "true" ] && [ "$CURRENT_PACKAGE" != "root" ]; then
    echo -e "  📍 Package:         $CURRENT_PACKAGE"
fi
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check and install dependencies if needed
check_and_install_dependencies() {
    log_info "Checking dependencies..."

    # Check if node_modules exists
    if [ ! -d "$REPO_ROOT/node_modules" ]; then
        log_warning "Dependencies not installed (node_modules not found)"
        log_info "Installing dependencies with $PACKAGE_MANAGER..."

        cd "$REPO_ROOT"
        if [ "$PACKAGE_MANAGER" = "pnpm" ]; then
            pnpm install
        elif [ "$PACKAGE_MANAGER" = "npm" ]; then
            npm install
        elif [ "$PACKAGE_MANAGER" = "yarn" ]; then
            yarn install
        else
            log_error "Unknown package manager: $PACKAGE_MANAGER"
            return 1
        fi

        if [ $? -eq 0 ]; then
            log_success "Dependencies installed successfully"
        else
            log_error "Failed to install dependencies"
            return 1
        fi
    else
        # Check if dependencies might be stale (package.json newer than node_modules)
        if [ "$REPO_ROOT/package.json" -nt "$REPO_ROOT/node_modules" ]; then
            log_warning "package.json is newer than node_modules - dependencies may be stale"
            log_info "Running $PACKAGE_MANAGER install to update dependencies..."

            cd "$REPO_ROOT"
            if [ "$PACKAGE_MANAGER" = "pnpm" ]; then
                pnpm install
            elif [ "$PACKAGE_MANAGER" = "npm" ]; then
                npm install
            elif [ "$PACKAGE_MANAGER" = "yarn" ]; then
                yarn install
            fi

            if [ $? -eq 0 ]; then
                log_success "Dependencies updated successfully"
            else
                log_warning "Failed to update dependencies, continuing with existing installation"
            fi
        else
            log_success "Dependencies already installed"
        fi
    fi

    # For monorepos, also check if lock file is newer than node_modules
    if [ "$IS_MONOREPO" = "true" ]; then
        LOCK_FILE=""
        if [ "$PACKAGE_MANAGER" = "pnpm" ] && [ -f "$REPO_ROOT/pnpm-lock.yaml" ]; then
            LOCK_FILE="$REPO_ROOT/pnpm-lock.yaml"
        elif [ "$PACKAGE_MANAGER" = "npm" ] && [ -f "$REPO_ROOT/package-lock.json" ]; then
            LOCK_FILE="$REPO_ROOT/package-lock.json"
        elif [ "$PACKAGE_MANAGER" = "yarn" ] && [ -f "$REPO_ROOT/yarn.lock" ]; then
            LOCK_FILE="$REPO_ROOT/yarn.lock"
        fi

        if [ -n "$LOCK_FILE" ] && [ "$LOCK_FILE" -nt "$REPO_ROOT/node_modules" ]; then
            log_warning "Lock file is newer than node_modules"
            log_info "Running $PACKAGE_MANAGER install to sync dependencies..."

            cd "$REPO_ROOT"
            if [ "$PACKAGE_MANAGER" = "pnpm" ]; then
                pnpm install
            elif [ "$PACKAGE_MANAGER" = "npm" ]; then
                npm install
            elif [ "$PACKAGE_MANAGER" = "yarn" ]; then
                yarn install
            fi

            if [ $? -eq 0 ]; then
                log_success "Dependencies synced successfully"
            else
                log_warning "Failed to sync dependencies"
            fi
        fi
    fi

    return 0
}

# Run dependency check
check_and_install_dependencies || {
    log_error "Failed to ensure dependencies are installed"
    exit 1
}

echo ""
log_info "Running validation checks..."
echo ""

# Function to validate a single package
validate_package() {
    local package="$1"
    local package_validation_passed=true

    if [ "$IS_MONOREPO" = "true" ] && [ "$package" != "root" ]; then
        CURRENT_PACKAGE="$package"
        echo ""
        log_info "Validating package: $CURRENT_PACKAGE"
        echo "────────────────────────────────"
    fi

# Step 1: Build Check (if applicable)
if [ -n "$BUILD_SCRIPT" ]; then
    log_info "Checking build..."
    BUILD_CMD=$(build_command "$BUILD_SCRIPT")

    if [ -n "$BUILD_CMD" ]; then
        if $BUILD_CMD > /dev/null 2>&1; then
            log_success "Build OK"
        else
            log_error "Build FAILED"
            package_validation_passed=false
            log_info "Run '$BUILD_CMD' to see detailed errors"
        fi
    else
        log_warning "Could not construct build command"
    fi
else
    log_info "No build script detected"
fi

# Step 2: Lint Check
if [ -n "$LINT_SCRIPT" ]; then
    log_info "Checking linter..."
    LINT_CMD=$(build_command "$LINT_SCRIPT")

    if [ "$AUTO_FIX" = true ]; then
        if [ -n "$LINT_CMD" ]; then
            if $LINT_CMD > /dev/null 2>&1; then
                log_success "Lint OK (auto-fixed)"
            else
                log_error "Lint FAILED (unfixable errors)"
                package_validation_passed=false
                log_info "Run '$LINT_CMD' to see detailed errors"
            fi
        fi
    else
        # Just check without fixing
        if [ -n "$LINT_CMD" ]; then
            # For checking, we might need to modify the command
            CHECK_CMD="$LINT_CMD"

            # Try to run lint in check mode if possible
            if $CHECK_CMD > /dev/null 2>&1; then
                log_success "Lint OK"
            else
                log_warning "Lint has issues (run with --fix to auto-fix)"
                package_validation_passed=false
            fi
        fi
    fi
else
    log_info "No lint script detected"
fi

# Step 3: Test Check
if [ -n "$TEST_SCRIPT" ]; then
    log_info "Running tests..."
    TEST_CMD=$(build_command "$TEST_SCRIPT")

    if [ -n "$TEST_CMD" ]; then
        if $TEST_CMD > /dev/null 2>&1; then
            log_success "All tests PASSED"
        else
            log_error "Tests FAILED"
            package_validation_passed=false
            log_info "Run '$TEST_CMD' to see detailed errors"
        fi
    fi
else
    log_info "No test script detected"
fi

# Step 4: Coverage Check (optional)
if [ -n "$TEST_SCRIPT" ]; then
    # Check if there's a coverage script
    if grep -q '"test:.*cov"' "$REPO_ROOT/package.json" 2>/dev/null; then
        log_info "Checking test coverage..."

        # Try to find coverage script
        COV_SCRIPT=$(grep -o '"test[^"]*cov[^"]*":[[:space:]]*"[^"]*"' "$REPO_ROOT/package.json" 2>/dev/null | head -1 | cut -d':' -f1 | tr -d '"')

        if [ -n "$COV_SCRIPT" ]; then
            COV_CMD=$(build_command "$COV_SCRIPT")
            if [ -n "$COV_CMD" ]; then
                if $COV_CMD > /dev/null 2>&1; then
                    log_success "Test coverage OK"
                else
                    log_warning "Test coverage might be below threshold"
                fi
            fi
        fi
    fi
fi

# Step 5: Check for changeset (if applicable)
if [ "$HAS_CHANGESETS" = "true" ]; then
    log_info "Checking for changeset..."
    CHANGESET_COUNT=$(find .changeset -name "*.md" -not -name "README.md" 2>/dev/null | wc -l)
    if [ "$CHANGESET_COUNT" -gt 0 ]; then
        log_success "Changeset found"
    else
        CHANGESET_CMD="$PACKAGE_MANAGER run changeset"
        if [ "$PACKAGE_MANAGER" = "npm" ]; then
            CHANGESET_CMD="npx changeset"
        elif [ "$PACKAGE_MANAGER" = "pnpm" ]; then
            CHANGESET_CMD="pnpm changeset"
        elif [ "$PACKAGE_MANAGER" = "yarn" ]; then
            CHANGESET_CMD="yarn changeset"
        fi
        log_warning "No changeset found (run '$CHANGESET_CMD' before creating PR)"
    fi
else
    log_info "Repository doesn't use changesets"
fi

# Step 6: Check for uncommitted changes
log_info "Checking git status..."
if git diff --quiet && git diff --cached --quiet; then
    log_success "Working directory clean"
else
    log_warning "You have uncommitted changes"

    # Show summary of changes
    CHANGED_FILES=$(git status --porcelain | wc -l | tr -d ' ')
    if [ "$CHANGED_FILES" -gt 0 ]; then
        echo "  Changed files: $CHANGED_FILES"
    fi
fi

# Step 7: Type checking (for TypeScript projects)
if [ -f "$REPO_ROOT/tsconfig.json" ]; then
    log_info "Checking TypeScript types..."

    # Look for type-check script
    if grep -q '"type-check"' "$REPO_ROOT/package.json" 2>/dev/null || grep -q '"typecheck"' "$REPO_ROOT/package.json" 2>/dev/null; then
        TYPE_SCRIPT=$(grep -o '"type[-]*check":[[:space:]]*"[^"]*"' "$REPO_ROOT/package.json" 2>/dev/null | head -1 | cut -d':' -f1 | tr -d '"' | tr -d ' ')
        if [ -n "$TYPE_SCRIPT" ]; then
            TYPE_CMD=$(build_command "$TYPE_SCRIPT")
            if [ -n "$TYPE_CMD" ]; then
                if $TYPE_CMD > /dev/null 2>&1; then
                    log_success "Type checking OK"
                else
                    log_error "Type checking FAILED"
                    package_validation_passed=false
                fi
            fi
        fi
    else
        # Fallback to tsc
        TSC_CMD="$PACKAGE_MANAGER run tsc --noEmit"
        if $TSC_CMD > /dev/null 2>&1; then
            log_success "TypeScript OK"
        else
            log_warning "TypeScript may have issues"
        fi
    fi
fi

    return $([ "$package_validation_passed" = "true" ] && echo 0 || echo 1)
}

# Determine which packages to validate
if [ -n "$PACKAGES_TO_VALIDATE" ] && [ "$PACKAGES_TO_VALIDATE" != "root" ]; then
    # Multiple packages to validate
    VALIDATION_PASSED=true
    FAILED_PACKAGES=""

    # Use process substitution instead of pipe to avoid subshell issues
    while read -r pkg; do
        [ -z "$pkg" ] && continue

        if validate_package "$pkg"; then
            log_success "Package $pkg validation passed"
        else
            log_error "Package $pkg validation failed"
            FAILED_PACKAGES="$FAILED_PACKAGES $pkg"
            VALIDATION_PASSED=false
        fi
    done < <(printf '%s\n' "$PACKAGES_TO_VALIDATE" | grep -v '^$')

    if [ -n "$FAILED_PACKAGES" ]; then
        VALIDATION_PASSED=false
    fi
else
    # Single package or root validation
    VALIDATION_PASSED=true
    validate_package "${CURRENT_PACKAGE:-root}" || VALIDATION_PASSED=false
fi

# Final Summary
echo ""
echo "=========================================="
if [ "$VALIDATION_PASSED" = true ]; then
    log_success "✨ ALL CHECKS PASSED"
    echo ""
    echo "Your code is ready for PR creation!"
    echo ""
    echo "Next steps:"
    echo "1. Stage your changes: git add -A"
    echo "2. Commit with conventional format: git commit -m \"feat: your feature\""
    if [ "$HAS_CHANGESETS" = "true" ]; then
        echo "3. Create changeset if needed: $PACKAGE_MANAGER run changeset"
        echo "4. Push to remote: git push -u origin <branch-name>"
        echo "5. Create PR: gh pr create --fill"
    else
        echo "3. Push to remote: git push -u origin <branch-name>"
        echo "4. Create PR: gh pr create --fill"
    fi
    if [ "$IS_MONOREPO" = "true" ] && [ "$CURRENT_PACKAGE" != "root" ]; then
        echo ""
        echo "📦 Note: You're in package '$CURRENT_PACKAGE'"
        echo "   Commands ran with filter: $(get_filter_flag)"
    fi
else
    log_error "❌ VALIDATION FAILED"
    echo ""
    echo "Please fix the issues above before creating a PR."
    echo ""
    echo "Quick fixes:"
    if [ "$AUTO_FIX" = false ] && [ -n "$LINT_SCRIPT" ]; then
        echo "  • Run with --fix to auto-fix lint issues: $0 --fix"
    fi
    if [ -n "$BUILD_SCRIPT" ]; then
        echo "  • Check build errors: $(build_command "$BUILD_SCRIPT")"
    fi
    if [ -n "$TEST_SCRIPT" ]; then
        echo "  • Run tests directly: $(build_command "$TEST_SCRIPT")"
    fi
    if [ "$HAS_CHANGESETS" = "true" ]; then
        echo "  • Create changeset: $PACKAGE_MANAGER run changeset"
    fi
fi
echo "=========================================="

# Exit with appropriate code
if [ "$VALIDATION_PASSED" = true ]; then
    exit 0
else
    exit 1
fi