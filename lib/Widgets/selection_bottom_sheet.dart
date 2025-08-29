import 'package:flutter/material.dart';
import 'package:reins/Models/ollama_request_state.dart';
import 'package:reins/Models/ollama_model.dart';
import 'package:reins/Services/ollama_service.dart';
import 'package:async/async.dart';

class SelectionBottomSheet<T> extends StatefulWidget {
  final Widget header;
  final Future<List<T>> Function() fetchItems;
  final T? currentSelection;
  // Optional: allow callers to provide a current selection value (e.g., String key)
  final Object? currentSelectionValue;
  // Optional: map an item to its selection value (e.g., (item) => item.name)
  final Object Function(T)? valueSelector;
  // Optional: custom row builder (receives selected flag)
  final Widget Function(BuildContext, T, bool)? itemBuilder;

  const SelectionBottomSheet({
    super.key,
    required this.header,
    required this.fetchItems,
    required this.currentSelection,
    this.currentSelectionValue,
    this.valueSelector,
    this.itemBuilder,
  });

  @override
  State<SelectionBottomSheet<T>> createState() => _SelectionBottomSheetState();
}

class _SelectionBottomSheetState<T> extends State<SelectionBottomSheet<T>> {
  static final _itemsBucket = PageStorageBucket();

  T? _selectedItem;
  List<T> _items = [];
  Object? _selectedValue; // supports custom selection values

  var _state = OllamaRequestState.uninitialized;
  late CancelableOperation _fetchOperation;

  @override
  void initState() {
    super.initState();

    // For model selection, always fetch fresh data to ensure capabilities are included
    // Only use cache for non-model data
    final isModelSelection = (widget.key is ValueKey) && 
        (widget.key as ValueKey).value.toString().contains('ollama-model');
    
    if (!isModelSelection) {
      // Load the previous state of the items list for non-model selections
      final cachedItems = _itemsBucket.readState(context, identifier: widget.key);
      if (cachedItems != null && cachedItems is List) {
        try {
          _items = List<T>.from(cachedItems);
        } catch (e) {
          _items = [];
        }
      }
    }
    
    _selectedItem = widget.currentSelection;
    _selectedValue = widget.currentSelectionValue ?? widget.currentSelection;

    _fetchOperation = CancelableOperation.fromFuture(_fetchItems());
  }

  @override
  void dispose() {
    // Cancel _fetchItems if it's still running
    _fetchOperation.cancel();

    super.dispose();
  }

  Future<void> _fetchItems() async {
    setState(() {
      _state = OllamaRequestState.loading;
    });

    try {
      _items = await widget.fetchItems();

      // If we're dealing with OllamaModel items, enrich them with capabilities
      if (_items.isNotEmpty && _items.first is OllamaModel) {
        await _enrichModelsWithCapabilities();
      }

      _state = OllamaRequestState.success;

      if (mounted) {
        // Save the current state of the items list
        _itemsBucket.writeState(context, _items, identifier: widget.key);
      }
    } catch (e) {
      _state = OllamaRequestState.error;
    }

    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _enrichModelsWithCapabilities() async {
    final ollamaService = OllamaService();
    final enrichedModels = <T>[];

    for (final item in _items) {
      if (item is OllamaModel) {
        try {
          final info = await ollamaService.fetchModelInfo(item.name);
          final caps = (info['capabilities'] as List?)?.map((e) => e.toString().toLowerCase()).toList() ?? [];
          
          // Create a new OllamaModel with updated capabilities
          final updatedModel = OllamaModel(
            name: item.name,
            model: item.model,
            modifiedAt: item.modifiedAt,
            size: item.size,
            digest: item.digest,
            details: item.details,
            capabilities: caps,
            supportsTools: caps.contains('tools') || caps.contains('tool'),
          );
          
          enrichedModels.add(updatedModel as T);
        } catch (e) {
          enrichedModels.add(item); // Keep original on error
        }
      } else {
        enrichedModels.add(item);
      }
    }

    _items = enrichedModels;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      minimum: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          Row(
            children: [
              widget.header,
              const Spacer(),
              if (_items.isNotEmpty && _state == OllamaRequestState.loading)
                const CircularProgressIndicator()
            ],
          ),
          const Divider(),
          Expanded(
            child: _buildBody(context),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop(widget.currentSelection);
                },
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () {
                  if (_selectedItem != null) {
                    Navigator.of(context).pop(_selectedItem);
                  }
                },
                child: const Text('Select'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_state == OllamaRequestState.error) {
      return Center(
        child: Text(
          'An error occurred while fetching the items.'
          '\nCheck your server connection and try again.',
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      );
    } else if (_state == OllamaRequestState.loading && _items.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    } else if (_state == OllamaRequestState.success || _items.isNotEmpty) {
      if (_items.isEmpty) {
        return Center(child: Text('No items found.'));
      }

      return RefreshIndicator(
        onRefresh: () async {
          _fetchOperation = CancelableOperation.fromFuture(_fetchItems());
        },
        child: RadioGroup<Object?> (
          groupValue: _selectedValue,
          onChanged: (v) {
            // When a radio updates, map back to the corresponding item
            final matchedItem = _items.firstWhere(
              (it) => (widget.valueSelector?.call(it) ?? it) == v,
              orElse: () => _items.isNotEmpty ? _items.first : null as T,
            );
            setState(() {
              _selectedItem = matchedItem;
              _selectedValue = v;
            });
          },
          child: ListView.builder(
            itemCount: _items.length,
            itemBuilder: (context, index) {
              final item = _items[index];

              final value = widget.valueSelector?.call(item) ?? item;
              final selected = _selectedValue == value;

              Widget titleWidget;
              if (widget.itemBuilder != null) {
                titleWidget = widget.itemBuilder!.call(context, item, selected);
              } else {
                titleWidget = Text(item.toString());
              }

              // Build the title with Tools badge if it's an OllamaModel with tools support
              Widget finalTitle = titleWidget;
              if (item is OllamaModel) {
                final model = item as OllamaModel;
                finalTitle = Row(
                  children: [
                    Expanded(child: titleWidget),
                    if (model.supportsTools)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
                        decoration: BoxDecoration(
                          color: Colors.blue,
                          borderRadius: BorderRadius.circular(12.0),
                        ),
                        child: const Text(
                          'MCP Tools Support',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10.0,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                  ],
                );
              }

              return ListTile(
                title: finalTitle,
                leading: Radio<Object?>(
                  value: value,
                ),
                onTap: () {
                  setState(() {
                    _selectedItem = item;
                    _selectedValue = value;
                  });
                },
                selected: selected,
              );
            },
          ),
        ),
      );
    } else {
      return const SizedBox.shrink();
    }
  }
}

Future<T?> showSelectionBottomSheet<T>({
  ValueKey? key,
  required BuildContext context,
  required Widget header,
  required Future<List<T>> Function() fetchItems,
  required T? currentSelection,
  Object? currentSelectionValue,
  Object Function(T)? valueSelector,
  Widget Function(BuildContext, T, bool)? itemBuilder,
}) async {
  return await showModalBottomSheet(
    context: context,
    builder: (context) {
      return SelectionBottomSheet(
        key: key,
        header: header,
        fetchItems: fetchItems,
        currentSelection: currentSelection,
        currentSelectionValue: currentSelectionValue,
        valueSelector: valueSelector,
        itemBuilder: itemBuilder,
      );
    },
    isDismissible: false,
    enableDrag: false,
  );
}
