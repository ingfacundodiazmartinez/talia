#!/usr/bin/env python3
"""
Script para arreglar errores de sintaxis causados por migrate_logs.py
"""

import re
from pathlib import Path

def fix_applogger_line(line):
    """Arregla una línea con errores de appLogger.log()"""
    original_line = line
    changed = False

    if 'appLogger.log(' in line:
        # Fix 1: Remover coma doble antes de level:
        if ',,' in line:
            line = line.replace(',,', ',')
            changed = True

        # Fix 2: Arreglar patrón de $e')' -> $e'
        pattern_extra_paren = r"(\$\w+)'\)'\s*,\s*level:"
        if re.search(pattern_extra_paren, line):
            line = re.sub(pattern_extra_paren, r"\1', level:", line)
            changed = True

        # Fix 3: Agregar ; al final si falta
        if re.search(r"appLogger\.log\(.*,\s*level:\s*'[A-Z]+'\)\s*$", line.rstrip()):
            line = line.rstrip() + ';\n' if original_line.endswith('\n') else line.rstrip() + ';'
            changed = True

        # Fix 4: Arreglar ; duplicado
        if re.search(r"level:\s*'[A-Z]+'\);\s*;", line):
            line = re.sub(r"(level:\s*'[A-Z]+'\));+", r"\1;", line)
            changed = True

    # Fix 5: Arreglar comillas extras en return, variables, etc.
    # Ejemplo: return message'; -> return message;
    if re.search(r"\w+'\s*;", line) and 'appLogger' not in line:
        line = re.sub(r"(\w+)'\s*;", r"\1;", line)
        changed = True

    return line, changed

def process_file(filepath):
    """Procesa un archivo y arregla los errores"""
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            lines = f.readlines()

        fixed_lines = []
        changes = 0

        for line in lines:
            fixed_line, changed = fix_applogger_line(line)
            fixed_lines.append(fixed_line)
            if changed:
                changes += 1

        if changes > 0:
            with open(filepath, 'w', encoding='utf-8') as f:
                f.writelines(fixed_lines)
            return changes
        return 0

    except Exception as e:
        print(f"❌ Error procesando {filepath}: {e}")
        return 0

def main():
    print("🔧 Arreglando errores de sintaxis de appLogger.log()...\n")

    lib_dir = Path('lib')
    total_files = 0
    modified_files = 0
    total_changes = 0

    for dart_file in lib_dir.rglob('*.dart'):
        total_files += 1
        changes = process_file(dart_file)

        if changes > 0:
            modified_files += 1
            total_changes += changes
            print(f"✅ {dart_file} ({changes} líneas arregladas)")

    print(f"\n📊 Resumen:")
    print(f"   - Archivos procesados: {total_files}")
    print(f"   - Archivos modificados: {modified_files}")
    print(f"   - Líneas arregladas: {total_changes}")

if __name__ == '__main__':
    main()
