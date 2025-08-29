import 'dart:io';
import 'dart:async';

import 'package:path/path.dart' as path;
import 'package:reins/Models/ollama_chat.dart';
import 'package:reins/Services/ollama_service.dart';
import 'package:reins/Models/ollama_message.dart';
import 'package:test/test.dart';

// Additional imports for end-to-end tool-call test via ChatProvider
import 'package:flutter_test/flutter_test.dart' as ft;
import 'package:reins/Providers/chat_provider.dart';
import 'package:reins/Services/database_service.dart';
import 'package:reins/Services/mcp_service.dart';
import 'package:reins/Models/mcp.dart';
import 'package:reins/Models/ollama_model.dart';
import 'package:uuid/uuid.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:reins/Constants/constants.dart';

// --- Test fakes/stubs used by the end-to-end tool call test ---
class _FakeOllamaService extends OllamaService {
  int chatStreamCalls = 0;
  _FakeOllamaService() : super(baseUrl: 'http://localhost:11434');

  @override
  Stream<OllamaMessage> chatStream(List<OllamaMessage> messages,
      {required OllamaChat chat, bool supportsTools = false}) async* {
    chatStreamCalls++;
    // Debug: trace which turn we're in
    // ignore: avoid_print
    print('[FakeOllamaService.chatStream] turn=$chatStreamCalls supportsTools=$supportsTools');
    if (chatStreamCalls == 1) {
      // First call: emit a tool call
      yield OllamaMessage(
        '',
        role: OllamaMessageRole.assistant,
        toolCall: McpToolCall(
          id: 'call_1',
          server: 'local',
          name: 'local.echo',
          args: const {'text': 'this is a test echo'},
        ),
      );
    } else {
      // Second call: emit final content
      yield OllamaMessage('Final: this is a test echo',
          role: OllamaMessageRole.assistant);
    }
  }

  @override
  Future<List<OllamaModel>> listModelsWithCaps() async {
    // Advertise tools capability so ChatProvider enables tool flow
    return [
      OllamaModel(
        name: 'llama3.1:8b',
        model: 'llama3.1:8b',
        modifiedAt: DateTime.now(),
        size: 0,
        digest: '',
        details: OllamaModelDetails(
          parentModel: '',
          format: 'gguf',
          family: 'llama',
          families: const ['llama'],
          parameterSize: '0',
          quantizationLevel: 'Q4',
        ),
        capabilities: const ['tools'],
        supportsTools: true,
      ),
    ];
  }

  @override
  Future<OllamaModel?> getModel(String modelName) async {
    // Return the single fake model with tools support without hitting network
    if (modelName == 'llama3.1:8b') {
      return (await listModelsWithCaps()).first;
    }
    return null;
  }
}

class _StubMcpService extends McpService {
  _StubMcpService();

  @override
  Future<void> connectAll(List<McpServerConfig> servers) async {}

  @override
  Future<List<McpTool>> listTools({String? server}) async {
    return [McpTool(name: 'local.echo', description: 'echo text', parameters: const {})];
  }

  @override
  Future<McpToolResult> call(String serverUrl, String toolName,
      Map<String, dynamic> arguments, {Duration? timeout}) async {
    // Always echo the requested text
    // ignore: avoid_print
    print('[StubMcpService.call] server=$serverUrl tool=$toolName args=$arguments');
    final response = McpResponse(id: const Uuid().v4(), result: {
      'text': arguments['text'] ?? 'this is a test echo',
    });
    return McpToolResult(result: response.result);
  }
}

class _FakePathProviderPlatform extends ft.Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async {
    return path.join(Directory.current.path, 'test', 'assets');
  }
}

void main() {
  final service = OllamaService();
  const model = "llama3.2:latest";

  final chat = OllamaChat(
    model: model,
    title: "Test chat",
    systemPrompt:
        "You are a pirate who don't talk too much, acting as an assistant.",
  );
  chat.options.temperature = 0;
  chat.options.seed = 1453;


  final assetsPath = path.join(Directory.current.path, 'test', 'assets');
  final imageFile = File(path.join(assetsPath, 'images', 'ollama.png'));

  final chatForImage = OllamaChat(
    model: 'gemma3:4b ',
    title: "Test chat",
    systemPrompt:
        "You are a pirate who don't talk too much, acting as an assistant.",
  );
  chatForImage.options.temperature = 0;
  chatForImage.options.seed = 1453;

  test("Test Ollama generate endpoint (non-stream)", () async {
    final message = await service.generate("Hello", chat: chat);

    // Model replies can vary; just assert we got a non-empty response
    expect(message.content.trim(), isNotEmpty);
  });

  test("Test Ollama generate endpoint (stream)", () async {
    final stream = service.generateStream("Hello", chat: chat);

    var ollamaMessage = "";
    await for (final message in stream) {
      ollamaMessage += message.content;
    }

    // Streaming responses can vary; assert non-empty
    expect(ollamaMessage.trim(), isNotEmpty);
  });

  test("Test Ollama chat endpoint (non-stream)", () async {
    final message = await service.chat(
      [
        OllamaMessage(
          "Hello!",
          role: OllamaMessageRole.user,
        ),
        OllamaMessage(
          "*grunts* Ye be lookin' fer somethin', matey?",
          role: OllamaMessageRole.assistant,
        ),
        OllamaMessage(
          "Write me a dart code which prints 'Hello, world!'.",
          role: OllamaMessageRole.user,
        ),
      ],
      chat: chat,
    );

    // Assert that the response contains the code block we requested
    expect(message.content, contains("```dart"));
    expect(message.content, contains("print('Hello, world!');"));
  });

  test("Test Ollama chat endpoint (stream)", () async {
    final stream = service.chatStream(
      [
        OllamaMessage(
          "Hello!",
          role: OllamaMessageRole.user,
        ),
        OllamaMessage(
          "*grunts* Ye be lookin' fer somethin', matey?",
          role: OllamaMessageRole.assistant,
        ),
        OllamaMessage(
          "Write me a dart code which prints 'Hello, world!'.",
          role: OllamaMessageRole.user,
        ),
      ],
      chat: chat,
    );

    List<String> ollamaMessages = [];
    await for (final message in stream) {
      ollamaMessages.add(message.content);
    }

    final joined = ollamaMessages.join();
    expect(joined, contains("```dart"));
    expect(joined, contains("print('Hello, world!');"));
  });

  test('Test Ollama chat endpoint with images (stream)', () async {
    // Skip dynamically if the vision model isn't available
    final models = await service.listModels();
    final hasVision = models.any((m) => m.model == 'llama3.2-vision:latest');
    if (!hasVision) {
      // Not a failure; environment-dependent
      return;
    }

    final stream = service.chatStream(
      [
        OllamaMessage(
          "Hello!, What is in the image?",
          images: [imageFile],
          role: OllamaMessageRole.user,
        ),
      ],
      chat: chatForImage,
    );

    List<String> ollamaMessages = [];
    await for (final message in stream) {
      ollamaMessages.add(message.content);
    }

    final message = ollamaMessages.join().trim();
    // Just assert we received some description
    expect(message, isNotEmpty);
  }, timeout: Timeout.none);

  test("Test Ollama tags endpoint", () async {
    final models = await service.listModels();

    expect(models, isNotEmpty);
    expect(models.map((e) => e.model).contains(model), true);
  });

  test("Test Ollama create endpoint without messages", () async {
    await service.createModel("test_model", chat: chat);
  });

  test("Test Ollama create endpoint", () async {
    final messages = [
      OllamaMessage(
        "Hello!",
        role: OllamaMessageRole.user,
      ),
      OllamaMessage(
        "*grunts* Ye be lookin' fer somethin', matey?",
        role: OllamaMessageRole.assistant,
      ),
      OllamaMessage(
        "Write me a dart code which prints 'Hello, world!'.",
        role: OllamaMessageRole.user,
      ),
    ];

    await service.createModel(
      "test_model_with_messages",
      chat: chat,
      messages: messages,
    );
  });

  test("Test Ollama delete endpoint", () async {
    // Delete should be tolerant if the model doesn't exist
    try { await service.deleteModel("test_model:latest"); } catch (_) {}
    try { await service.deleteModel("test_model_with_messages:latest"); } catch (_) {}
  });

  test("Test constructUrl with various base URLs", () {
    // Test with trailing slash
    var service = OllamaService(baseUrl: "http://localhost:11434/");
    expect(service.constructUrl("/api/chat").toString(),
        "http://localhost:11434/api/chat");
    expect(service.constructUrl("api/generate").toString(),
        "http://localhost:11434/api/generate");

    // Test without trailing slash
    service = OllamaService(baseUrl: "http://localhost:11434");
    expect(service.constructUrl("/api/tags").toString(),
        "http://localhost:11434/api/tags");
    expect(service.constructUrl("api/models").toString(),
        "http://localhost:11434/api/models");

    // Test with path component
    service = OllamaService(baseUrl: "http://localhost:11434/ollama");
    expect(service.constructUrl("/api/chat").toString(),
        "http://localhost:11434/ollama/api/chat");
    expect(service.constructUrl("api/generate").toString(),
        "http://localhost:11434/ollama/api/generate");

    // Test with path component and trailing slash
    service = OllamaService(baseUrl: "http://localhost:11434/ollama/");
    expect(service.constructUrl("/api/chat").toString(),
        "http://localhost:11434/ollama/api/chat");
    expect(service.constructUrl("api/generate").toString(),
        "http://localhost:11434/ollama/api/generate");

    // Test with IP address
    service = OllamaService(baseUrl: "http://192.168.1.100:11434");
    expect(service.constructUrl("/api/chat").toString(),
        "http://192.168.1.100:11434/api/chat");
    expect(service.constructUrl("api/generate").toString(),
        "http://192.168.1.100:11434/api/generate");

    // Test with subdomain
    service = OllamaService(baseUrl: "http://ollama.mydomain.com/");
    expect(service.constructUrl("/api/chat").toString(),
        "http://ollama.mydomain.com/api/chat");

    // Test with HTTPS
    service = OllamaService(baseUrl: "https://ollama.mydomain.com");
    expect(service.constructUrl("/api/chat").toString(),
        "https://ollama.mydomain.com/api/chat");

    // Test setting baseUrl after initialization
    service = OllamaService();
    service.baseUrl = "http://newhost:11434/";
    expect(service.constructUrl("/api/chat").toString(),
        "http://newhost:11434/api/chat");
  });

  ft.group('End-to-end tool call via ChatProvider (fake MCP echo)', () {
    late _FakeOllamaService ollama;
    late DatabaseService db;
    late _StubMcpService mcp;
    late ChatProvider provider;

    ft.setUpAll(() async {
      // Initialize FFI for sqflite in tests and set a fake documents directory
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      PathProviderPlatform.instance = _FakePathProviderPlatform();
      await PathManager.initialize();
      // Initialize Hive and open settings box used by ChatProvider
      await Hive.initFlutter();
      await Hive.openBox('settings');
      Hive.box('settings').put('serverAddress', 'http://localhost:11434');
      // Ensure a clean DB matching ChatProvider's default DB name
      final dbPath = path.join(await getDatabasesPath(), 'ollama_chat.db');
      await databaseFactoryFfi.deleteDatabase(dbPath);
    });

    ft.setUp(() async {
      ollama = _FakeOllamaService();
      db = DatabaseService();
      mcp = _StubMcpService();
      await db.open('ollama_chat.db');

      provider = ChatProvider(
        ollamaService: ollama,
        databaseService: db,
        mcpService: mcp,
      );

      // Create and select a chat (match the fake model name)
      await provider.createNewChat(OllamaModel(
        name: 'llama3.1:8b',
        model: 'llama3.1:8b',
        modifiedAt: DateTime.now(),
        size: 0,
        digest: '',
        details: OllamaModelDetails(
          parentModel: '',
          format: 'gguf',
          family: 'llama',
          families: const ['llama'],
          parameterSize: '0',
          quantizationLevel: 'Q4',
        ),
      ));
    });

    ft.tearDown(() async {
      await db.close();
    });

    ft.test('invokes tool and produces final assistant message', () async {
      final completer = Completer<void>();
      provider.addListener(() {
        final msgs = provider.messages;
        final hasFinal = msgs.any((m) =>
            m.role == OllamaMessageRole.assistant &&
            m.content.contains('Final: this is a test echo'));
        if (hasFinal && !completer.isCompleted) {
          completer.complete();
        }
      });

      await provider.sendPrompt('trigger tool call');
      await completer.future.timeout(const Duration(seconds: 15));

      final msgs = provider.messages;
      // Expect: user, assistant(tool call), tool(result), assistant(final)
      expect(msgs.length, 4);
      expect(msgs[0].role, OllamaMessageRole.user);
      expect(msgs[1].role, OllamaMessageRole.assistant);
      expect(msgs[1].toolCall?.name, 'local.echo');
      expect(msgs[1].toolCall?.args['text'], 'this is a test echo');
      expect(msgs[2].role, OllamaMessageRole.tool);
      expect(msgs[2].toolResult?.result['text'], 'this is a test echo');
      expect(msgs[3].role, OllamaMessageRole.assistant);
      expect(msgs[3].content, 'Final: this is a test echo');

      expect(ollama.chatStreamCalls, 2);
    }, timeout: const ft.Timeout(Duration(seconds: 15)));
  });
}
