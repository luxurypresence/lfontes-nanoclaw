#!/bin/bash

# Detect Changed Packages Script
# Identifies which packages have been modified in a monorepo

set -e

# Colors for output
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Get script directory and source detection
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/detect-repo-config.sh" >/dev/null 2>&1

# Function to detect the default branch
detect_default_branch() {
    # Try to get the default branch from remote
    local default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')

    if [ -z "$default_branch" ]; then
        # Fallback: check for common branch names
        if git show-ref --verify --quiet "refs/remotes/origin/master"; then
            default_branch="master"
        elif git show-ref --verify --quiet "refs/remotes/origin/main"; then
            default_branch="main"
        else
            # Last resort: use main
            default_branch="main"
        fi
    fi

    echo "$default_branch"
}

# Function to get git changes
get_git_changes() {
    local base_branch="${1:-$(detect_default_branch)}"

    # Check if we have uncommitted changes
    local has_uncommitted=false
    if ! git diff --quiet || ! git diff --cached --quiet; then
        has_uncommitted=true
    fi

    # Get list of changed files
    local changed_files=""

    # Get uncommitted and staged changes
    if [ "$has_uncommitted" = true ]; then
        changed_files=$(git diff --name-only)
        changed_files="$changed_files
$(git diff --cached --name-only)"
    fi

    # Get committed changes not in base branch
    local current_branch=$(git branch --show-current)

    # Always check for commits that differ from the base branch
    if [ "$current_branch" != "$base_branch" ]; then
        # Try to compare with origin/base_branch first (most common case)
        if git show-ref --verify --quiet "refs/remotes/origin/$base_branch"; then
            local branch_changes=$(git diff --name-only "origin/$base_branch"...HEAD 2>/dev/null || true)
            if [ -n "$branch_changes" ]; then
                changed_files="$changed_files
$branch_changes"
            fi
        elif git show-ref --verify --quiet "refs/heads/$base_branch"; then
            # Fallback to local branch if origin doesn't exist
            local branch_changes=$(git diff --name-only "$base_branch"...HEAD 2>/dev/null || true)
            if [ -n "$branch_changes" ]; then
                changed_files="$changed_files
$branch_changes"
            fi
        fi
    fi

    # Remove duplicates, empty lines, and .md files (changesets, docs, etc. don't need validation)
    echo "$changed_files" | grep -v '\.md$' | sort -u | grep -v '^$' || true
}

# Function to map files to packages
map_files_to_packages() {
    local changed_files="$1"
    local packages=""

    if [ "$IS_MONOREPO" != "true" ]; then
        # Not a monorepo, return root
        echo "root"
        return
    fi

    # Parse workspace configuration
    local workspace_patterns=""
    if [ -f "$REPO_ROOT/pnpm-workspace.yaml" ]; then
        # Extract workspace patterns from pnpm-workspace.yaml - handle both single and double quotes
        workspace_patterns=$(grep '^\s*-' "$REPO_ROOT/pnpm-workspace.yaml" 2>/dev/null | sed 's/^[[:space:]]*-[[:space:]]*//' | tr -d "\"'" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    elif [ -f "$REPO_ROOT/package.json" ]; then
        # Extract workspaces from package.json
        workspace_patterns=$(grep -A 10 '"workspaces"' "$REPO_ROOT/package.json" 2>/dev/null | grep -E '^\s*"[^"]+"\s*,?\s*$' | sed 's/.*"\([^"]*\)".*/\1/')
    fi

    # Check each changed file
    while IFS= read -r file; do
        [ -z "$file" ] && continue

        # Check if file is in root (not in any package)
        local in_package=false

        # Check against each workspace pattern
        while IFS= read -r pattern; do
            [ -z "$pattern" ] && continue

            # Convert glob pattern to regex-like check
            # Handle patterns like "apps/*", "packages/*", etc.
            local dir_pattern=$(echo "$pattern" | sed 's/\*/[^\/]*/g')

            # Check if file matches pattern
            if echo "$file" | grep -qE "^$dir_pattern/"; then
                # Extract package directory
                local pkg_dir=$(echo "$file" | grep -oE "^$dir_pattern" | head -1)

                # If pattern ends with /*, get the actual package directory
                if [[ "$pattern" == *"/*" ]]; then
                    pkg_dir=$(echo "$file" | cut -d'/' -f1-2)
                fi

                # Check if this directory has a package.json
                if [ -f "$REPO_ROOT/$pkg_dir/package.json" ]; then
                    # Extract package name
                    local pkg_name=$(grep -o '"name":[[:space:]]*"[^"]*"' "$REPO_ROOT/$pkg_dir/package.json" 2>/dev/null | head -1 | cut -d'"' -f4)
                    if [ -n "$pkg_name" ]; then
                        packages="$packages
$pkg_name"
                        in_package=true
                        break
                    fi
                fi
            fi
        done <<< "$workspace_patterns"

        # If file is not in any package, it's a root change
        if [ "$in_package" = "false" ]; then
            packages="$packages
root"
        fi
    done <<< "$changed_files"

    # Remove duplicates
    echo "$packages" | sort -u | grep -v '^$' || echo "root"
}

# Function to detect if root files affect all packages
check_root_affects_all() {
    local changed_files="$1"

    # Files that affect all packages when changed
    local global_files="
pnpm-workspace.yaml
package.json
pnpm-lock.yaml
yarn.lock
package-lock.json
turbo.json
lerna.json
nx.json
tsconfig.json
.eslintrc
.prettierrc
"

    while IFS= read -r file; do
        [ -z "$file" ] && continue

        # Check if file is in root and is a global config
        if ! echo "$file" | grep -q '/' || echo "$file" | grep -q '^\./'; then
            local basename=$(basename "$file")
            if echo "$global_files" | grep -qF "$basename"; then
                return 0  # true - affects all
            fi
        fi
    done <<< "$changed_files"

    return 1  # false - doesn't affect all
}

# Main execution
main() {
    local mode="${1:-detect}"  # detect, list, or filter
    local base_branch="${2:-}"  # optional base branch override

    # Get changed files (will auto-detect base branch if not provided)
    local changed_files=$(get_git_changes "$base_branch")

    if [ -z "$changed_files" ]; then
        if [ "$mode" = "list" ]; then
            # For list mode, output nothing (empty list)
            exit 0
        else
            # For detect mode, show user-friendly message
            echo "No changes detected"
            exit 0
        fi
    fi

    # Check if root changes affect all packages
    local affects_all=false
    if check_root_affects_all "$changed_files"; then
        affects_all=true
    fi

    # Map files to packages
    local changed_packages=$(map_files_to_packages "$changed_files")

    case "$mode" in
        detect)
            # Default mode: show summary
            echo -e "${CYAN}Changed Packages Detected:${NC}"
            if [ "$affects_all" = "true" ]; then
                echo "⚠️  Root configuration changed - affects all packages"
                echo ""
                echo "Changed files in root:"
                echo "$changed_files" | grep -v '/' | sed 's/^/  - /'
                echo ""
                echo "Recommendation: Run validation without package filter"
            elif [ "$changed_packages" = "root" ] && [ "$IS_MONOREPO" = "true" ]; then
                echo "📁 Root package only"
                echo "Recommendation: Run validation at root level"
            else
                echo "$changed_packages" | while read -r pkg; do
                    [ -z "$pkg" ] && continue
                    echo "  📦 $pkg"
                done

                # Count packages
                local pkg_count=$(echo "$changed_packages" | grep -v '^$' | wc -l)
                echo ""
                echo "Total: $pkg_count package(s) changed"

                if [ "$pkg_count" -eq 1 ] && [ "$IS_MONOREPO" = "true" ]; then
                    local single_pkg=$(echo "$changed_packages" | grep -v '^$' | head -1)
                    if [ "$single_pkg" != "root" ]; then
                        echo "Recommendation: Run validation with --package $single_pkg"
                    fi
                elif [ "$pkg_count" -gt 1 ] && [ "$pkg_count" -lt 5 ]; then
                    echo "Recommendation: Run validation for each package:"
                    echo "$changed_packages" | grep -v '^$' | grep -v '^root$' | while read -r pkg; do
                        echo "  ./validate.sh --package $pkg"
                    done
                elif [ "$pkg_count" -ge 5 ]; then
                    echo "Recommendation: Many packages changed, consider running full validation"
                fi
            fi
            ;;

        list)
            # List mode: just output package names
            if [ "$affects_all" = "true" ]; then
                echo "ALL"
            else
                echo "$changed_packages"
            fi
            ;;

        filter)
            # Filter mode: output filter flags for commands
            if [ "$affects_all" = "true" ] || [ "$changed_packages" = "root" ]; then
                echo ""  # No filter needed
            else
                # Output filter flags for each package
                echo "$changed_packages" | grep -v '^$' | grep -v '^root$' | while read -r pkg; do
                    [ -z "$pkg" ] && continue
                    if [ "$PACKAGE_MANAGER" = "pnpm" ]; then
                        echo "--filter $pkg"
                    elif [ "$PACKAGE_MANAGER" = "yarn" ] && [[ "$MONOREPO_TOOL" == *"workspaces"* ]]; then
                        echo "workspace $pkg"
                    elif [[ "$MONOREPO_TOOL" == *"lerna"* ]]; then
                        echo "--scope $pkg"
                    fi
                done | head -1  # Return first package for single validation
            fi
            ;;

        *)
            echo "Usage: $0 [detect|list|filter] [base-branch]"
            echo "  detect - Show summary of changed packages (default)"
            echo "  list   - List changed package names"
            echo "  filter - Output filter flags for package manager"
            exit 1
            ;;
    esac
}

# Run main function
main "$@"