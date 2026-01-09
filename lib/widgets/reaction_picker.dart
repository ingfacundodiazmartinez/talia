import 'package:flutter/material.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';

class ReactionPicker extends StatelessWidget {
  final Function(String) onReactionSelected;

  const ReactionPicker({
    super.key,
    required this.onReactionSelected,
  });

  static const List<String> reactions = ['❤️', '👍', '😂', '😮', '😢', '🔥'];

  void _showFullEmojiPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SizedBox(
        height: 350,
        child: EmojiPicker(
          onEmojiSelected: (category, emoji) {
            Navigator.of(ctx).pop();
            onReactionSelected(emoji.emoji);
          },
          config: Config(
            height: 350,
            checkPlatformCompatibility: true,
            emojiViewConfig: EmojiViewConfig(
              columns: 8,
              emojiSizeMax: 28,
              verticalSpacing: 0,
              horizontalSpacing: 0,
              gridPadding: EdgeInsets.zero,
              backgroundColor: Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xFF1C1B1F)
                  : Colors.white,
              recentsLimit: 28,
              loadingIndicator: const SizedBox.shrink(),
              noRecents: const Text(
                'Sin recientes',
                style: TextStyle(fontSize: 14, color: Colors.grey),
              ),
            ),
            categoryViewConfig: CategoryViewConfig(
              initCategory: Category.SMILEYS,
              backgroundColor: Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xFF1C1B1F)
                  : Colors.white,
              indicatorColor: Theme.of(context).colorScheme.primary,
              iconColorSelected: Theme.of(context).colorScheme.primary,
              iconColor: Colors.grey,
            ),
            bottomActionBarConfig: const BottomActionBarConfig(enabled: false),
            searchViewConfig: SearchViewConfig(
              backgroundColor: Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xFF1C1B1F)
                  : Colors.white,
              buttonIconColor: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2C2C2C) : Colors.white,
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Quick reaction emojis
          ...reactions.map((reaction) {
            return InkWell(
              onTap: () => onReactionSelected(reaction),
              customBorder: const CircleBorder(),
              child: Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                child: Text(
                  reaction,
                  style: const TextStyle(fontSize: 28),
                ),
              ),
            );
          }),
          // + button for more emojis
          InkWell(
            onTap: () => _showFullEmojiPicker(context),
            customBorder: const CircleBorder(),
            child: Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.1)
                    : Colors.grey.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.add,
                size: 24,
                color: isDark ? Colors.white70 : Colors.grey[700],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
