import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reins/Constants/constants.dart';
import 'package:reins/Models/mcp.dart';
import 'package:reins/Models/ollama_chat.dart';
import 'package:reins/Models/ollama_message.dart';
import 'package:reins/Models/ollama_model.dart';
import 'package:uuid/uuid.dart';
import 'package:reins/Providers/chat_provider.dart';
import 'package:reins/Services/database_service.dart';
import 'package:reins/Services/mcp_service.dart';
import 'package:reins/Services/ollama_service.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:hive_flutter/hive_flutter.dart';

class _FakeOllamaService extends OllamaService {
  int chatStreamCalls = 0;

  _FakeOllamaService() : super(baseUrl: 'http://localhost:11434');

  @override
  Stream<OllamaMessage> chatStream(List<OllamaMessage> messages,
      {required OllamaChat chat, bool supportsTools = false}) async* {
    chatStreamCalls++;

    final toolResultCount = messages.where((m) => m.role == OllamaMessageRole.tool).length;

    if (toolResultCount == 0) {
      // 1. First call: no tool results yet. Ask to echo 'first'.
      yield OllamaMessage(
        '',
        role: OllamaMessageRole.assistant,
        toolCall: McpToolCall(
          id: 'call_1',
          server: 'local',
          name: 'local.echo',
          args: {'text': 'first'},
        ),
      );
    } else if (toolResultCount == 1) {
      // 2. Second call: has one tool result. Ask to echo 'second'.
      yield OllamaMessage(
        '',
        role: OllamaMessageRole.assistant,
        toolCall: McpToolCall(
          id: 'call_2',
          server: 'local',
          name: 'local.echo',
          args: {'text': 'second'},
        ),
      );
    } else {
      // 3. Third call: has two tool results. Return final answer.
      yield OllamaMessage('Final response: second', role: OllamaMessageRole.assistant);
    }
  }

  @override
  Future<List<OllamaModel>> listModelsWithCaps() async {
    // Provide a dummy model list so UI bits relying on tools badges won't break
    return [
      OllamaModel(
        name: 'llama3.2:latest',
        model: 'llama3.2:latest',
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
  Future<OllamaModel?> getModel(String name) async {
    if (name == 'llama3.2:latest') {
      return OllamaModel(
        name: 'llama3.2:latest',
        model: 'llama3.2:latest',
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
      );
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
  Future<McpToolResult> call(String serverUrl, String toolName, Map<String, dynamic> arguments, {Duration? timeout}) async {
    // Mimic echo tool returning the text argument
    final response = McpResponse(id: Uuid().v4(), result: {'text': arguments['text']});
    return McpToolResult(result: response.result);
  }
}

void main() {
  group('ChatProvider tool-call orchestration', () {
    late _FakeOllamaService ollama;
    late DatabaseService db;
    late _StubMcpService mcp;
    late ChatProvider provider;

    setUpAll(() async {
      // Initialize FFI for sqflite in tests and set a fake documents directory
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      PathProviderPlatform.instance = _FakePathProviderPlatform();
      await PathManager.initialize();
      // Initialize Hive and open settings box used by ChatProvider
      await Hive.initFlutter();
      await Hive.openBox('settings');
      Hive.box('settings').put('serverAddress', 'http://localhost:11434');
      // Ensure a clean DB
      final dbPath = path.join(await getDatabasesPath(), 'provider_tool_flow.db');
      await databaseFactoryFfi.deleteDatabase(dbPath);
    });

    setUp(() async {
      ollama = _FakeOllamaService();
      db = DatabaseService();
      mcp = _StubMcpService();

      // Open test database (DatabaseService will place it under getDatabasesPath)
      await db.open('provider_tool_flow.db');

      provider = ChatProvider(
        ollamaService: ollama,
        databaseService: db,
        mcpService: mcp,
      );

      // Create a chat and select it
      await provider.createNewChat(OllamaModel(
        name: 'llama3.2:latest',
        model: 'llama3.2:latest',
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

    tearDown(() async {
      await db.close();
    });

    test('handles multiple sequential tool calls and provides a final answer', () async {

      // Send a prompt that will trigger the multi-call sequence in the fake service.
      // Ensure the provider will use the structured tools path.
      provider.setSupportsToolsForModel('llama3.2:latest', true);
      await provider.sendPrompt('Trigger multi-tool call');

      final msgs = provider.messages;
      expect(msgs.length, 6, reason: "Should have 6 messages: user, assistant, tool, assistant, tool, assistant");

      // 1. User prompt
      expect(msgs[0].role, OllamaMessageRole.user);

      // 2. First assistant message (tool call 1)
      expect(msgs[1].role, OllamaMessageRole.assistant);
      expect(msgs[1].toolCall?.args['text'], 'first');

      // 3. First tool result
      expect(msgs[2].role, OllamaMessageRole.tool);
      expect(msgs[2].toolResult?.result['text'], 'first');

      // 4. Second assistant message (tool call 2)
      expect(msgs[3].role, OllamaMessageRole.assistant);
      expect(msgs[3].toolCall?.args['text'], 'second');

      // 5. Second tool result
      expect(msgs[4].role, OllamaMessageRole.tool);
      expect(msgs[4].toolResult?.result['text'], 'second');

      // 6. Final assistant message
      expect(msgs[5].role, OllamaMessageRole.assistant);
      expect(msgs[5].content, 'Final response: second');

      // Ensure Ollama service was called three times
      expect(ollama.chatStreamCalls, equals(3));
    }, timeout: Timeout(Duration(seconds: 10)));
  });
}

class _FakePathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async {
    return path.join(Directory.current.path, 'test', 'assets');
  }
}
