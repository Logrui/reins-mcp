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
import 'package:flutter/foundation.dart' show kIsWeb, kDebugMode, debugPrint;
import 'package:meta/meta.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:reins/Models/mcp.dart';
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
  final Map<String, bool> _activeToolCalls = {}; // message.id -> isRunning
  static const int _maxToolCallsPerTurn = 5; // Safeguard against infinite loops
  /// Cache of model -> supportsTools to avoid repeated capability lookups
  /// within a single session. This is populated on first use in
  /// `_streamOllamaMessage()` and reused for subsequent turns. If a chat's
  /// model changes, the cache key naturally changes (by model name), so no
  /// explicit invalidation is required here.
  final Map<String, bool> _supportsToolsCache = {};

  /// Explicit cancellation flags per chat, set when the user cancels a stream.
  /// Using a dedicated flag is more robust than inferring cancellation from
  /// the absence of an entry in `_activeChatStreams`.
  final Set<String> _cancelledChatIds = {};

  @visibleForTesting
  void setSupportsToolsForModel(String model, bool value) {
    _supportsToolsCache[model] = value;
  }

  bool get isCurrentChatStreaming =>
      _activeChatStreams.containsKey(currentChat?.id);

  bool get isCurrentChatThinking {
    if (currentChat == null) return false;
    // Regular stream is thinking
    if (_activeChatStreams.containsKey(currentChat?.id) &&
        _activeChatStreams[currentChat?.id] == null) {
      return true;
    }
    // A tool is running in the current chat
    return _messages.any((m) => m.toolCall != null && _activeToolCalls.containsKey(m.id));
  }

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
    // Clear any previous cancel flag for this chat so the next stream can run.
    _cancelledChatIds.remove(associatedChat.id);

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

    // Save the Ollama message to the database and notify listeners once more
    if (!kIsWeb && ollamaMessage != null) {
      await _databaseService.addMessage(ollamaMessage, chat: associatedChat);
    }
    if (ollamaMessage != null) {
      // Ensure observers see the final assistant message state
      notifyListeners();
    }
  }

  Future<OllamaMessage?> _streamOllamaMessage(OllamaChat associatedChat) async {
    if (_messages.isEmpty) return null;

    int toolCallCount = 0;

    // This loop handles multiple sequential tool calls.
    while (toolCallCount < _maxToolCallsPerTurn) {
      if (kDebugMode) {
        debugPrint('[ChatProvider] loop start: toolCallCount=$toolCallCount chatId=${associatedChat.id}');
      }
      // Re-enable the thinking indicator for each iteration. After a tool call,
      // the main stream indicator is cleared in _executeToolCall(). Without
      // re-enabling here, the next stream might be considered cancelled.
      _activeChatStreams[associatedChat.id] = null;
      notifyListeners();

      // Build system prompt with currently known tools from connected servers
      final allTools = await _mcpService.listTools();
      final toolSystemPrompt = generateToolSystemPrompt(allTools);

      final messagesWithSystemPrompt = [
        OllamaMessage(toolSystemPrompt, role: OllamaMessageRole.system),
        ..._messages,
      ];

      // Determine supportsTools with a small cache to avoid repeated network lookups
      final cachedSupportsTools = _supportsToolsCache[associatedChat.model];
      final resolvedSupportsTools = cachedSupportsTools ??
          ((await _ollamaService.getModel(associatedChat.model))?.supportsTools ?? false);
      _supportsToolsCache[associatedChat.model] = resolvedSupportsTools;
      if (kDebugMode) {
        debugPrint('[ChatProvider] supportsTools: cached=$cachedSupportsTools resolved=$resolvedSupportsTools model=${associatedChat.model}');
      }

      final stream = _ollamaService.chatStream(
        messagesWithSystemPrompt,
        chat: associatedChat,
        supportsTools: resolvedSupportsTools,
      );

      OllamaMessage? streamingMessage;
      OllamaMessage? receivedMessage;
      McpToolCall? pendingToolCall;

      await for (receivedMessage in stream) {
        if (_cancelledChatIds.contains(associatedChat.id)) {
          // Stream was cancelled by user
          streamingMessage?.createdAt = DateTime.now();
          return streamingMessage;
        }

        if (streamingMessage == null) {
          streamingMessage = receivedMessage;
          _activeChatStreams[associatedChat.id] = streamingMessage;
          // Always add the streaming assistant message for this associated chat
          // so tests and non-UI contexts see the full transcript.
          _messages.add(streamingMessage);
          if (kDebugMode) {
            debugPrint('[ChatProvider] streaming started: msgId=${streamingMessage.id}');
          }
        } else {
          streamingMessage.content += receivedMessage.content;
          // Important: if a tool call comes in chunks, merge it.
          if (receivedMessage.toolCall != null) {
            streamingMessage.toolCall = receivedMessage.toolCall;
          }
        }

        notifyListeners();

        // A tool call has been detected. We'll execute it after the stream ends.
        if (streamingMessage.toolCall != null) {
          final tc = streamingMessage.toolCall!;
          pendingToolCall = tc;
          if (kDebugMode) {
            debugPrint('[ChatProvider] tool call detected: server=${tc.server} name=${tc.name} args=${tc.args}');
          }
          break; // Exit stream to process the tool call
        }
      }

      // After the stream is done for this turn...
      if (pendingToolCall != null) {
        toolCallCount++;

        // Finalize and save the assistant message that contains the tool call
        final sm = streamingMessage!;
        sm.createdAt = DateTime.now();
        if (_dbEnabled) {
          await _databaseService.addMessage(sm, chat: associatedChat);
        }

        // Execute the tool call. This will add the result to _messages.
        if (kDebugMode) {
          debugPrint('[ChatProvider] executing tool call #$toolCallCount: ${pendingToolCall.server}/${pendingToolCall.name}');
        }
        await _executeToolCall(associatedChat, pendingToolCall);
        if (kDebugMode) {
          debugPrint('[ChatProvider] tool call finished #$toolCallCount: ${pendingToolCall.server}/${pendingToolCall.name}');
        }

        // If the tool call was cancelled, stop processing this turn.
        final lastMessage = _messages.last;
        if (lastMessage.role == OllamaMessageRole.tool && lastMessage.toolResult?.error == 'Cancelled') {
          return null;
        }
        // Continue to the next iteration of the while loop.
      } else {
        // No tool call was made, this is the final response.
        if (receivedMessage != null) {
          streamingMessage?.updateMetadataFrom(receivedMessage);
        }
        streamingMessage?.createdAt = DateTime.now();
        // Ensure the final message is in the list and notify observers
        if (streamingMessage != null && !_messages.contains(streamingMessage)) {
          _messages.add(streamingMessage);
        }
        // Always notify in case content/metadata changed
        notifyListeners();
        if (kDebugMode) {
          debugPrint('[ChatProvider] final response produced: len=${streamingMessage?.content.length ?? 0}');
        }
        return streamingMessage; // Exit the loop and the function.
      }
    }

    // If we exit the loop due to max tool calls, return an error message.
    final errorMessage = OllamaMessage(
      "Exceeded maximum tool calls limit ($_maxToolCallsPerTurn).",
      role: OllamaMessageRole.assistant,
    );
    errorMessage.createdAt = DateTime.now();
    _messages.add(errorMessage);
    notifyListeners();
    return errorMessage;
  }

  Future<void> _executeToolCall(OllamaChat associatedChat, McpToolCall toolCall) async {
    // A tool call is active, so the main stream is paused.
    // Clear the thinking indicator for the main stream.
    if (_activeChatStreams.containsKey(associatedChat.id)) {
      _activeChatStreams.remove(associatedChat.id);
    }
    // Create a 'tool' message to show the thinking state
    final toolMessage = OllamaMessage(
      '', // Content is initially empty
      role: OllamaMessageRole.tool,
      toolCall: toolCall,
    );
    _messages.add(toolMessage);
    _activeToolCalls[toolMessage.id] = true;
    if (_dbEnabled) {
      await _databaseService.addMessage(toolMessage, chat: associatedChat);
    }
    if (kDebugMode) {
      debugPrint('[ChatProvider] tool message created: msgId=${toolMessage.id} for ${toolCall.server}/${toolCall.name}');
    }
    notifyListeners();

    // If the call was cancelled while it was running, do nothing.
    if (!_activeToolCalls.containsKey(toolMessage.id)) {
      return;
    }

    // Validate arguments against tool schema (if any). If invalid, short-circuit
    final validationErrors = _mcpService.validateToolArguments(toolCall.server, toolCall.name, toolCall.args);
    if (validationErrors.isNotEmpty) {
      final err = 'Invalid arguments: ${validationErrors.join('; ')}';
      toolMessage.toolResult = McpToolResult(result: null, error: err);
      toolMessage.content = 'Tool validation failed: $err';
      _activeToolCalls.remove(toolMessage.id);
      if (_dbEnabled) {
        await _databaseService.updateMessage(
          toolMessage,
          newContent: toolMessage.content,
          newToolResult: toolMessage.toolResult,
        );
      }
      notifyListeners();
      if (kDebugMode) {
        debugPrint('[ChatProvider] tool args validation failed for ${toolCall.server}/${toolCall.name}: $err');
      }
      return;
    }

    McpToolResult toolResult;
    try {
      if (kDebugMode) {
        debugPrint('[ChatProvider] calling MCP tool: ${toolCall.server}/${toolCall.name} args=${toolCall.args}');
      }
      final resp = await _mcpService.call(toolCall.server, toolCall.name, toolCall.args);
      toolResult = McpToolResult(
        result: resp.result,
        error: resp.error?.toString(),
      );
    } catch (e) {
      toolResult = McpToolResult(
        result: null,
        error: e.toString(),
      );
    }

    // If cancelled after completion but before UI update, still do nothing.
    if (!_activeToolCalls.containsKey(toolMessage.id)) {
      return;
    }

    // Update the message with the result. The content is no longer needed
    // as the structured tool_results will be sent to the model.
    toolMessage.toolResult = toolResult;
    toolMessage.content = 'Tool returned: ${toolResult.result ?? toolResult.error}';
    if (kDebugMode) {
      debugPrint('[ChatProvider] MCP tool result: ok=${toolResult.error == null} len=${toolMessage.content.length}');
    }

    _activeToolCalls.remove(toolMessage.id);
    if (_dbEnabled) {
      await _databaseService.updateMessage(
        toolMessage,
        newContent: toolMessage.content,
        newToolResult: toolMessage.toolResult,
      );
    }

    notifyListeners();

    // The stream will be re-initialized by the loop in _streamOllamaMessage.
    if (kDebugMode) {
      debugPrint('[ChatProvider] tool call completed, returning to stream loop');
    }
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

  /// Cancels the current model streaming for the active chat.
  ///
  /// Sets a dedicated cancellation flag for the chat and removes the
  /// thinking indicator. The streaming loop checks this flag to stop
  /// gracefully on the next chunk.
  void cancelCurrentStreaming() {
    if (currentChat?.id != null) {
      _cancelledChatIds.add(currentChat!.id);
      _activeChatStreams.remove(currentChat!.id);
    }
    notifyListeners();
  }

  void cancelToolCall(String messageId) {
    if (_activeToolCalls.containsKey(messageId)) {
      _activeToolCalls.remove(messageId);
            final message = _messages.firstWhere((m) => m.id == messageId, orElse: () => OllamaMessage('', role: OllamaMessageRole.system));
      if (message.id.isNotEmpty) {
        message.content = 'Tool call cancelled by user.';
        message.toolResult = McpToolResult(result: null, error: 'Cancelled');
        if (_dbEnabled) {
          _databaseService.updateMessage(
            message,
            newContent: message.content,
            newToolResult: message.toolResult,
          );
        }
      }
      notifyListeners();
    }
  }

  void _moveCurrentChatToTop() {
    if (_currentChatIndex == 0) return;

    final chat = _chats.removeAt(_currentChatIndex);
    _chats.insert(0, chat);
    _currentChatIndex = 0;
  }

  Future<List<OllamaModel>> fetchAvailableModels() async {
    final models = await _ollamaService.listModelsWithCaps();
    return models;
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
