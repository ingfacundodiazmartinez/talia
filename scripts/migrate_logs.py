#!/usr/bin/env python3
"""
Script para migrar debugPrint() y print() a appLogger.log()
Excepto remote_logger_service.dart para evitar loops infinitos
"""

import os
import re
from pathlib import Path

def determine_level(message):
    """Determina el nivel de log basado en el contenido del mensaje"""
    lower = message.lower()

    if any(word in lower for word in ['error', 'exception', 'failed', '❌']):
        return 'ERROR'
    if any(word in lower for word in ['warning', 'warn', '⚠️']):
        return 'WARNING'
    if any(word in lower for word in ['success', '✅', 'completed']):
        return 'INFO'
    if any(word in lower for word in ['debug', '🐛']):
        return 'DEBUG'

    return 'INFO'

def migrate_file(filepath):
    """Migra un archivo individual"""
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()

    original_content = content
    replacements = 0

    # Check if already has import
    has_import = "import 'package:talia/services/remote_logger_service.dart'" in content or \
                 'import "package:talia/services/remote_logger_service.dart"' in content

    # Check if has logging statements
    has_logging = 'debugPrint(' in content or re.search(r'\bprint\(', content)

    if not has_logging:
        return 0

    # Add import if needed
    if not has_import:
        # Find first import line
        import_match = re.search(r"^import ['\"].*['\"];$", content, re.MULTILINE)
        if import_match:
            insert_pos = import_match.end()
            content = content[:insert_pos] + "\nimport 'package:talia/services/remote_logger_service.dart';" + content[insert_pos:]
        else:
            # No imports, add at top
            content = "import 'package:talia/services/remote_logger_service.dart';\n\n" + content

    # Replace debugPrint - only simple single-line cases
    def replace_debug_print(match):
        nonlocal replacements
        full_match = match.group(0)
        message = match.group(1).strip()

        # Skip multi-line or complex cases
        if '\n' in message or message.count('(') > message.count(')'):
            return full_match

        replacements += 1
        level = determine_level(message)
        return f"appLogger.log({message}, level: '{level}')"

    # Only match single-line debugPrint calls
    content = re.sub(
        r"debugPrint\(([^;]+?)\);",
        replace_debug_print,
        content
    )

    # Replace print - only simple single-line cases
    def replace_print(match):
        nonlocal replacements
        full_match = match.group(0)
        message = match.group(1).strip()

        # Get full line context
        start = content.rfind('\n', 0, match.start()) + 1
        line = content[start:match.start()].strip()

        # Skip if in comment or complex case
        if line.startswith('//') or '\n' in message or message.count('(') > message.count(')'):
            return full_match

        replacements += 1
        level = determine_level(message)
        return f"appLogger.log({message}, level: '{level}')"

    # Only match simple single-line print calls
    content = re.sub(
        r"\bprint\(([^;]+?)\);",
        replace_print,
        content
    )

    # Write back if changed
    if content != original_content:
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(content)
        return replacements

    return 0

def main():
    print("🔄 Migrando logs a appLogger...\n")

    lib_dir = Path('lib')
    total_files = 0
    modified_files = 0
    total_replacements = 0

    for dart_file in lib_dir.rglob('*.dart'):
        # Skip remote_logger_service.dart
        if 'remote_logger_service.dart' in str(dart_file):
            print(f"⏭️  Skipping {dart_file} (logger service)")
            continue

        total_files += 1
        replacements = migrate_file(dart_file)

        if replacements > 0:
            modified_files += 1
            total_replacements += replacements
            print(f"✅ {dart_file} ({replacements} replacements)")

    print(f"\n📊 Resumen:")
    print(f"   - Archivos procesados: {total_files}")
    print(f"   - Archivos modificados: {modified_files}")
    print(f"   - Total reemplazos: {total_replacements}")

if __name__ == '__main__':
    main()
