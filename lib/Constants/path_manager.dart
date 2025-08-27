import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';

class PathManager {
  static final PathManager _instance = PathManager._internal();
  late final Directory documentsDirectory;

  PathManager._internal();

  static Future<void> initialize() async {
    if (kIsWeb) {
      // No documents directory on Web; skip initialization
      return;
    }

    final directory = await getApplicationDocumentsDirectory();
    _instance.documentsDirectory = directory;
  }

  static PathManager get instance => _instance;
}
