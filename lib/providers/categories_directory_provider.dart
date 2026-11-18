import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../services/category_repository.dart';
import 'auth_provider.dart';
import 'zlibrary_provider.dart';

/// 分类目录树（方案 F1）：`/categories` 页解析成 顶级分类 → 子分类
/// （带藏书计数）。双通道：Dio 直取，命中浏览器检查墙时走 WebView
/// solver。
final categoriesDirectoryProvider =
    FutureProvider.autoDispose<CategoriesDirectoryPage>((ref) async {
      final repo = CategoryRepository(ref.watch(zlibraryApiProvider));
      final user = ref.read(authProvider).user;
      final response = await repo.fetchDirectory();
      if (response.success && response.data != null) {
        return response.data!;
      }
      if (repo.isChallengeError(response.error)) {
        final html = await repo.fetchViaSolver(
          repo.categoriesDirectoryUrl,
          userId: user?.id,
          userKey: user?.remixUserkey,
        );
        if (html != null) {
          final parsed = await repo.parseDirectory(html);
          if (parsed != null) return parsed;
        }
      }
      throw StateError(response.error ?? 'categories directory failed');
    });
