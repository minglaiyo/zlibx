import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/generated/app_localizations.dart';
import '../providers/auth_provider.dart';
import '../providers/zlibrary_provider.dart';
import '../services/booklist_repository.dart';
import '../utils/app_snack.dart';

/// 长按书单条目弹出的快捷操作面板——书籍侧 [showBookQuickActionsSheet]
/// 的书单孪生:同款 bottom sheet(标题 = 书单名,一行动作一项)。
/// 用在关联书单页与书单页的发现/收藏 tab;「我的」tab 的长按保持
/// 删除语义,不走这里。
///
/// 收藏接口是站点写操作(`POST /papi/booklist/{id}/favorite/add` /
/// `DELETE .../favorite/remove`,vendor 已实机验证),需要登录会话;
/// 未登录只提示登录,不发请求。成功后失效收藏页
/// (`/booklists/favorite`)的默认缓存键,让收藏 tab 下一次打开重拉
/// 而非画回旧集合——面板刻意绕开 booklistsControllerProvider:那会
/// 为一次收藏把整个书单页状态机拉起来。
Future<void> showBooklistQuickActionsSheet(
  BuildContext context,
  Booklist list,
) async {
  final l10n = AppLocalizations.of(context)!;
  final messenger = ScaffoldMessenger.of(context);
  final container = ProviderScope.containerOf(context);
  final action = await showModalBottomSheet<_BooklistQuickAction>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Text(
              list.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                sheetContext,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          // 心形状态:关联书单页的卡片不带 favorite 属性(书页区块
          // 不渲染它),isFavorite 恒 false → 这里给出"收藏";从发现/
          // 收藏 tab 进来的条目带真实状态,只显示当前可做的那一项。
          if (!list.isFavorite)
            ListTile(
              leading: const Icon(Icons.favorite_border_rounded),
              title: Text(l10n.favoriteBooklist),
              onTap: () =>
                  Navigator.pop(sheetContext, _BooklistQuickAction.favorite),
            )
          else
            ListTile(
              leading: const Icon(Icons.favorite_rounded),
              title: Text(l10n.unfavoriteBooklist),
              onTap: () =>
                  Navigator.pop(sheetContext, _BooklistQuickAction.unfavorite),
            ),
          ListTile(
            leading: const Icon(Icons.share_outlined),
            title: Text(l10n.share),
            onTap: () =>
                Navigator.pop(sheetContext, _BooklistQuickAction.share),
          ),
        ],
      ),
    ),
  );
  if (action == null) return;
  if (!context.mounted) return;
  switch (action) {
    case _BooklistQuickAction.share:
      try {
        await SharePlus.instance.share(
          ShareParams(text: '${list.name}\n${list.url}'),
        );
      } catch (_) {
        if (!context.mounted) return;
        showAppSnack(context, l10n.shareFailed);
      }
    case _BooklistQuickAction.favorite:
    case _BooklistQuickAction.unfavorite:
      await _runFavorite(
        context,
        messenger,
        container,
        list,
        wantFavorite: action == _BooklistQuickAction.favorite,
      );
  }
}

/// 收藏/取消收藏——详情页 AppBar 心形按钮与长按面板共用的直调入口。
/// 返回是否写入成功(未登录或失败为 false),调用方据此决定本地
/// 收藏态是否翻转。
Future<bool> runBooklistFavorite(
  BuildContext context,
  Booklist list, {
  required bool wantFavorite,
}) {
  final messenger = ScaffoldMessenger.of(context);
  final container = ProviderScope.containerOf(context);
  return _runFavorite(
    context,
    messenger,
    container,
    list,
    wantFavorite: wantFavorite,
  );
}

/// 系统分享书单链接(详情页分享按钮与面板同一实现)。
Future<void> runBooklistShare(BuildContext context, Booklist list) async {
  final l10n = AppLocalizations.of(context)!;
  try {
    await SharePlus.instance.share(
      ShareParams(text: '${list.name}\n${list.url}'),
    );
  } catch (_) {
    if (!context.mounted) return;
    showAppSnack(context, l10n.shareFailed);
  }
}

Future<bool> _runFavorite(
  BuildContext context,
  ScaffoldMessengerState messenger,
  ProviderContainer container,
  Booklist list, {
  required bool wantFavorite,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final user = container.read(authProvider).user;
  final listId = int.tryParse(list.id);
  // 未登录/非数字 id:站点写接口不可用。只提示,不发请求。
  if (user == null) {
    showAppSnackOn(messenger, l10n.loginToContinue);
    return false;
  }
  if (listId == null) return false; // 非数字 id:理论不可达,静默即可
  final api = container.read(zlibraryApiProvider);
  final response = wantFavorite
      ? await api.favoriteBooklist(listId)
      : await api.unfavoriteBooklist(listId);
  if (response.success) {
    // 收藏页缓存失效(默认键;best-effort,见 provider 侧同名注释)。
    final repository = BooklistRepository(api);
    repository.invalidateBooklist(
      repository.booklistsPageUrl(
        mine: false,
        favorite: true,
        query: '',
        order: 'popular',
        page: 1,
      ),
      accountId: user.id,
    );
  }
  showAppSnackOn(
    messenger,
    response.success
        ? (wantFavorite ? l10n.booklistFavorited : l10n.booklistUnfavorited)
        : l10n.booklistFavoriteFailed(response.error ?? ''),
  );
  return response.success;
}

enum _BooklistQuickAction { favorite, unfavorite, share }
