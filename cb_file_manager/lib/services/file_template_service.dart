import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:cb_file_manager/models/file_template.dart';
import 'package:cb_file_manager/helpers/files/external_app_helper.dart';
import 'package:cb_file_manager/helpers/files/windows_app_icon.dart';

/// Central service that combines brand detection with file templates.
/// Manages brand detection across all platforms and provides filtered
/// template lists for the create-file dialog.
class FileTemplateService {
  FileTemplateService._();
  static final FileTemplateService instance = FileTemplateService._();

  bool _initialized = false;
  Set<String> _detectedBrands = {};

  /// Must be called before using getAvailableTemplates().
  /// Safe to call multiple times.
  Future<void> init() async {
    if (_initialized) return;
    _detectedBrands = await _detectInstalledBrands();
    _initialized = true;
    debugPrint('[FileTemplateService] Detected brands: $_detectedBrands');
  }

  /// Returns the set of detected brand IDs (e.g. {'microsoft', 'libre', 'wps'}).
  Set<String> get detectedBrands => Set.unmodifiable(_detectedBrands);

  Future<Set<String>> _detectInstalledBrands() async {
    if (Platform.isAndroid) {
      return ExternalAppHelper.getInstalledBrands();
    } else if (Platform.isWindows) {
      return WindowsAppIcon.getInstalledBrands();
    } else if (Platform.isMacOS) {
      return MacosAppHelper.getInstalledBrands();
    } else if (Platform.isIOS) {
      return IosAppHelper.getInstalledBrands();
    }
    return {};
  }

  /// Returns all available templates filtered by detected brands.
  /// Brand-specific templates are only shown if their brand was detected.
  List<FileTemplate> getAvailableTemplates() {
    return allFileTemplates.where((t) {
      if (t.brand == FileTemplateBrand.generic) return true;
      return _detectedBrands.contains(_brandToId(t.brand));
    }).toList();
  }

  /// Returns templates grouped by category for display.
  Map<FileTemplateCategory, List<FileTemplate>> getGroupedTemplates() {
    final templates = getAvailableTemplates();
    final grouped = <FileTemplateCategory, List<FileTemplate>>{};
    for (final t in templates) {
      grouped.putIfAbsent(t.category, () => []).add(t);
    }
    return grouped;
  }

  /// Creates an empty file from a template in the given directory.
  /// If a file with the same name exists, auto-increments suffix (1), (2), etc.
  /// Returns the created file path, or null on failure.
  Future<String?> createFile(
    String directoryPath,
    FileTemplate template,
    String customFileName,
  ) async {
    final separator = Platform.isWindows ? r'\' : '/';
    final sanitized = customFileName.trim();
    if (sanitized.isEmpty) return null;

    // Ensure the file name ends with the correct extension
    String finalName = sanitized;
    if (!sanitized.toLowerCase().endsWith(template.extension.toLowerCase())) {
      finalName = '$sanitized${template.extension}';
    }

    final filePath = '$directoryPath$separator$finalName';

    try {
      final file = File(filePath);
      if (await file.exists()) {
        // Try with incremental suffix: (1), (2), (3)...
        final baseName = path.basenameWithoutExtension(finalName);
        final ext = path.extension(finalName);
        for (int i = 1; i <= 999; i++) {
          final candidateName = '$baseName ($i)$ext';
          final candidatePath = '$directoryPath$separator$candidateName';
          final candidateFile = File(candidatePath);
          if (!await candidateFile.exists()) {
            await candidateFile.create(exclusive: true);
            return candidatePath;
          }
        }
        // All suffixes exhausted
        return null;
      }
      await file.create(exclusive: true);
      return filePath;
    } catch (e) {
      debugPrint('[FileTemplateService] Failed to create file: $e');
      return null;
    }
  }

  static String _brandToId(FileTemplateBrand brand) {
    switch (brand) {
      case FileTemplateBrand.microsoft:
        return 'microsoft';
      case FileTemplateBrand.libre:
        return 'libre';
      case FileTemplateBrand.wps:
        return 'wps';
      case FileTemplateBrand.google:
        return 'google';
      case FileTemplateBrand.generic:
        return 'generic';
    }
  }
}

/// macOS brand detection — scans /Applications for known app bundles.
class MacosAppHelper {
  MacosAppHelper._();

  static Future<Set<String>> getInstalledBrands() async {
    if (!Platform.isMacOS) return {};

    try {
      final appsDir = Directory('/Applications');
      if (!appsDir.existsSync()) return {};

      final brands = <String>{};
      final entries = appsDir.listSync();

      for (final entity in entries) {
        if (entity is! Directory) continue;
        final name = entity.path.split('/').last.toLowerCase();

        if (name.contains('microsoft word') ||
            name.contains('microsoft excel') ||
            name.contains('microsoft powerpoint') ||
            name.contains('word.app') ||
            name.contains('excel.app') ||
            name.contains('powerpoint.app')) {
          brands.add('microsoft');
        }
        if (name.contains('libreoffice') || name.contains('libre office')) {
          brands.add('libre');
        }
        if (name.contains('wps office') || name.contains('wps office.app')) {
          brands.add('wps');
        }
      }

      return brands;
    } catch (e) {
      debugPrint('[MacosAppHelper] Error scanning applications: $e');
      return {};
    }
  }
}

/// iOS stub — sandbox prevents brand detection; always returns empty set.
class IosAppHelper {
  IosAppHelper._();

  static Future<Set<String>> getInstalledBrands() async {
    return {};
  }
}
