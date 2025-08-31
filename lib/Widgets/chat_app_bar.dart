import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:reins/Constants/constants.dart';
import 'package:reins/Widgets/chat_configure_bottom_sheet.dart';
import 'package:reins/Widgets/ollama_bottom_sheet_header.dart';
import 'package:reins/Widgets/selection_bottom_sheet.dart';
import 'package:provider/provider.dart';
import 'package:reins/Providers/chat_provider.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:responsive_framework/responsive_framework.dart';
import 'package:reins/Models/ollama_model.dart';
import 'package:reins/Services/ollama_service.dart';

class ChatAppBar extends StatelessWidget implements PreferredSizeWidget {
  final VoidCallback? onToggleDevPanel; // large screens: toggle side panel
  const ChatAppBar({super.key, this.onToggleDevPanel});

  @override
  Widget build(BuildContext context) {
    final chatProvider = Provider.of<ChatProvider>(context);

    return AppBar(
      title: Column(
        children: [
          Text(AppConstants.appName, style: GoogleFonts.pacifico()),
          if (chatProvider.currentChat != null)
            InkWell(
              onTap: () {
                _handleModelSelectionButton(context);
              },
              customBorder: StadiumBorder(),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                child: Text(
                  chatProvider.currentChat!.model,
                  style: GoogleFonts.kodeMono(
                    textStyle: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ),
            ),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.tune),
          onPressed: () {
            _handleConfigureButton(context);
          },
        ),
        // Debug button
        Builder(
          builder: (ctx) {
            // If a toggler is provided (large layout), use it to show/hide the side panel
            if (onToggleDevPanel != null) {
              return IconButton(
                tooltip: 'Toggle Debug Panel',
                icon: const Icon(Icons.bug_report_outlined),
                onPressed: onToggleDevPanel,
              );
            }
            // Otherwise (mobile), use the endDrawer if available
            final scaffold = Scaffold.maybeOf(ctx);
            final hasEndDrawer = scaffold?.hasEndDrawer ?? false;
            if (!hasEndDrawer) return const SizedBox.shrink();
            return IconButton(
              tooltip: 'Open Debug Panel',
              icon: const Icon(Icons.bug_report_outlined),
              onPressed: () => scaffold!.openEndDrawer(),
            );
          },
        ),
      ],
      forceMaterialTransparency: !ResponsiveBreakpoints.of(context).isMobile,
    );
  }

  Future<void> _handleModelSelectionButton(BuildContext context) async {
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);

    final OllamaModel? selectedModel = await showSelectionBottomSheet<OllamaModel>(
      key: ValueKey("${Hive.box('settings').get('serverAddress')}-ollama-model"),
      context: context,
      header: OllamaBottomSheetHeader(title: "Change The Model"),
      fetchItems: () async {
        // Use basic model list - SelectionBottomSheet will enrich with capabilities
        final ollamaService = OllamaService();
        final models = await ollamaService.listModels();
        return models;
      },
      // We only know the current model name string; use value-based selection
      currentSelection: null,
      currentSelectionValue: chatProvider.currentChat!.model,
      valueSelector: (m) => m.name,
      // No custom itemBuilder needed - SelectionBottomSheet handles Tools badges
    );

    if (selectedModel != null) {
      await chatProvider.updateCurrentChat(newModel: selectedModel.name);
    }
  }

  Future<void> _handleConfigureButton(BuildContext context) async {
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);

    final arguments = chatProvider.currentChatConfiguration;

    final ChatConfigureBottomSheetAction? action = await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext context) {
        return Padding(
          padding: MediaQuery.of(context).viewInsets,
          child: ChatConfigureBottomSheet(arguments: arguments),
        );
      },
    );

    // If the user deletes the chat, we don't need to update the chat.
    if (action == ChatConfigureBottomSheetAction.delete) return;

    await chatProvider.updateCurrentChat(
      newSystemPrompt: arguments.systemPrompt,
      newOptions: arguments.chatOptions,
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}
