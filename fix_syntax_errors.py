#!/usr/bin/env python3
"""
Script para arreglar errores de sintaxis causados por migración de print() a appLogger.log()
"""

import re
import sys
from pathlib import Path

def fix_logger_line(line):
    """
    Arregla una línea con errores de appLogger.log()

    Errores comunes:
    1. appLogger.log('texto, level: 'INFO'):'); -> appLogger.log('texto)', level: 'INFO');
    2. appLogger.log('${var.toList(, level: 'INFO')}'); -> appLogger.log('${var.toList()}', level: 'INFO');
    """

    if 'appLogger.log(' not in line:
        return line, False

    original = line
    changed = False

    # Caso 1: texto)', level: 'LEVEL'):' o texto, level: 'LEVEL'):'
    # Buscar: cualquier cosa antes de ), level: o , level: dentro del string
    pattern1 = r"(appLogger\.log\(['\"])(.+?)(, level: ['\"](?:INFO|DEBUG|WARNING|ERROR)['\"]\):\1\);)"
    if re.search(pattern1, line):
        # Extraer las partes
        match = re.search(r"appLogger\.log\((['\"])(.+?), level: (['\"])(INFO|DEBUG|WARNING|ERROR)\3\):\1\);", line)
        if match:
            quote = match.group(1)
            text = match.group(2)
            level = match.group(4)
            indent = len(line) - len(line.lstrip())
            line = ' ' * indent + f"appLogger.log({quote}{text}){quote}, level: '{level}');"
            changed = True

    # Caso 2: ${var.toList(, level: 'LEVEL')}
    if ', level: ' in line and '${' in line and not changed:
        # Buscar patrón ${...( seguido de , level:
        pattern2 = r"\$\{([^}]+?)\(, level: (['\"])(INFO|DEBUG|WARNING|ERROR)\2\)\}"
        matches = list(re.finditer(pattern2, line))
        if matches:
            for match in reversed(matches):  # Procesar de derecha a izquierda
                expr = match.group(1)
                level = match.group(3)
                # Reemplazar ${expr(, level: 'LEVEL')} por ${expr()}
                line = line[:match.start()] + f"${{{expr}()}}" + line[match.end():]
            # Agregar level al final si no está
            if not re.search(r", level: ['\"](?:INFO|DEBUG|WARNING|ERROR)['\"]", line):
                line = re.sub(r'\);$', f", level: '{matches[0].group(3)}');", line)
            changed = True

    # Caso 3: level sin comillas
    if ', level: INFO' in line or ', level: DEBUG' in line or ', level: WARNING' in line or ', level: ERROR' in line:
        line = re.sub(r", level: (INFO|DEBUG|WARNING|ERROR)\)", r", level: '\1')", line)
        changed = True

    return line, changed

def process_file(file_path):
    """Procesa un archivo y arregla los errores"""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            lines = f.readlines()

        fixed_lines = []
        changes = 0

        for line in lines:
            fixed_line, changed = fix_logger_line(line.rstrip('\n'))
            fixed_lines.append(fixed_line + '\n' if line.endswith('\n') else fixed_line)
            if changed:
                changes += 1

        if changes > 0:
            with open(file_path, 'w', encoding='utf-8') as f:
                f.writelines(fixed_lines)
            print(f"✅ {file_path.name}: {changes} líneas arregladas")
            return changes
        else:
            return 0

    except Exception as e:
        print(f"❌ Error procesando {file_path}: {e}")
        return 0

def main():
    if len(sys.argv) < 2:
        print("Uso: python3 fix_syntax_errors.py <archivo1> [archivo2] ...")
        sys.exit(1)

    total_changes = 0
    total_files = 0

    for file_path in sys.argv[1:]:
        path = Path(file_path)
        if path.exists() and path.suffix == '.dart':
            changes = process_file(path)
            if changes > 0:
                total_files += 1
                total_changes += changes

    print(f"\n📊 Resumen: {total_files} archivos modificados, {total_changes} líneas arregladas")

if __name__ == '__main__':
    main()
