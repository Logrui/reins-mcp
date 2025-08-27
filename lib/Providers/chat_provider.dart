import 'dart:io';

import 'package:reins/Constants/constants.dart';
import 'package:reins/Models/chat_configure_arguments.dart';
import 'package:reins/Models/ollama_chat.dart';
import 'package:reins/Models/ollama_exception.dart';
import 'package:reins/Models/ollama_message.dart';
import 'package:reins/Models/ollama_model.dart';
import 'package:reins/Services/database_service.dart';
import 'package:reins/Services/mcp_service.dart';
import 'package:reins/Services/ollama_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:reins/Models/mcp.dart';
import 'package:reins/Utils/tool_call_parser.dart';
import 'package:reins/Constants/tool_system_prompt.dart';

class ChatProvider extends ChangeNotifier {
  final OllamaService _ollamaService;
  final DatabaseService _databaseService;
  final McpService _mcpService;

  bool get _dbEnabled => !kIsWeb;

  List<OllamaMessage> _messages = [];
  List<OllamaMessage> get messages => _messages;

  List<OllamaChat> _chats = [];
  List<OllamaChat> get chats => _chats;

  int _currentChatIndex = -1;
  int get selectedDestination => _currentChatIndex + 1;

  OllamaChat? get currentChat =>
      _currentChatIndex == -1 ? null : _chats[_currentChatIndex];

  final Map<String, OllamaMessage?> _activeChatStreams = {};
  bool _toolFlowActive = false; // guard to prevent re-entrant tool flows

  bool get isCurrentChatStreaming =>
      _activeChatStreams.containsKey(currentChat?.id);

  bool get isCurrentChatThinking =>
      currentChat != null &&
      _activeChatStreams.containsKey(currentChat?.id) &&
      _activeChatStreams[currentChat?.id] == null;

  /// A map of chat errors, indexed by chat ID.
  final Map<String, OllamaException> _chatErrors = {};

  /// The current chat error. This is the error associated with the current chat.
  /// If there is no error, this will be `null`.
  ///
  /// This is used to display error messages in the chat view.
  OllamaException? get currentChatError => _chatErrors[currentChat?.id];

  /// The current chat configuration.
  ChatConfigureArguments get currentChatConfiguration {
    if (currentChat == null) {
      return _emptyChatConfiguration ?? ChatConfigureArguments.defaultArguments;
    } else {
      return ChatConfigureArguments(
        systemPrompt: currentChat!.systemPrompt,
        chatOptions: currentChat!.options,
      );
    }
  }

  /// The chat configuration for the empty chat.
  ChatConfigureArguments? _emptyChatConfiguration;

  ChatProvider({
    required OllamaService ollamaService,
    required DatabaseService databaseService,
    required McpService mcpService,
  })  : _ollamaService = ollamaService,
        _databaseService = databaseService,
        _mcpService = mcpService {
    _initialize();
  }

  Future<void> _initialize() async {
    _updateOllamaServiceAddress();

    // Disable sqflite-backed database on Web (unsupported)
    if (!kIsWeb) {
      await _databaseService.open("ollama_chat.db");
      _chats = await _databaseService.getAllChats();
      notifyListeners();
    }
  }

  void destinationChatSelected(int destination) {
    _currentChatIndex = destination - 1;

    if (destination == 0) {
      _resetChat();
    } else {
      _loadCurrentChat();
    }

    notifyListeners();
  }

  void _resetChat() {
    _currentChatIndex = -1;

    _messages.clear();

    notifyListeners();
  }

  Future<void> _loadCurrentChat() async {
    if (_dbEnabled) {
      _messages = await _databaseService.getMessages(currentChat!.id);
    } else {
      // On Web, messages are only in-memory for current session
      _messages = _messages;
    }

    // Add the streaming message to the chat if it exists
    final streamingMessage = _activeChatStreams[currentChat!.id];
    if (streamingMessage != null) {
      _messages.add(streamingMessage);
    }

    // Unfocus the text field to dismiss the keyboard
    FocusManager.instance.primaryFocus?.unfocus();

    notifyListeners();
  }

  Future<void> createNewChat(OllamaModel model) async {
    final chat = _dbEnabled
        ? await _databaseService.createChat(model.name)
        : OllamaChat(model: model.name);

    _chats.insert(0, chat);
    _currentChatIndex = 0;

    if (_emptyChatConfiguration != null) {
      await updateCurrentChat(
        newSystemPrompt: _emptyChatConfiguration!.systemPrompt,
        newOptions: _emptyChatConfiguration!.chatOptions,
      );

      _emptyChatConfiguration = null;
    }

    notifyListeners();
  }

  Future<void> updateCurrentChat({
    String? newModel,
    String? newTitle,
    String? newSystemPrompt,
    OllamaChatOptions? newOptions,
  }) async {
    await updateChat(
      currentChat,
      newModel: newModel,
      newTitle: newTitle,
      newSystemPrompt: newSystemPrompt,
      newOptions: newOptions,
    );
  }

  /// Updates the chat with the given parameters.
  ///
  /// If the chat is `null`, it updates the empty chat configuration.
  Future<void> updateChat(
    OllamaChat? chat, {
    String? newModel,
    String? newTitle,
    String? newSystemPrompt,
    OllamaChatOptions? newOptions,
  }) async {
    if (chat == null) {
      final chatOptions = newOptions ?? _emptyChatConfiguration?.chatOptions;
      _emptyChatConfiguration = ChatConfigureArguments(
        systemPrompt: newSystemPrompt ?? _emptyChatConfiguration?.systemPrompt,
        chatOptions: chatOptions ?? OllamaChatOptions(),
      );
    } else {
      if (_dbEnabled) {
        await _databaseService.updateChat(
          chat,
          newModel: newModel,
          newTitle: newTitle,
          newSystemPrompt: newSystemPrompt,
          newOptions: newOptions,
        );
      }

      final chatIndex = _chats.indexWhere((c) => c.id == chat.id);

      if (chatIndex != -1) {
        if (_dbEnabled) {
          _chats[chatIndex] = (await _databaseService.getChat(chat.id))!;
        } else {
          // On Web, mirror the updates locally
          final updated = OllamaChat(
            id: chat.id,
            model: newModel ?? chat.model,
            title: newTitle ?? chat.title,
            systemPrompt: newSystemPrompt ?? chat.systemPrompt,
            options: newOptions ?? chat.options,
          );
          _chats[chatIndex] = updated;
        }
        notifyListeners();
      } else {
        throw OllamaException("Chat not found.");
      }
    }
  }

  Future<void> deleteCurrentChat() async {
    final chat = currentChat;
    if (chat == null) return;

    _resetChat();

    _chats.remove(chat);
    _activeChatStreams.remove(chat.id);

    if (!kIsWeb) {
      await _databaseService.deleteChat(chat.id);
    }
  }

  Future<void> sendPrompt(String text, {List<File>? images}) async {
    // Save the chat where the prompt was sent
    final associatedChat = currentChat!;

    // Create a user prompt message and add it to the chat
    final prompt = OllamaMessage(
      text.trim(),
      images: images,
      role: OllamaMessageRole.user,
    );
    _messages.add(prompt);

    notifyListeners();

    // Save the user prompt to the database
    if (!kIsWeb) {
      await _databaseService.addMessage(prompt, chat: associatedChat);
    }

    // Initialize the chat stream with the messages in the chat
    await _initializeChatStream(associatedChat);
  }

  Future<void> _initializeChatStream(OllamaChat associatedChat) async {
    // Clear the active chat streams to cancel the previous stream
    _activeChatStreams.remove(associatedChat.id);

    // Clear the error message associated with the chat
    if (_chatErrors.remove(associatedChat.id) != null) {
      notifyListeners();
      // Wait for a short time to show the user that the error message is cleared
      await Future.delayed(Duration(milliseconds: 250));
    }

    // Update the chat list to show the latest chat at the top
    _moveCurrentChatToTop();

    // Add the chat to the active chat streams to show the thinking indicator
    _activeChatStreams[associatedChat.id] = null;
    // Notify the listeners to show the thinking indicator
    notifyListeners();

    // Stream the Ollama message
    OllamaMessage? ollamaMessage;

    try {
      ollamaMessage = await _streamOllamaMessage(associatedChat);
    } on OllamaException catch (error) {
      _chatErrors[associatedChat.id] = error;
    } on SocketException catch (_) {
      _chatErrors[associatedChat.id] = OllamaException(
        'Network connection lost. Check your server address or internet connection.',
      );
    } catch (error) {
      _chatErrors[associatedChat.id] = OllamaException("Something went wrong.");
    } finally {
      // Remove the chat from the active chat streams
      _activeChatStreams.remove(associatedChat.id);
      notifyListeners();
    }

    // Save the Ollama message to the database
    if (!kIsWeb && ollamaMessage != null) {
      await _databaseService.addMessage(ollamaMessage, chat: associatedChat);
    }
  }

  Future<OllamaMessage?> _streamOllamaMessage(OllamaChat associatedChat) async {
    if (_messages.isEmpty) return null;

    // Build system prompt with currently known tools from connected servers
    final allTools = await _mcpService.listTools();
    final toolSystemPrompt = generateToolSystemPrompt({'connected': allTools});

    final messagesWithSystemPrompt = [
      OllamaMessage(toolSystemPrompt, role: OllamaMessageRole.system),
      ..._messages,
    ];

    final stream = _ollamaService.chatStream(messagesWithSystemPrompt, chat: associatedChat);

    OllamaMessage? streamingMessage;
    OllamaMessage? receivedMessage;

    await for (receivedMessage in stream) {
      if (_activeChatStreams.containsKey(associatedChat.id) == false) {
        streamingMessage?.createdAt = DateTime.now();
        return streamingMessage;
      }

      if (streamingMessage == null) {
        streamingMessage = receivedMessage;
        _activeChatStreams[associatedChat.id] = streamingMessage;
        if (associatedChat.id == currentChat?.id) {
          _messages.add(streamingMessage);
        }
      } else {
        streamingMessage.content += receivedMessage.content;
      }

      notifyListeners();

      final toolCall = _toolFlowActive ? null : parseToolCall(streamingMessage.content);
      if (toolCall != null) {
        _toolFlowActive = true;
        // Finalize and save the tool call message
        streamingMessage.createdAt = DateTime.now();
        if (_dbEnabled) {
          await _databaseService.addMessage(streamingMessage, chat: associatedChat);
        }

        // Explicitly cancel current stream for this chat
        _activeChatStreams.remove(associatedChat.id);
        notifyListeners();

        try {
          // Execute the tool call
          await _executeToolCall(associatedChat, toolCall);
        } finally {
          _toolFlowActive = false;
        }
        return null; // Stop this stream; a new one will be started.
      }
    }

    if (receivedMessage != null) {
      streamingMessage?.updateMetadataFrom(receivedMessage);
    }

    streamingMessage?.createdAt = DateTime.now();

    return streamingMessage;
  }

  Future<void> _executeToolCall(OllamaChat associatedChat, McpToolCall toolCall) async {
    try {
      final resp = await _mcpService.call(toolCall.server, toolCall.name, toolCall.args);
      final formatted = formatToolResult(
        toolCall.name,
        resp.result,
        error: resp.error,
      );
      final resultMessage = OllamaMessage(formatted, role: OllamaMessageRole.assistant);
      _messages.add(resultMessage);
      if (!kIsWeb) {
        await _databaseService.addMessage(resultMessage, chat: associatedChat);
      }
    } catch (e) {
      final errorMessage = OllamaMessage(
        formatToolResult(toolCall.name, null, error: e.toString()),
        role: OllamaMessageRole.assistant,
      );
      _messages.add(errorMessage);
      if (!kIsWeb) {
        await _databaseService.addMessage(errorMessage, chat: associatedChat);
      }
    }

    notifyListeners();

    // Restart the stream with the tool result
    await _initializeChatStream(associatedChat);
  }

  Future<void> regenerateMessage(OllamaMessage message) async {
    final associatedChat = currentChat!;

    final messageIndex = _messages.indexOf(message);
    if (messageIndex == -1) return;

    final includeMessage = (message.role == OllamaMessageRole.user ? 1 : 0);

    final stayedMessages = _messages.sublist(0, messageIndex + includeMessage);
    final removeMessages = _messages.sublist(messageIndex + includeMessage);

    _messages = stayedMessages;
    notifyListeners();

    if (!kIsWeb) {
      await _databaseService.deleteMessages(removeMessages);
    }

    // Reinitialize the chat stream with the messages in the chat
    await _initializeChatStream(associatedChat);
  }

  Future<void> retryLastPrompt() async {
    if (_messages.isEmpty) return;

    final associatedChat = currentChat!;

    if (_messages.last.role == OllamaMessageRole.assistant) {
      final message = _messages.removeLast();
      if (!kIsWeb) {
        await _databaseService.deleteMessage(message.id);
      }
    }

    // Reinitialize the chat stream with the messages in the chat
    await _initializeChatStream(associatedChat);

    notifyListeners();
  }

  Future<void> updateMessage(
    OllamaMessage message, {
    String? newContent,
  }) async {
    message.content = newContent ?? message.content;
    notifyListeners();

    if (!kIsWeb) {
      await _databaseService.updateMessage(message, newContent: newContent);
    }
  }

  Future<void> deleteMessage(OllamaMessage message) async {
    if (_dbEnabled) {
      await _databaseService.deleteMessage(message.id);
    }

    // If the message is in the chat, remove it from the chat
    if (_messages.remove(message)) {
      notifyListeners();
    }
  }

  void cancelCurrentStreaming() {
    _activeChatStreams.remove(currentChat?.id);
    notifyListeners();
  }

  void _moveCurrentChatToTop() {
    if (_currentChatIndex == 0) return;

    final chat = _chats.removeAt(_currentChatIndex);
    _chats.insert(0, chat);
    _currentChatIndex = 0;
  }

  Future<List<OllamaModel>> fetchAvailableModels() async {
    return await _ollamaService.listModels();
  }

  void _updateOllamaServiceAddress() {
    final settingsBox = Hive.box('settings');
    _ollamaService.baseUrl = settingsBox.get('serverAddress');

    settingsBox.listenable(keys: ["serverAddress"]).addListener(() {
      _ollamaService.baseUrl = settingsBox.get('serverAddress');

      // This will update empty chat state to dismiss "Tap to configure server address" message
      notifyListeners();
    });
  }

  Future<void> saveAsNewModel(String modelName) async {
    final associatedChat = currentChat;
    if (associatedChat == null) {
      // TODO: Empty chat should be saved as a new model.
      throw OllamaException("No chat is selected.");
    }

    await _ollamaService.createModel(
      modelName,
      chat: associatedChat,
      messages: _messages.toList(),
    );
  }

  Future<void> generateTitleForCurrentChat() async {
    final associatedChat = currentChat;
    final message = _messages.firstOrNull;
    if (associatedChat == null || message == null) return;

    // Create a temp chat with necessary system prompt
    final chat = OllamaChat(
      model: associatedChat.model,
      systemPrompt: GenerateTitleConstants.systemPrompt,
    );

    // Generate a title for the message
    final stream = _ollamaService.generateStream(
      GenerateTitleConstants.prompt + message.content,
      chat: chat,
    );

    var title = "";
    await for (final titleMessage in stream) {
      title += titleMessage.content;

      // If <think> tag exists, do not stream chat title
      if (title.startsWith("<think>")) {
        await updateChat(associatedChat, newTitle: "Thinking for a title...");
      } else {
        await updateChat(associatedChat, newTitle: title);
      }
    }

    // Remove <think> tag and its content
    if (title.startsWith("<think>")) {
      title = title.replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), '');
    }

    // Save the title as the chat title
    await updateChat(associatedChat, newTitle: title.trim());
  }
}
