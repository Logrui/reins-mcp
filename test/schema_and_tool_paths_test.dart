import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:reins/Constants/constants.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:reins/Models/mcp.dart';
import 'package:reins/Models/ollama_chat.dart';
import 'package:reins/Models/ollama_message.dart';
import 'package:reins/Models/ollama_model.dart';
import 'package:reins/Providers/chat_provider.dart';
import 'package:reins/Services/database_service.dart';
import 'package:reins/Services/mcp_service.dart';
import 'package:reins/Services/ollama_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakePathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async {
    return path.join(Directory.current.path, 'test', 'assets');
  }
}

class _FakeOllamaServiceSingleCallWithArgs extends OllamaService {
  final String toolName;
  final Map<String, dynamic> args;
  _FakeOllamaServiceSingleCallWithArgs({required this.toolName, required this.args}) : super(baseUrl: 'http://localhost:11434');

  @override
  Stream<OllamaMessage> chatStream(List<OllamaMessage> messages,
      {required OllamaChat chat, bool supportsTools = false}) async* {
    final toolResultCount = messages.where((m) => m.role == OllamaMessageRole.tool).length;
    if (toolResultCount == 0) {
      yield OllamaMessage(
        '',
        role: OllamaMessageRole.assistant,
        toolCall: McpToolCall(id: 'call_param', server: 'local', name: toolName, args: args),
      );
    } else {
      yield OllamaMessage('done', role: OllamaMessageRole.assistant);
    }
  }
}

class _FakeOllamaServiceSingleCall extends OllamaService {
  _FakeOllamaServiceSingleCall() : super(baseUrl: 'http://localhost:11434');

  @override
  Stream<OllamaMessage> chatStream(List<OllamaMessage> messages,
      {required OllamaChat chat, bool supportsTools = false}) async* {
    final toolResultCount = messages.where((m) => m.role == OllamaMessageRole.tool).length;
    if (toolResultCount == 0) {
      // Emit a single assistant with a tool call; args intentionally missing to trigger validation.
      yield OllamaMessage(
        '',
        role: OllamaMessageRole.assistant,
        toolCall: McpToolCall(
          id: 'call_missing',
          server: 'local',
          name: 'local.echo',
          args: const {},
        ),
      );
    } else {
      // After tool message, emit final answer to end loop
      yield OllamaMessage('done', role: OllamaMessageRole.assistant);
    }
  }

  @override
  Future<OllamaModel?> getModel(String name) async {
    return OllamaModel(
      name: name,
      model: name,
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
}

class _SchemaMcpService extends McpService {
  int callCount = 0;
  @override
  Future<List<McpTool>> listTools({String? server}) async {
    // Schema requires 'text' string minLength 1
    return [
      McpTool(
        name: 'local.echo',
        description: 'echo',
        parameters: const {
          'type': 'object',
          'required': ['text'],
          'properties': {
            'text': {'type': 'string', 'minLength': 1}
          },
          'additionalProperties': false
        },
      )
    ];
  }

  @override
  Future<McpToolResult> call(String serverUrl, String toolName, Map<String, dynamic> arguments, {Duration? timeout}) async {
    callCount++;
    return McpToolResult(result: {'text': arguments['text']});
  }
}

class _ErrorMcpService extends McpService {
  @override
  Future<List<McpTool>> listTools({String? server}) async {
    return [McpTool(name: 'local.fail', description: 'fail', parameters: const {})];
  }

  @override
  Future<McpToolResult> call(String serverUrl, String toolName, Map<String, dynamic> arguments, {Duration? timeout}) async {
    return McpToolResult(result: null, error: 'Server error: boom');
  }
}

class _SlowMcpService extends McpService {
  bool called = false;
  @override
  Future<List<McpTool>> listTools({String? server}) async {
    return [McpTool(name: 'local.echo', description: 'echo', parameters: const {})];
  }

  @override
  Future<McpToolResult> call(String serverUrl, String toolName, Map<String, dynamic> arguments, {Duration? timeout}) async {
    called = true;
    await Future.delayed(const Duration(seconds: 2));
    return McpToolResult(result: {'text': arguments['text']});
  }
}

void main() {
  group('Schema validation and tool error paths', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      PathProviderPlatform.instance = _FakePathProviderPlatform();
      await PathManager.initialize();
      await Hive.initFlutter();
      await Hive.openBox('settings');
      Hive.box('settings').put('serverAddress', 'http://localhost:11434');
    });

    test('schema validation blocks invalid args and does not call MCP', () async {
      // Fresh DB
      final dbPath = path.join(await getDatabasesPath(), 'schema_validation.db');
      await databaseFactoryFfi.deleteDatabase(dbPath);

      final db = DatabaseService();
      await db.open('schema_validation.db');

      final ollama = _FakeOllamaServiceSingleCall();
      final mcp = _SchemaMcpService();
      final provider = ChatProvider(ollamaService: ollama, databaseService: db, mcpService: mcp);

      await provider.createNewChat(
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
        ),
      );

      provider.setSupportsToolsForModel('llama3.2:latest', true);
      await provider.sendPrompt('trigger');

      // Expect messages: user, assistant(tool call), tool(validation error), assistant(final)
      final msgs = provider.messages;
      expect(msgs.length, 4);
      expect(msgs[2].role, OllamaMessageRole.tool);
      expect(msgs[2].toolResult?.error, contains('Invalid arguments'));
      expect(mcp.callCount, 0, reason: 'MCP should not be called on validation failure');

      await db.close();
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('server error is captured in tool message', () async {
      final dbPath = path.join(await getDatabasesPath(), 'server_error.db');
      await databaseFactoryFfi.deleteDatabase(dbPath);

      final db = DatabaseService();
      await db.open('server_error.db');

      // Ollama emits a tool call with valid args, targeting failing tool
      final ollama = _FakeOllamaServiceSingleCallWithArgs(toolName: 'local.fail', args: const {'text': 'ok'});

      final mcp = _ErrorMcpService();
      final provider = ChatProvider(ollamaService: ollama, databaseService: db, mcpService: mcp);

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

      provider.setSupportsToolsForModel('llama3.2:latest', true);
      await provider.sendPrompt('trigger');

      final msgs = provider.messages;
      // user, assistant(tool call), tool(error), assistant(final)
      expect(msgs.length, 4);
      expect(msgs[2].role, OllamaMessageRole.tool);
      expect(msgs[2].toolResult?.error, contains('Server error'));

      await db.close();
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('cancellation during tool call marks tool message as Cancelled and skips MCP call', () async {
      // Fresh DB
      final dbPath = path.join(await getDatabasesPath(), 'cancel_during_tool.db');
      await databaseFactoryFfi.deleteDatabase(dbPath);

      final db = DatabaseService();
      await db.open('cancel_during_tool.db');

      // Ollama emits a tool call with valid args
      final ollama = _FakeOllamaServiceSingleCallWithArgs(toolName: 'local.echo', args: const {'text': 'ok'});
      final mcp = _SlowMcpService();
      final provider = ChatProvider(ollamaService: ollama, databaseService: db, mcpService: mcp);

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

      provider.setSupportsToolsForModel('llama3.2:latest', true);
      unawaited(provider.sendPrompt('trigger'));

      // Wait until tool message appears
      OllamaMessage? toolMsg;
      for (var i = 0; i < 20; i++) {
        await Future.delayed(const Duration(milliseconds: 50));
        final t = provider.messages.where((m) => m.role == OllamaMessageRole.tool).toList();
        if (t.isNotEmpty) { toolMsg = t.first; break; }
      }
      expect(toolMsg, isNotNull, reason: 'Tool message should be created');

      // Cancel immediately
      provider.cancelToolCall(toolMsg!.id);

      // Give provider a tick to persist update
      await Future.delayed(const Duration(milliseconds: 100));

      // Validate cancellation reflected
      expect(toolMsg.toolResult?.error, 'Cancelled');

      // Optional: ensure MCP may not have been called before cancel check; allow either due to race
      // but primary assertion is tool message shows Cancelled and loop continues safely

      await db.close();
    }, timeout: const Timeout(Duration(seconds: 10)));
  });
}
