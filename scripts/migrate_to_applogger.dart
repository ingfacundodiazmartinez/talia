#!/usr/bin/env dart

import 'dart:io';

/// Script para migrar todos los debugPrint() y print() a appLogger.log()
///
/// Excepto remote_logger_service.dart para evitar loops infinitos

void main() async {
  print('🔄 Migrando logs a appLogger...\n');

  final libDir = Directory('lib');
  final files = await _findDartFiles(libDir);

  int totalFiles = 0;
  int modifiedFiles = 0;
  int totalReplacements = 0;

  for (final file in files) {
    // Skip remote_logger_service.dart
    if (file.path.contains('remote_logger_service.dart')) {
      print('⏭️  Skipping ${file.path} (logger service)');
      continue;
    }

    totalFiles++;
    final result = await _migrateFile(file);

    if (result.modified) {
      modifiedFiles++;
      totalReplacements += result.replacements;
      print('✅ ${file.path} (${result.replacements} replacements)');
    }
  }

  print('\n📊 Resumen:');
  print('   - Archivos procesados: $totalFiles');
  print('   - Archivos modificados: $modifiedFiles');
  print('   - Total reemplazos: $totalReplacements');
}

Future<List<File>> _findDartFiles(Directory dir) async {
  final files = <File>[];

  await for (final entity in dir.list(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      files.add(entity);
    }
  }

  return files;
}

Future<MigrationResult> _migrateFile(File file) async {
  String content = await file.readAsString();
  final originalContent = content;
  int replacements = 0;

  // Check if already has appLogger import
  final hasImport = content.contains("import 'package:talia/services/remote_logger_service.dart'") ||
                    content.contains('import "package:talia/services/remote_logger_service.dart"');

  // Check if file has any debug/print statements
  final hasDebugPrint = content.contains('debugPrint(') ||
                        content.contains(RegExp(r'print\([^)]+\)'));

  if (!hasDebugPrint) {
    return MigrationResult(modified: false, replacements: 0);
  }

  // Add import if needed
  if (!hasImport) {
    // Find where to insert import (after first import or at top)
    final importPattern = RegExp(r"^import ['\"].*['\"];$", multiLine: true);
    final firstImport = importPattern.firstMatch(content);

    if (firstImport != null) {
      final insertPos = firstImport.end;
      content = content.substring(0, insertPos) +
                "\nimport 'package:talia/services/remote_logger_service.dart';" +
                content.substring(insertPos);
    } else {
      // No imports found, add at top
      content = "import 'package:talia/services/remote_logger_service.dart';\n\n" + content;
    }
  }

  // Replace debugPrint with appLogger.log
  // Pattern: debugPrint('message') -> appLogger.log('message', level: 'DEBUG')
  content = content.replaceAllMapped(
    RegExp(r"debugPrint\((.*?)\);", multiLine: true, dotAll: true),
    (match) {
      replacements++;
      final message = match.group(1)!.trim();

      // Determine level based on content
      String level = _determineLevel(message);

      return "appLogger.log($message, level: '$level');";
    },
  );

  // Replace print() with appLogger.log
  // Only replace print statements that look like logging (not in comments)
  content = content.replaceAllMapped(
    RegExp(r"print\((.*?)\);", multiLine: true, dotAll: true),
    (match) {
      final fullMatch = match.group(0)!;

      // Skip if in comment
      final lines = content.substring(0, match.start).split('\n');
      final lastLine = lines.last.trim();
      if (lastLine.startsWith('//')) {
        return fullMatch;
      }

      replacements++;
      final message = match.group(1)!.trim();

      // Determine level based on content
      String level = _determineLevel(message);

      return "appLogger.log($message, level: '$level');";
    },
  );

  // Write back if modified
  if (content != originalContent) {
    await file.writeAsString(content);
    return MigrationResult(modified: true, replacements: replacements);
  }

  return MigrationResult(modified: false, replacements: 0);
}

String _determineLevel(String message) {
  final lowerMessage = message.toLowerCase();

  if (lowerMessage.contains('error') ||
      lowerMessage.contains('exception') ||
      lowerMessage.contains('failed') ||
      lowerMessage.contains('❌')) {
    return 'ERROR';
  }

  if (lowerMessage.contains('warning') ||
      lowerMessage.contains('warn') ||
      lowerMessage.contains('⚠️')) {
    return 'WARNING';
  }

  if (lowerMessage.contains('success') ||
      lowerMessage.contains('✅') ||
      lowerMessage.contains('completed')) {
    return 'INFO';
  }

  if (lowerMessage.contains('debug') ||
      lowerMessage.contains('🐛')) {
    return 'DEBUG';
  }

  // Default to INFO
  return 'INFO';
}

class MigrationResult {
  final bool modified;
  final int replacements;

  MigrationResult({required this.modified, required this.replacements});
}
