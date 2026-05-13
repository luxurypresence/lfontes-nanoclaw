#!/usr/bin/env python3
"""
Migration Helper

Scans files for ux-core imports and provides migration suggestions to design-system-ui.
Helps identify migration opportunities and provides actionable recommendations.

Usage:
    python migration-helper.py <directory-or-file>
    python migration-helper.py --format json <directory>
    python migration-helper.py --component Box src/
"""

import sys
import re
from pathlib import Path
from typing import List, Dict, Set
from collections import defaultdict


# Migration mappings
COMPONENT_MIGRATIONS = {
    'Box': {
        'from': '@luxury-presence/ux-core/dist/v2',
        'to': 'Tailwind utilities',
        'suggestion': 'Replace with <div> and Tailwind classes (e.g., p-4, m-2, bg-surface)',
        'example': '<Box padding={16}> → <div className="p-4">'
    },
    'Flex': {
        'from': '@luxury-presence/ux-core/dist/v2',
        'to': 'Tailwind utilities',
        'suggestion': 'Replace with <div> and Tailwind flex classes',
        'example': '<Flex spaceBetween> → <div className="flex justify-between">'
    },
    'Button': {
        'from': '@luxury-presence/ux-core/dist/v2',
        'to': '@luxury-presence/design-system-ui/components/ui/button',
        'suggestion': 'Migrate to design-system Button component',
        'example': 'import { Button } from "@luxury-presence/design-system-ui/components/ui/button"'
    },
    'Input': {
        'from': '@luxury-presence/ux-core/dist/v2',
        'to': '@luxury-presence/design-system-ui/components/ui/input',
        'suggestion': 'Migrate to design-system Input component',
        'example': 'import { Input } from "@luxury-presence/design-system-ui/components/ui/input"'
    },
    'SelectInput': {
        'from': '@luxury-presence/ux-core/dist/v2',
        'to': '@luxury-presence/design-system-ui/components/ui/select',
        'suggestion': 'Migrate to design-system Select component',
        'example': 'import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@luxury-presence/design-system-ui/components/ui/select"'
    },
    'FormikTextInput': {
        'from': '@luxury-presence/ux-core/dist/v2',
        'to': '@luxury-presence/design-system-ui/components/ui/input',
        'suggestion': 'Replace with design-system Input and remove Formik wrapper',
        'example': 'Use Input component with formik.handleChange and formik.values'
    },
    'ResourceListViewV2': {
        'from': '@luxury-presence/ux-core/dist/v2/components/ResourceListViewV2',
        'to': '@luxury-presence/design-system-ui/components/composite/data-table',
        'suggestion': 'Migrate to design-system DataTable with column builder API',
        'example': 'import { DataTable, columns } from "@luxury-presence/design-system-ui/components/composite/data-table"'
    },
    'WarningModal': {
        'from': '@luxury-presence/ux-core/dist/v2',
        'to': '@luxury-presence/design-system-ui/components/ui/dialog',
        'suggestion': 'Migrate to design-system Dialog component',
        'example': 'import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@luxury-presence/design-system-ui/components/ui/dialog"'
    },
    'SnackBar': {
        'from': '@luxury-presence/ux-core/dist/v2',
        'to': '@luxury-presence/design-system-ui/components/ui/toast',
        'suggestion': 'Migrate to design-system toast() function',
        'example': 'import { toast } from "@luxury-presence/design-system-ui/components/ui/toast"; toast({ title: "...", description: "..." })'
    },
    'Icon': {
        'from': '@luxury-presence/ux-core/dist/v2',
        'to': '@luxury-presence/design-system-icons/sprite/*',
        'suggestion': 'Replace with specific icons from design-system-icons',
        'example': 'import { FilterFunnel01Outline } from "@luxury-presence/design-system-icons/sprite/general"'
    },
    'Label': {
        'from': '@luxury-presence/ux-core/dist/v2',
        'to': '@luxury-presence/design-system-ui/components/ui/label',
        'suggestion': 'Migrate to design-system Label component',
        'example': 'import { Label } from "@luxury-presence/design-system-ui/components/ui/label"'
    },
}

THEME_MIGRATIONS = {
    'theme.colors.primary': 'bg-primary / text-primary',
    'theme.colors.error': 'bg-error / text-error',
    'theme.colors.success': 'bg-success / text-success',
    'theme.colors.text.primary': 'text-on-surface',
    'theme.colors.text.secondary': 'text-on-surface-variant',
    'theme.colors.background': 'bg-surface',
    'theme.spacing': 'Tailwind spacing utilities (gap-2, p-4, etc.)',
}


def find_ux_core_imports(file_path: Path) -> Dict[str, Set[str]]:
    """Find all ux-core imports in a file"""
    imports = defaultdict(set)

    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
    except Exception as e:
        print(f"Warning: Could not read {file_path}: {e}", file=sys.stderr)
        return imports

    # Pattern 1: import { Component1, Component2 } from '@luxury-presence/ux-core/...'
    pattern1 = r"import\s+{([^}]+)}\s+from\s+['\"]@luxury-presence/ux-core/([^'\"]+)['\"]"
    for match in re.finditer(pattern1, content):
        components = [c.strip() for c in match.group(1).split(',')]
        source = match.group(2)
        for component in components:
            imports[component].add(source)

    # Pattern 2: import Component from '@luxury-presence/ux-core/...'
    pattern2 = r"import\s+(\w+)\s+from\s+['\"]@luxury-presence/ux-core/([^'\"]+)['\"]"
    for match in re.finditer(pattern2, content):
        component = match.group(1)
        source = match.group(2)
        imports[component].add(source)

    # Pattern 3: Check for theme usage
    if 'theme' in content and '@luxury-presence/ux-core' in content:
        imports['theme'].add('dist/v2/style/theme')

    return imports


def scan_directory(directory: Path, component_filter: str = None) -> Dict[str, List[Dict]]:
    """Scan directory for ux-core imports"""
    results = defaultdict(list)

    # Find all TypeScript/JavaScript files
    patterns = ['**/*.ts', '**/*.tsx', '**/*.js', '**/*.jsx']
    files = []
    for pattern in patterns:
        files.extend(directory.glob(pattern))

    for file_path in files:
        imports = find_ux_core_imports(file_path)

        if not imports:
            continue

        # Filter by component if specified
        if component_filter:
            imports = {k: v for k, v in imports.items() if k == component_filter}
            if not imports:
                continue

        file_data = {
            'file': str(file_path.relative_to(directory)),
            'imports': dict(imports)
        }

        for component in imports:
            results[component].append(file_data)

    return results


def print_text_report(results: Dict[str, List[Dict]], show_all: bool = False):
    """Print human-readable report"""
    if not results:
        print("✅ No ux-core imports found! Migration complete.")
        return

    print("=" * 80)
    print("UX-CORE MIGRATION OPPORTUNITIES")
    print("=" * 80)
    print()

    # Summary statistics
    total_files = len(set(item['file'] for items in results.values() for item in items))
    total_components = len(results)

    print(f"Files with ux-core imports: {total_files}")
    print(f"Different ux-core components used: {total_components}")
    print()

    # Sort components by usage count (most used first)
    sorted_components = sorted(
        results.items(),
        key=lambda x: len(x[1]),
        reverse=True
    )

    for component, files in sorted_components:
        print(f"\n{'='*80}")
        print(f"COMPONENT: {component}")
        print(f"{'='*80}")
        print(f"Usage count: {len(files)} file(s)")

        # Show migration suggestion
        if component in COMPONENT_MIGRATIONS:
            migration = COMPONENT_MIGRATIONS[component]
            print(f"\nFrom: {migration['from']}")
            print(f"To:   {migration['to']}")
            print(f"\n✅ Suggestion: {migration['suggestion']}")
            print(f"📝 Example: {migration['example']}")
        elif component == 'theme':
            print(f"\n✅ Suggestion: Replace theme imports with Tailwind design tokens")
            print(f"\nCommon migrations:")
            for old, new in THEME_MIGRATIONS.items():
                print(f"  • {old} → {new}")
        else:
            print(f"\n⚠️  No migration path defined for this component")
            print(f"   Check design-system documentation for alternatives")

        # Show file list
        if show_all or len(files) <= 10:
            print(f"\nFiles using this component:")
            for file_data in files:
                print(f"  • {file_data['file']}")
        else:
            print(f"\nShowing 10 of {len(files)} files:")
            for file_data in files[:10]:
                print(f"  • {file_data['file']}")
            print(f"  ... and {len(files) - 10} more")

        print()

    # Priority recommendations
    print(f"\n{'='*80}")
    print("PRIORITY RECOMMENDATIONS")
    print(f"{'='*80}\n")

    high_priority = []
    for component, files in sorted_components:
        if len(files) > 20:
            high_priority.append(f"🔴 {component}: {len(files)} files (very high impact)")
        elif len(files) > 10:
            high_priority.append(f"🟡 {component}: {len(files)} files (high impact)")

    if high_priority:
        print("Focus migration efforts on these components:\n")
        for item in high_priority:
            print(f"  {item}")
    else:
        print("All components have low usage counts - good for incremental migration!")

    print(f"\n{'='*80}\n")


def print_json_report(results: Dict[str, List[Dict]]):
    """Print JSON report"""
    import json

    output = {
        'summary': {
            'total_files': len(set(item['file'] for items in results.values() for item in items)),
            'total_components': len(results),
        },
        'components': {}
    }

    for component, files in results.items():
        output['components'][component] = {
            'usage_count': len(files),
            'migration': COMPONENT_MIGRATIONS.get(component, {}),
            'files': files
        }

    print(json.dumps(output, indent=2))


def main():
    """Main entry point"""
    import argparse

    parser = argparse.ArgumentParser(
        description="Scan files for ux-core imports and suggest migrations"
    )
    parser.add_argument(
        'path',
        type=str,
        help='Directory or file to scan'
    )
    parser.add_argument(
        '--format',
        choices=['text', 'json'],
        default='text',
        help='Output format (default: text)'
    )
    parser.add_argument(
        '--component',
        type=str,
        help='Filter results by specific component name'
    )
    parser.add_argument(
        '--show-all',
        action='store_true',
        help='Show all files (don't truncate long lists)'
    )

    args = parser.parse_args()

    path = Path(args.path)

    if not path.exists():
        print(f"Error: Path does not exist: {path}")
        sys.exit(1)

    if path.is_file():
        # Scan single file
        imports = find_ux_core_imports(path)
        if not imports:
            print(f"✅ No ux-core imports found in {path}")
            sys.exit(0)

        results = defaultdict(list)
        for component in imports:
            results[component].append({
                'file': path.name,
                'imports': {component: list(imports[component])}
            })
    else:
        # Scan directory
        results = scan_directory(path, args.component)

    if args.format == 'json':
        print_json_report(results)
    else:
        print_text_report(results, args.show_all)


if __name__ == '__main__':
    main()
