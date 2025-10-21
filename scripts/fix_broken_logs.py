#!/usr/bin/env python3
"""
Script para arreglar los errores del script de migración anterior
"""

import os
import re
from pathlib import Path

def fix_file(filepath):
    """Arregla los errores en un archivo"""
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()

    original_content = content

    # Pattern 1: appLogger.log('...', level: 'INFO'): -> appLogger.log('...:', level: 'INFO');
    content = re.sub(
        r"appLogger\.log\(([^,]+), level: '([^']+)'\):",
        r"appLogger.log(\1:', level: '\2');",
        content
    )

    # Pattern 2: ...($var, level: 'LEVEL') -> ...$var), level: 'LEVEL')
    # This fixes: groupData['name'], level: 'INFO')
    content = re.sub(
        r"\(([^,]+), level: '([^']+)'\):",
        r"(\1):', level: '\2');",
        content
    )

    # Pattern 3: toList(, level: 'INFO') -> toList()), level: 'INFO')
    content = re.sub(
        r"\.toList\(\, level: '([^']+)'\)\}'\)",
        r".toList())}', level: '\1')",
        content
    )

    # Pattern 4: level: INFO (sin comillas) -> level: 'INFO'
    content = re.sub(
        r"level: (ERROR|WARNING|INFO|DEBUG)([,\)])",
        r"level: '\1'\2",
        content
    )

    if content != original_content:
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(content)
        return True
    return False

def main():
    print("🔧 Arreglando errores del script de migración...\n")

    lib_dir = Path('lib')
    fixed_count = 0

    for dart_file in lib_dir.rglob('*.dart'):
        if fix_file(dart_file):
            fixed_count += 1
            print(f"✅ {dart_file}")

    print(f"\n📊 Archivos arreglados: {fixed_count}")

if __name__ == '__main__':
    main()
