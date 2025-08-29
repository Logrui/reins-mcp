import 'dart:convert';
import 'dart:io';

import 'package:reins/Constants/constants.dart';
import 'package:reins/Models/mcp.dart';
import 'package:reins/Models/ollama_chat.dart';
import 'package:reins/Models/ollama_message.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'package:path/path.dart' as path;

class DatabaseService {
  late Database _db;

  Future<void> open(String databaseFile) async {
    _db = await openDatabase(
      path.join(await getDatabasesPath(), databaseFile),
      version: 3,
      onCreate: (Database db, int version) async {
        await db.execute('''CREATE TABLE IF NOT EXISTS chats (
chat_id TEXT PRIMARY KEY,
model TEXT NOT NULL,
chat_title TEXT NOT NULL,
system_prompt TEXT,
options TEXT
) WITHOUT ROWID;''');

        await db.execute('''CREATE TABLE IF NOT EXISTS messages (
message_id TEXT PRIMARY KEY,
chat_id TEXT NOT NULL,
content TEXT NOT NULL,
images TEXT,
role TEXT CHECK(role IN ('user', 'assistant', 'system', 'tool')) NOT NULL,
tool_call TEXT,
tool_result TEXT,
timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
FOREIGN KEY (chat_id) REFERENCES chats(chat_id) ON DELETE CASCADE
) WITHOUT ROWID;''');

        // Create cleanup_jobs table
        await db.execute('''CREATE TABLE IF NOT EXISTS cleanup_jobs (
id INTEGER PRIMARY KEY AUTOINCREMENT,
image_paths TEXT NOT NULL
)''');

        // Create trigger to handle image deletion
        await db.execute('''CREATE TRIGGER IF NOT EXISTS delete_images_trigger
AFTER DELETE ON messages
WHEN OLD.images IS NOT NULL
BEGIN
  INSERT INTO cleanup_jobs (image_paths) VALUES (OLD.images);
END;''');
      },
      onUpgrade: (Database db, int oldVersion, int newVersion) async {
        if (oldVersion < 2) {
          // In version 2, we add the 'tool' role to the messages table.
          // SQLite doesn't support modifying CHECK constraints directly, so we have to
          // recreate the table.
          await db.execute('ALTER TABLE messages RENAME TO messages_old;');

          await db.execute('''CREATE TABLE messages (
            message_id TEXT PRIMARY KEY,
            chat_id TEXT NOT NULL,
            content TEXT NOT NULL,
            images TEXT,
            role TEXT CHECK(role IN ('user', 'assistant', 'system', 'tool')) NOT NULL,
            tool_call TEXT,
            tool_result TEXT,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (chat_id) REFERENCES chats(chat_id) ON DELETE CASCADE
          ) WITHOUT ROWID;''');

          await db.execute(
            'INSERT INTO messages(message_id, chat_id, content, images, role, timestamp) SELECT message_id, chat_id, content, images, role, timestamp FROM messages_old;'
          );

          await db.execute('DROP TABLE messages_old;');

          // The trigger was dropped when the table was dropped, so we need to recreate it.
          await db.execute('''CREATE TRIGGER IF NOT EXISTS delete_images_trigger
          AFTER DELETE ON messages
          WHEN OLD.images IS NOT NULL
          BEGIN
            INSERT INTO cleanup_jobs (image_paths) VALUES (OLD.images);
          END;''');
        }
        if (oldVersion < 3) {
          // Version 3 introduces tool_call and tool_result columns if not already present.
          // Some users may already have them from v2 migration above, but ensure presence.
          // SQLite lacks IF NOT EXISTS for ADD COLUMN before 3.35; safest is table recreate.
          await db.execute('ALTER TABLE messages RENAME TO messages_old;');

          await db.execute('''CREATE TABLE messages (
            message_id TEXT PRIMARY KEY,
            chat_id TEXT NOT NULL,
            content TEXT NOT NULL,
            images TEXT,
            role TEXT CHECK(role IN ('user', 'assistant', 'system', 'tool')) NOT NULL,
            tool_call TEXT,
            tool_result TEXT,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (chat_id) REFERENCES chats(chat_id) ON DELETE CASCADE
          ) WITHOUT ROWID;''');

          // Migrate old data; new columns default to NULL
          await db.execute(
              'INSERT INTO messages(message_id, chat_id, content, images, role, timestamp) SELECT message_id, chat_id, content, images, role, timestamp FROM messages_old;');

          await db.execute('DROP TABLE messages_old;');

          // Recreate trigger
          await db.execute('''CREATE TRIGGER IF NOT EXISTS delete_images_trigger
          AFTER DELETE ON messages
          WHEN OLD.images IS NOT NULL
          BEGIN
            INSERT INTO cleanup_jobs (image_paths) VALUES (OLD.images);
          END;''');
        }
      },
    );
  }

  Future<void> close() async => _db.close();

  // Chat Operations

  Future<OllamaChat> createChat(String model) async {
    final id = Uuid().v4();

    await _db.insert('chats', {
      'chat_id': id,
      'model': model,
      'chat_title': 'New Chat',
      'system_prompt': null,
      'options': null,
    });

    return (await getChat(id))!;
  }

  Future<OllamaChat?> getChat(String chatId) async {
    final List<Map<String, dynamic>> maps = await _db.query(
      'chats',
      where: 'chat_id = ?',
      whereArgs: [chatId],
    );

    if (maps.isEmpty) {
      return null;
    } else {
      return OllamaChat.fromMap(maps.first);
    }
  }

  Future<void> updateChat(
    OllamaChat chat, {
    String? newModel,
    String? newTitle,
    String? newSystemPrompt,
    OllamaChatOptions? newOptions,
  }) async {
    await _db.update(
      'chats',
      {
        'model': newModel ?? chat.model,
        'chat_title': newTitle ?? chat.title,
        'system_prompt': newSystemPrompt ?? chat.systemPrompt,
        'options': newOptions?.toJson() ?? chat.options.toJson(),
      },
      where: 'chat_id = ?',
      whereArgs: [chat.id],
    );
  }

  Future<void> deleteChat(String chatId) async {
    await _db.delete(
      'chats',
      where: 'chat_id = ?',
      whereArgs: [chatId],
    );

    await _db.delete(
      'messages',
      where: 'chat_id = ?',
      whereArgs: [chatId],
    );

    // ? Should we run with Isolate.run?
    _cleanupDeletedImages();
  }

  Future<List<OllamaChat>> getAllChats() async {
    final List<Map<String, dynamic>> maps = await _db.rawQuery(
        '''SELECT chats.chat_id, chats.model, chats.chat_title, chats.system_prompt, chats.options, MAX(messages.timestamp) AS last_update
FROM chats
LEFT JOIN messages ON chats.chat_id = messages.chat_id
GROUP BY chats.chat_id
ORDER BY last_update DESC;''');

    return List.generate(maps.length, (i) {
      return OllamaChat.fromMap(maps[i]);
    });
  }

  // Message Operations

  Future<void> addMessage(
    OllamaMessage message, {
    required OllamaChat chat,
  }) async {
    await _db.insert('messages', {
      'chat_id': chat.id,
      ...message.toDatabaseMap(),
    });
  }

  Future<OllamaMessage?> getMessage(String messageId) async {
    final List<Map<String, dynamic>> maps = await _db.query(
      'messages',
      where: 'message_id = ?',
      whereArgs: [messageId],
    );

    if (maps.isEmpty) {
      return null;
    } else {
      return OllamaMessage.fromDatabase(maps.first);
    }
  }

  Future<void> updateMessage(
    OllamaMessage message, {
    String? newContent,
    McpToolCall? newToolCall,
    McpToolResult? newToolResult,
  }) async {
    await _db.update(
      'messages',
      {
        'content': newContent ?? message.content,
        'tool_call': (newToolCall ?? message.toolCall) != null
            ? jsonEncode((newToolCall ?? message.toolCall)!.toJson())
            : null,
        'tool_result': (newToolResult ?? message.toolResult) != null
            ? jsonEncode((newToolResult ?? message.toolResult)!.toJson())
            : null,
      },
      where: 'message_id = ?',
      whereArgs: [message.id],
    );
  }

  Future<void> deleteMessage(String messageId) async {
    await _db.delete(
      'messages',
      where: 'message_id = ?',
      whereArgs: [messageId],
    );

    _cleanupDeletedImages();
  }

  Future<List<OllamaMessage>> getMessages(String chatId) async {
    final List<Map<String, dynamic>> maps = await _db.query(
      'messages',
      where: 'chat_id = ?',
      whereArgs: [chatId],
      orderBy: 'timestamp ASC',
    );

    return List.generate(maps.length, (i) {
      return OllamaMessage.fromDatabase(maps[i]);
    });
  }

  Future<void> deleteMessages(List<OllamaMessage> messages) async {
    await _db.transaction((txn) async {
      for (final message in messages) {
        await txn.delete(
          'messages',
          where: 'message_id = ?',
          whereArgs: [message.id],
        );
      }
    });

    _cleanupDeletedImages();
  }

  // ? Should we trigger this cleanup on every message deletion?
  // ? Or should we run it on every app start?
  Future<void> _cleanupDeletedImages() async {
    final List<Map<String, dynamic>> results = await _db.query(
      'cleanup_jobs',
      columns: ['id', 'image_paths'],
      where: 'image_paths IS NOT NULL',
    );

    for (final result in results) {
      try {
        final images = _constructImages(result['image_paths']);
        if (images == null) continue;

        for (final image in images) {
          if (await image.exists()) {
            await image.delete();
          }
        }

        // Delete the row after images are deleted
        await _db.delete(
          'cleanup_jobs',
          where: 'id = ?',
          whereArgs: [result['id']],
        );
      } catch (_) {}
    }
  }

  static List<File>? _constructImages(String? raw) {
    if (raw != null) {
      final List<dynamic> decoded = jsonDecode(raw);
      return decoded.map((imageRelativePath) {
        return File(path.join(
          PathManager.instance.documentsDirectory.path,
          imageRelativePath,
        ));
      }).toList();
    }

    return null;
  }
}
