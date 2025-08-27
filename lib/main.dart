import 'package:flutter/material.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:reins/Constants/constants.dart';
import 'package:reins/Models/settings_route_arguments.dart';
import 'package:reins/Pages/main_page.dart';
import 'package:reins/Pages/settings_page/settings_page.dart';
import 'package:reins/Providers/chat_provider.dart';
import 'package:reins/Services/database_service.dart';
import 'package:reins/Services/mcp_service.dart';
import 'package:reins/Services/ollama_service.dart';
import 'package:reins/Models/mcp.dart';
import 'package:reins/Utils/material_color_adapter.dart';
import 'package:provider/provider.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:reins/Utils/request_review_helper.dart';
import 'package:responsive_framework/responsive_framework.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:io' show Platform;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Global guards: log errors instead of crashing the app window on startup
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.dumpErrorToConsole(details);
  };

  if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  // Initialize Hive
  await Hive.initFlutter();

  // Register the MaterialColorAdapter
  Hive.registerAdapter(MaterialColorAdapter());

  // Open the settings box
  await Hive.openBox('settings');

  // Initialize singleton instances
  if (!kIsWeb) {
    await PathManager.initialize();
  }
  final reviewHelper = await RequestReviewHelper.initialize();

  // Increment the launch count
  await reviewHelper.incrementCount(isLaunch: true);

  // Request a review if available
  final inAppReview = InAppReview.instance;
  if (await inAppReview.isAvailable() && reviewHelper.shouldRequestReview()) {
    await inAppReview.requestReview();
  }

  // Prepare MCP service (defer connections until after first frame)
  final mcpService = McpService();

  runApp(
    MultiProvider(
      providers: [
        Provider(create: (_) => OllamaService()),
        Provider(create: (_) => DatabaseService()),
        ChangeNotifierProvider.value(value: mcpService),
        ChangeNotifierProvider(
          create: (context) => ChatProvider(
            ollamaService: context.read(),
            databaseService: context.read(),
            mcpService: context.read(),
          ),
        ),
      ],
      child: const ReinsApp(),
    ),
  );

  // Defer MCP connect so the window paints even if MCP is misconfigured
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    try {
      final settings = Hive.box('settings');
      final List<dynamic> rawServers = settings.get('mcpServers', defaultValue: <dynamic>[]);
      final mcpConfigs = rawServers
          .whereType<Map>()
          .map((m) => McpServerConfig.fromJson(m.cast<String, dynamic>()))
          .toList();
      if (mcpConfigs.isNotEmpty) {
        await mcpService.connectAll(mcpConfigs);
        await mcpService.listTools();
      }
    } catch (e, st) {
      // Swallow errors to avoid taking down the UI; logs visible in console
      debugPrint('Deferred MCP connect failed: $e\n$st');
    }
  });
}

class ReinsApp extends StatelessWidget {
  const ReinsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: Hive.box('settings').listenable(
        keys: ['color', 'brightness'],
      ),
      builder: (context, box, _) {
        return MaterialApp(
          title: AppConstants.appName,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              brightness: _brightness ?? MediaQuery.platformBrightnessOf(context),
              dynamicSchemeVariant: DynamicSchemeVariant.neutral,
              seedColor: box.get('color', defaultValue: Colors.grey),
            ),
            appBarTheme: const AppBarTheme(centerTitle: true),
            useMaterial3: true,
          ),
          builder: (context, child) => ResponsiveBreakpoints.builder(
            breakpoints: [
              const Breakpoint(start: 0, end: 450, name: MOBILE),
              const Breakpoint(start: 451, end: 800, name: TABLET),
              const Breakpoint(start: 801, end: 1920, name: DESKTOP),
            ],
            useShortestSide: true,
            child: child!,
          ),
          onGenerateRoute: (settings) {
            if (settings.name == '/') {
              return MaterialPageRoute(
                builder: (context) => const ReinsMainPage(),
              );
            }

            if (settings.name == '/settings') {
              final args = settings.arguments as SettingsRouteArguments?;

              return MaterialPageRoute(
                builder: (context) => SettingsPage(arguments: args),
              );
            }

            assert(false, 'Need to implement ${settings.name}');
            return null;
          },
        );
      },
    );
  }

  Brightness? get _brightness {
    final brightnessValue = Hive.box('settings').get('brightness');
    if (brightnessValue == null) return null;
    return brightnessValue == 1 ? Brightness.light : Brightness.dark;
  }
}
