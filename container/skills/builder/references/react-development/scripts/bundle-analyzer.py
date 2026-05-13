#!/usr/bin/env python3
"""
Bundle Size Analyzer

Analyzes bundle-analysis reports to identify large dependencies and optimization opportunities.
Helps track bundle size trends and identify bloat.

Usage:
    python bundle-analyzer.py <path-to-bundle-analysis-report.html>
    python bundle-analyzer.py --threshold 100000 <path-to-report>
"""

import sys
import json
import re
from pathlib import Path
from typing import List, Dict, Tuple
from html.parser import HTMLParser


class BundleAnalyzer(HTMLParser):
    """Parse webpack bundle analyzer HTML report"""

    def __init__(self):
        super().__init__()
        self.in_script = False
        self.chart_data = None

    def handle_starttag(self, tag, attrs):
        if tag == 'script':
            self.in_script = True

    def handle_endtag(self, tag):
        if tag == 'script':
            self.in_script = False

    def handle_data(self, data):
        if self.in_script and 'window.chartData' in data:
            # Extract JSON data from the script tag
            match = re.search(r'window\.chartData\s*=\s*(\[.*?\]);', data, re.DOTALL)
            if match:
                self.chart_data = json.loads(match.group(1))


def format_size(size_bytes: int) -> str:
    """Format byte size to human-readable string"""
    for unit in ['B', 'KB', 'MB', 'GB']:
        if size_bytes < 1024.0:
            return f"{size_bytes:.2f} {unit}"
        size_bytes /= 1024.0
    return f"{size_bytes:.2f} TB"


def extract_packages(data: List[Dict], parent_path: str = "") -> List[Tuple[str, int]]:
    """Recursively extract package names and sizes"""
    packages = []

    for item in data:
        label = item.get('label', '')
        stat_size = item.get('statSize', 0)
        parsed_size = item.get('parsedSize', 0)
        groups = item.get('groups', [])

        current_path = f"{parent_path}/{label}" if parent_path else label

        # If this is a leaf node (no children), record it
        if not groups and (stat_size > 0 or (parsed_size and parsed_size > 0)):
            packages.append((current_path, parsed_size or stat_size))

        # Recurse into children
        if groups:
            packages.extend(extract_packages(groups, current_path))

    return packages


def analyze_bundle(report_path: str, threshold_bytes: int = 50000) -> None:
    """Analyze bundle and print optimization opportunities"""

    if not Path(report_path).exists():
        print(f"Error: Report file not found: {report_path}")
        sys.exit(1)

    # Parse the HTML report
    with open(report_path, 'r', encoding='utf-8') as f:
        content = f.read()

    parser = BundleAnalyzer()
    parser.feed(content)

    if not parser.chart_data:
        print("Error: Could not extract bundle data from report")
        sys.exit(1)

    # Extract all packages
    packages = extract_packages(parser.chart_data)

    # Sort by size (largest first)
    packages.sort(key=lambda x: x[1], reverse=True)

    # Calculate totals
    total_size = sum(size for _, size in packages)
    large_packages = [(name, size) for name, size in packages if size >= threshold_bytes]

    # Print analysis
    print("=" * 80)
    print("BUNDLE SIZE ANALYSIS")
    print("=" * 80)
    print(f"\nTotal bundle size: {format_size(total_size)}")
    print(f"Number of packages: {len(packages)}")
    print(f"Large packages (>{format_size(threshold_bytes)}): {len(large_packages)}")

    print(f"\n{'='*80}")
    print("TOP 20 LARGEST PACKAGES")
    print(f"{'='*80}\n")

    print(f"{'Package':<50} {'Size':>15} {'% of Total':>10}")
    print("-" * 80)

    for name, size in packages[:20]:
        percentage = (size / total_size) * 100
        print(f"{name:<50} {format_size(size):>15} {percentage:>9.1f}%")

    # Optimization suggestions
    print(f"\n{'='*80}")
    print("OPTIMIZATION OPPORTUNITIES")
    print(f"{'='*80}\n")

    suggestions = []

    for name, size in large_packages:
        if 'moment' in name.lower() and size > 500000:
            suggestions.append({
                'package': name,
                'size': size,
                'suggestion': 'Consider using date-fns instead of moment-timezone'
            })
        elif 'ux-core' in name.lower():
            suggestions.append({
                'package': name,
                'size': size,
                'suggestion': 'Migrate to @luxury-presence/design-system-ui to reduce bundle'
            })
        elif 'cloudinary' in name.lower() or 'video-player' in name.lower():
            suggestions.append({
                'package': name,
                'size': size,
                'suggestion': 'Consider lazy loading this package only when needed'
            })
        elif 'grapesjs' in name.lower() or 'editor' in name.lower():
            suggestions.append({
                'package': name,
                'size': size,
                'suggestion': 'Use route-based code splitting for editor components'
            })
        elif 'libphonenumber' in name.lower():
            suggestions.append({
                'package': name,
                'size': size,
                'suggestion': 'Consider libphonenumber-js as a lighter alternative'
            })
        elif size > 1000000:  # > 1MB
            suggestions.append({
                'package': name,
                'size': size,
                'suggestion': 'Very large package - investigate tree-shaking or alternatives'
            })

    if suggestions:
        for i, item in enumerate(suggestions, 1):
            print(f"{i}. {item['package']}")
            print(f"   Size: {format_size(item['size'])}")
            print(f"   Suggestion: {item['suggestion']}")
            print()
    else:
        print("No major optimization opportunities found!")
        print("All packages are below the threshold.")

    # Summary statistics
    print(f"{'='*80}")
    print("SUMMARY")
    print(f"{'='*80}\n")

    packages_over_1mb = sum(1 for _, size in packages if size > 1000000)
    packages_over_500kb = sum(1 for _, size in packages if size > 500000)
    packages_over_100kb = sum(1 for _, size in packages if size > 100000)

    print(f"Packages > 1 MB:   {packages_over_1mb}")
    print(f"Packages > 500 KB: {packages_over_500kb}")
    print(f"Packages > 100 KB: {packages_over_100kb}")

    print(f"\n{'='*80}\n")


def main():
    """Main entry point"""
    import argparse

    parser = argparse.ArgumentParser(
        description="Analyze webpack bundle reports for optimization opportunities"
    )
    parser.add_argument(
        'report_path',
        help='Path to bundle-analysis report HTML file'
    )
    parser.add_argument(
        '--threshold',
        type=int,
        default=50000,
        help='Size threshold in bytes for flagging large packages (default: 50000)'
    )

    args = parser.parse_args()

    analyze_bundle(args.report_path, args.threshold)


if __name__ == '__main__':
    main()
