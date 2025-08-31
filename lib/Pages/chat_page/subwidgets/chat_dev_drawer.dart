import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reins/Providers/chat_provider.dart';
import 'package:reins/Services/mcp_service.dart';

class ChatDevDrawer extends StatefulWidget {
  final bool asPanel; // when true, render as a fixed-width panel instead of Drawer overlay
  final VoidCallback? onClose; // used by panel mode to signal hide
  const ChatDevDrawer({super.key, this.asPanel = false, this.onClose});

  @override
  State<ChatDevDrawer> createState() => _ChatDevDrawerState();
}

class _ChatDevDrawerState extends State<ChatDevDrawer> {
  String? _serverFilter; // null -> All
  McpLogLevel? _levelMin; // null -> All
  final Set<String> _categoryFilter = <String>{};
  String _search = '';
  bool _liveTail = true;
  final ScrollController _scroll = ScrollController();

  // RequestId filter
  String _requestId = '';

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mcp = context.watch<McpService>();
    final logs = mcp.logs;

    // Derive server options from current logs (unique, sorted)
    final current = logs.recent();
    final List<String> serverOptions = current
        .map((e) => e.serverUrl)
        .whereType<String>()
        .toSet()
        .toList()
      ..sort();

    final String? effectiveServerFilter =
        (_serverFilter != null && serverOptions.contains(_serverFilter)) ? _serverFilter : null;

    Color _levelColor(McpLogLevel lvl) {
      switch (lvl) {
        case McpLogLevel.debug:
          return Colors.blueGrey;
        case McpLogLevel.info:
          return Colors.blue;
        case McpLogLevel.warn:
          return Colors.orange;
        case McpLogLevel.error:
          return Colors.red;
      }
    }

    String _fmtTime(DateTime t) =>
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}.${t.millisecond.toString().padLeft(3, '0') }';

    bool _passesLevel(McpLogEvent e) {
      if (_levelMin == null) return true;
      return e.level.index >= _levelMin!.index;
    }

    bool _passesCategory(McpLogEvent e) {
      if (_categoryFilter.isEmpty) return true;
      return _categoryFilter.contains(e.category);
    }

    bool _passesSearch(McpLogEvent e) {
      if (_search.isEmpty) return true;
      final q = _search.toLowerCase();
      final dataStr = e.data == null ? '' : jsonEncode(e.data);
      return e.message.toLowerCase().contains(q) ||
          e.category.toLowerCase().contains(q) ||
          (e.serverUrl ?? '').toLowerCase().contains(q) ||
          (e.requestId ?? '').toLowerCase().contains(q) ||
          (e.sessionId ?? '').toLowerCase().contains(q) ||
          dataStr.toLowerCase().contains(q);
    }

    bool _passesRequestId(McpLogEvent e) {
      if (_requestId.trim().isEmpty) return true;
      return (e.requestId ?? '') == _requestId.trim();
    }

    final content = SafeArea(
      child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    'Chat Debug (Dev Logs)',
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      if (widget.asPanel) {
                        widget.onClose?.call();
                      } else {
                        Navigator.of(context).maybePop();
                      }
                    },
                  )
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  DropdownButton<String?>(
                    value: effectiveServerFilter,
                    hint: const Text('All servers'),
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('All servers')),
                      ...serverOptions.map((s) => DropdownMenuItem<String?>(value: s, child: Text(s))),
                    ],
                    onChanged: (v) => setState(() => _serverFilter = v),
                  ),
                  DropdownButton<McpLogLevel?>(
                    value: _levelMin,
                    hint: const Text('Level: All'),
                    items: const [
                      DropdownMenuItem<McpLogLevel?>(value: null, child: Text('Level: All')),
                      DropdownMenuItem<McpLogLevel?>(value: McpLogLevel.debug, child: Text('>= Debug')),
                      DropdownMenuItem<McpLogLevel?>(value: McpLogLevel.info, child: Text('>= Info')),
                      DropdownMenuItem<McpLogLevel?>(value: McpLogLevel.warn, child: Text('>= Warn')),
                      DropdownMenuItem<McpLogLevel?>(value: McpLogLevel.error, child: Text('>= Error')),
                    ],
                    onChanged: (v) => setState(() => _levelMin = v),
                  ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: TextField(
                      decoration: const InputDecoration(
                        isDense: true,
                        prefixIcon: Icon(Icons.search, size: 18),
                        hintText: 'Search…',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (v) => setState(() => _search = v.trim()),
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Live tail'),
                      const SizedBox(width: 6),
                      Switch(
                        value: _liveTail,
                        onChanged: (v) => setState(() => _liveTail = v),
                      ),
                    ],
                  ),
                  OutlinedButton.icon(
                    onPressed: () {
                      logs.clear(serverUrl: effectiveServerFilter);
                      setState(() {});
                    },
                    icon: const Icon(Icons.clear_all),
                    label: const Text('Clear'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // RequestId filter row
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: 'Request ID',
                        hintText: 'Enter to filter by tool-call requestId',
                        border: OutlineInputBorder(),
                      ),
                      controller: TextEditingController(text: _requestId),
                      onChanged: (v) => setState(() => _requestId = v.trim()),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: 'Use last tool-call requestId from current chat',
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.link),
                      label: const Text('Link last'),
                      onPressed: () {
                        final chat = context.read<ChatProvider>();
                        String? lastReq;
                        for (final msg in chat.messages.reversed) {
                          final tc = msg.toolCall;
                          if (tc != null && (tc.id.isNotEmpty)) {
                            lastReq = tc.id;
                            break;
                          }
                        }
                        if (lastReq != null) {
                          setState(() => _requestId = lastReq!);
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('No tool-call requestId found in current chat')),
                          );
                        }
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Categories
              Builder(builder: (context) {
                final current = logs.recent(serverUrl: effectiveServerFilter);
                final cats = current.map((e) => e.category).toSet().toList()
                  ..sort();
                return Wrap(
                  spacing: 8,
                  children: [
                    for (final c in cats)
                      FilterChip(
                        label: Text(c),
                        selected: _categoryFilter.contains(c),
                        onSelected: (sel) => setState(() {
                          if (sel) {
                            _categoryFilter.add(c);
                          } else {
                            _categoryFilter.remove(c);
                          }
                        }),
                      ),
                    if (_categoryFilter.isNotEmpty)
                      TextButton(
                        onPressed: () => setState(() => _categoryFilter.clear()),
                        child: const Text('Clear categories'),
                      ),
                  ],
                );
              }),
              const SizedBox(height: 8),
              // Live list
              Expanded(
                child: StreamBuilder<McpLogEvent>(
                  stream: logs.stream(),
                  builder: (context, snapshot) {
                    final events = logs
                        .recent(serverUrl: effectiveServerFilter)
                        .where(_passesLevel)
                        .where(_passesCategory)
                        .where(_passesSearch)
                        .where(_passesRequestId)
                        .toList();

                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (_liveTail && _scroll.hasClients) {
                        _scroll.jumpTo(_scroll.position.maxScrollExtent);
                      }
                    });

                    final mono = Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace');

                    return Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Theme.of(context).dividerColor),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: ListView.builder(
                        controller: _scroll,
                        itemCount: events.length,
                        itemBuilder: (context, i) {
                          final e = events[i];
                          final line =
                              '[${_fmtTime(e.timestamp)}] [${e.level.name.toUpperCase()}] [${e.category}] ${e.message}';
                          return ExpansionTile(
                            tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                            childrenPadding: const EdgeInsets.only(left: 24, right: 12, bottom: 8),
                            leading: Icon(Icons.fiber_manual_record, size: 12, color: _levelColor(e.level)),
                            title: Text(line, style: mono),
                            subtitle: (e.serverUrl != null || e.requestId != null)
                                ? Text(
                                    [
                                      if (e.serverUrl != null) e.serverUrl!,
                                      if (e.requestId != null) 'req=${e.requestId}',
                                      if (e.sessionId != null) 'sess=${e.sessionId}',
                                    ].join(' · '),
                                    style: Theme.of(context).textTheme.bodySmall,
                                  )
                                : null,
                            children: [
                              if (e.data != null)
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: SelectableText(
                                    const JsonEncoder.withIndent('  ').convert(e.data),
                                    style: mono,
                                  ),
                                )
                              else
                                const Align(
                                  alignment: Alignment.centerLeft,
                                  child: Padding(
                                    padding: EdgeInsets.only(bottom: 4),
                                    child: Text('No details'),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
      ),
    );

    if (widget.asPanel) {
      return SizedBox(width: 420, child: content);
    }
    return Drawer(width: 420, child: content);
  }
}
