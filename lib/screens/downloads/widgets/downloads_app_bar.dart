/// AppBar for the downloads screen (P1-4 split of
/// local_downloads_screen.dart): title + open-folder action + the
/// ongoing/completed tab bar with counts. The screen sizes the header
/// from [preferredSize], as before (default toolbar + tab bar heights).
import 'package:flutter/material.dart';

class LocalDownloadsAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  const LocalDownloadsAppBar({
    super.key,
    required this.title,
    required this.openFolderTooltip,
    required this.ongoingLabel,
    required this.completedLabel,
    required this.accent,
    required this.onOpenFolder,
  });

  final String title;
  final String openFolderTooltip;
  final String ongoingLabel;
  final String completedLabel;

  /// Tab indicator / label color (the screen passes the theme primary).
  final Color accent;
  final VoidCallback onOpenFolder;

  @override
  Size get preferredSize =>
      const Size.fromHeight(kToolbarHeight + kTextTabBarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: Text(title),
      actions: [
        IconButton(
          tooltip: openFolderTooltip,
          icon: const Icon(Icons.folder_open_rounded),
          onPressed: onOpenFolder,
        ),
      ],
      bottom: TabBar(
        indicatorColor: accent,
        labelColor: accent,
        tabs: [Tab(text: ongoingLabel), Tab(text: completedLabel)],
      ),
    );
  }
}
