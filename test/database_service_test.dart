import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reins/Constants/constants.dart';
import 'package:reins/Models/mcp.dart';
import 'package:reins/Models/ollama_chat.dart';
import 'package:reins/Models/ollama_message.dart';
import 'package:reins/Services/database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as path;

import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

void main() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  PathProviderPlatform.instance = FakePathProviderPlatform();
  await PathManager.initialize();

  final databasePath = path.join(await getDatabasesPath(), 'test_database.db');
  await databaseFactoryFfi.deleteDatabase(databasePath);

  final service = DatabaseService();
  await service.open('test_database.db');

  const model = "llama3.2";

  final assetsPath = path.join(Directory.current.path, 'test', 'assets');
  final imageFile = File(path.join(assetsPath, 'images', 'ollama.png'));

  test("Test database open", () async {
    await service.open('test_database.db');
  });

  test('Persist cancelled tool call result', () async {
    final chat = await service.createChat(model);
    final toolCall = McpToolCall(
      id: 'call-2',
      server: 'dummy',
      name: 'echo',
      args: {'text': 'bye'},
    );

    final toolMessage = OllamaMessage(
      '',
      role: OllamaMessageRole.tool,
      toolCall: toolCall,
    );
    await service.addMessage(toolMessage, chat: chat);

    final cancelled = McpToolResult(result: null, error: 'Cancelled');
    toolMessage.toolResult = cancelled;
    toolMessage.content = 'Tool call cancelled by user.';
    await service.updateMessage(
      toolMessage,
      newContent: toolMessage.content,
      newToolResult: cancelled,
    );

    final retrieved = await service.getMessage(toolMessage.id);
    expect(retrieved, isNotNull);
    expect(retrieved!.role, OllamaMessageRole.tool);
    expect(retrieved.toolResult, isNotNull);
    expect(retrieved.toolResult!.error, 'Cancelled');
  });

  test('Persist error tool call result', () async {
    final chat = await service.createChat(model);
    final toolCall = McpToolCall(
      id: 'call-3',
      server: 'dummy',
      name: 'explode',
      args: {'text': 'boom'},
    );

    final toolMessage = OllamaMessage(
      '',
      role: OllamaMessageRole.tool,
      toolCall: toolCall,
    );
    await service.addMessage(toolMessage, chat: chat);

    final errorRes = McpToolResult(result: null, error: 'Some error');
    toolMessage.toolResult = errorRes;
    toolMessage.content = 'Tool returned: Some error';
    await service.updateMessage(
      toolMessage,
      newContent: toolMessage.content,
      newToolResult: errorRes,
    );

    final retrieved = await service.getMessage(toolMessage.id);
    expect(retrieved, isNotNull);
    expect(retrieved!.role, OllamaMessageRole.tool);
    expect(retrieved.toolResult, isNotNull);
    expect(retrieved.toolResult!.error, 'Some error');
  });

  test('Persist and load tool role with tool_call and tool_result', () async {
    final chat = await service.createChat(model);
    final toolCall = McpToolCall(
      id: 'call-1',
      server: 'dummy',
      name: 'echo',
      args: {'text': 'hello'},
    );

    // Create tool message with call
    final toolMessage = OllamaMessage(
      '',
      role: OllamaMessageRole.tool,
      toolCall: toolCall,
    );

    await service.addMessage(toolMessage, chat: chat);

    // Update with a result
    final result = McpToolResult(result: {'ok': true, 'echo': 'hello'});
    toolMessage.toolResult = result;
    toolMessage.content = 'Tool returned: {ok: true, echo: hello}';
    await service.updateMessage(
      toolMessage,
      newContent: toolMessage.content,
      newToolResult: result,
    );

    final retrieved = await service.getMessage(toolMessage.id);
    expect(retrieved, isNotNull);
    expect(retrieved!.role, OllamaMessageRole.tool);
    expect(retrieved.toolCall, isNotNull);
    expect(retrieved.toolCall!.name, 'echo');
    expect(retrieved.toolResult, isNotNull);
    expect(retrieved.toolResult!.result, isNotNull);
    expect((retrieved.toolResult!.result as Map)['ok'], true);
  });

  test("Test database create chat", () async {
    final chat = await service.createChat(model);

    expect(chat.id, isNotEmpty);
    expect(chat.model, model);
    expect(chat.title, "New Chat");
    expect(chat.systemPrompt, isNull);
    expect(chat.options.toJson(), OllamaChatOptions().toJson());
  });

  test("Test database get chat", () async {
    final chat = await service.createChat(model);

    final retrievedChat = (await service.getChat(chat.id))!;
    expect(retrievedChat.id, chat.id);
    expect(retrievedChat.model, chat.model);
    expect(retrievedChat.title, chat.title);
    expect(retrievedChat.systemPrompt, chat.systemPrompt);
    expect(retrievedChat.options.toJson(), chat.options.toJson());
  });

  test("Test database update chat title", () async {
    final chat = await service.createChat(model);

    await service.updateChat(chat, newModel: "llama3.2");

    final updatedChat = (await service.getChat(chat.id))!;
    expect(updatedChat.model, "llama3.2");
    expect(updatedChat.title, "New Chat");
    expect(updatedChat.systemPrompt, isNull);
    expect(chat.options.toJson(), OllamaChatOptions().toJson());
  });

  test('Test database update chat system prompt', () async {
    const systemPrompt =
        "You are Mario from super mario bros, acting as an assistant.";

    final chat = await service.createChat(model);

    await service.updateChat(
      chat,
      newSystemPrompt: systemPrompt,
    );

    final updatedChat = (await service.getChat(chat.id))!;
    expect(updatedChat.model, model);
    expect(updatedChat.title, "New Chat");
    expect(updatedChat.systemPrompt, systemPrompt);
    expect(chat.options.toJson(), OllamaChatOptions().toJson());

    await service.updateChat(updatedChat, newSystemPrompt: null);
  });

  test('Test database update chat options', () async {
    final chat = await service.createChat(model);

    await service.updateChat(
      chat,
      newOptions: OllamaChatOptions(
        mirostat: 1,
        mirostatEta: 0.1,
        mirostatTau: 0.1,
        contextSize: 1,
        repeatLastN: 1,
        repeatPenalty: 0.1,
        temperature: 0.1,
        seed: 1,
      ),
    );

    final updatedChat = (await service.getChat(chat.id))!;
    expect(updatedChat.model, model);
    expect(updatedChat.title, "New Chat");
    expect(updatedChat.systemPrompt, isNull);
    expect(updatedChat.options.mirostat, 1);
    expect(updatedChat.options.mirostatEta, 0.1);
    expect(updatedChat.options.mirostatTau, 0.1);
    expect(updatedChat.options.contextSize, 1);
    expect(updatedChat.options.repeatLastN, 1);
    expect(updatedChat.options.repeatPenalty, 0.1);
    expect(updatedChat.options.temperature, 0.1);
    expect(updatedChat.options.seed, 1);
  });

  test("Test database delete chat", () async {
    final chat = await service.createChat(model);

    await service.deleteChat(chat.id);

    expect(await service.getChat(chat.id), isNull);
  });

  test('Test database delete chat with images', () async {
    List<File> images = [];
    for (var i = 0; i < 10; i++) {
      final image = File(path.join(assetsPath, 'images', 'test_image$i.png'));
      await imageFile.copy(image.path);

      images.add(image);
    }

    final chat = await service.createChat(model);

    for (final image in images) {
      await service.addMessage(
        OllamaMessage(
          "Hello, this is a test message.",
          images: [image],
          role: OllamaMessageRole.user,
        ),
        chat: chat,
      );
    }

    await service.deleteChat(chat.id);

    expect(await service.getChat(chat.id), isNull);
    // Wait for the images to be deleted
    await Future.delayed(Duration(seconds: 1));
    for (final image in images) {
      expect(await image.exists(), isFalse);
    }
  });

  test("Test database get all chats", () async {
    await service.createChat(model);
    final chats = await service.getAllChats();

    if (chats.isNotEmpty) {
      expect(chats.first.id, isNotEmpty);
      expect(chats.first.model, model);
      expect(chats.first.title, "New Chat");
      expect(chats.first.systemPrompt, isNull);
      expect(chats.first.options.toJson(), OllamaChatOptions().toJson());
    }
  }, retry: 5);

  test("Test database add message", () async {
    final chat = await service.createChat(model);
    final message = OllamaMessage(
      "Hello, this is a test message.",
      role: OllamaMessageRole.user,
    );

    await service.addMessage(message, chat: chat);

    final messages = await service.getMessages(chat.id);
    expect(messages.length, 1);
    expect(messages.first.id, message.id);
    expect(messages.first.content, message.content);
    expect(messages.first.role, message.role);
  });

  test('Test database add message with images', () async {
    final chat = await service.createChat(model);
    final message = OllamaMessage(
      "Hello, this is a test message.",
      images: [imageFile],
      role: OllamaMessageRole.user,
    );

    await service.addMessage(message, chat: chat);

    final messages = await service.getMessages(chat.id);
    expect(messages.length, 1);
    expect(messages.first.id, message.id);
    expect(messages.first.content, message.content);
    expect(messages.first.images!.first.path, message.images!.first.path);
    expect(messages.first.role, message.role);
  });

  test("Test database get message", () async {
    final chat = await service.createChat(model);
    final message = OllamaMessage(
      "Hello, this is a test message.",
      role: OllamaMessageRole.user,
    );

    await service.addMessage(message, chat: chat);

    final retrievedMessage = await service.getMessage(message.id);
    expect(retrievedMessage, isNotNull);
    expect(retrievedMessage!.id, message.id);
    expect(retrievedMessage.content, message.content);
    expect(retrievedMessage.role, message.role);
  });

  test('Test database get message with images', () async {
    final chat = await service.createChat(model);
    final message = OllamaMessage(
      "Hello, this is a test message.",
      images: [imageFile],
      role: OllamaMessageRole.user,
    );

    await service.addMessage(message, chat: chat);

    final retrievedMessage = await service.getMessage(message.id);
    expect(retrievedMessage, isNotNull);
    expect(retrievedMessage!.id, message.id);
    expect(retrievedMessage.content, message.content);
    expect(retrievedMessage.images!.first.path, message.images!.first.path);
    expect(retrievedMessage.role, message.role);
  });

  test('Test database update message', () async {
    final chat = await service.createChat(model);

    final message = OllamaMessage("Message", role: OllamaMessageRole.user);
    await service.addMessage(message, chat: chat);

    await service.updateMessage(message, newContent: "Updated message");
    final retrievedMessage = (await service.getMessage(message.id))!;

    expect(retrievedMessage, isNotNull);
    expect(retrievedMessage.id, message.id);
    expect(retrievedMessage.content, 'Updated message');
    expect(retrievedMessage.role, message.role);
  });

  test('Test database delete message', () async {
    final chat = await service.createChat(model);
    final message = OllamaMessage(
      "Hello, this is a test message.",
      role: OllamaMessageRole.user,
    );

    await service.addMessage(message, chat: chat);
    expect(await service.getMessage(message.id), isNotNull);

    await service.deleteMessage(message.id);
    expect(await service.getMessage(message.id), isNull);
  });

  test('Test database delete message with images', () async {
    final testImagePath = path.join(assetsPath, 'images', 'test_image.png');
    await imageFile.copy(testImagePath);
    final testImageFile = File(testImagePath);

    final chat = await service.createChat(model);
    final message = OllamaMessage(
      "Hello, this is a test message.",
      images: [testImageFile],
      role: OllamaMessageRole.user,
    );

    await service.addMessage(message, chat: chat);
    expect(await service.getMessage(message.id), isNotNull);

    await service.deleteMessage(message.id);
    expect(await service.getMessage(message.id), isNull);

    // Wait for the image to be deleted
    await Future.delayed(Duration(seconds: 1));
    expect(await testImageFile.exists(), isFalse);
  });

  test("Test database get messages", () async {
    final chat = await service.createChat(model);
    final message = OllamaMessage(
      "Hello, this is a test message.",
      role: OllamaMessageRole.user,
    );

    await service.addMessage(message, chat: chat);

    final messages = await service.getMessages(chat.id);
    expect(messages.length, 1);
    expect(messages.first.id, message.id);
    expect(messages.first.content, message.content);
    expect(messages.first.role, message.role);
  });

  test("Test database delete messages", () async {
    final chat = await service.createChat(model);
    final message = OllamaMessage(
      "Hello, this is a test message.",
      role: OllamaMessageRole.user,
    );

    await service.addMessage(message, chat: chat);
    expect(await service.getMessage(message.id), isNotNull);

    await service.deleteMessages([message]);
    expect(await service.getMessage(message.id), isNull);
  });

  test('Test database delete messages with images', () async {
    List<File> images = [];
    for (var i = 0; i < 10; i++) {
      final image = File(path.join(assetsPath, 'images', 'test_image$i.png'));
      await imageFile.copy(image.path);

      images.add(image);
    }

    final chat = await service.createChat(model);

    List<OllamaMessage> messages = [];
    for (final image in images) {
      final message = OllamaMessage(
        "Hello, this is a test message.",
        images: [image],
        role: OllamaMessageRole.user,
      );
      await service.addMessage(message, chat: chat);
      messages.add(message);
    }

    await service.deleteMessages(messages);

    for (final message in messages) {
      expect(await service.getMessage(message.id), isNull);
    }

    // Wait for the images to be deleted
    await Future.delayed(Duration(seconds: 1));
    for (final image in images) {
      expect(await image.exists(), isFalse);
    }
  });
}

class FakePathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async {
    return path.join(Directory.current.path, 'test', 'assets');
  }
}
