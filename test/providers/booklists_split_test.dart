// P1-4 split tests: booklists_provider.dart is now three files behind
// a thin barrel (booklists_provider.dart re-exports state, controller
// and cache). These tests pin the split down: the state model is
// importable directly from booklists_state.dart, and the barrel still
// exposes every name the old single file did, so no call site changes.
import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/providers/booklists_controller.dart';
import 'package:zlibx/providers/booklists_provider.dart' as barrel;
import 'package:zlibx/providers/booklists_state.dart';

void main() {
  test('state model defaults match the pre-split defaults', () {
    const state = BooklistsState();
    expect(state.tab, BooklistTab.mine);
    expect(state.query, '');
    expect(state.order, 'popular');
    expect(state.phase, BooklistsPhase.loading);
    expect(state.lists, isEmpty);
    expect(state.nextPage, 1);
    expect(state.hasMore, isTrue);
    expect(state.isLoadingMore, isFalse);
    expect(state.error, isNull);
  });

  test('copyWith changes only the given fields; clearError clears', () {
    const state = BooklistsState(
      phase: BooklistsPhase.error,
      error: 'boom',
    );
    final next = state.copyWith(tab: BooklistTab.discover);
    expect(next.tab, BooklistTab.discover);
    expect(next.phase, BooklistsPhase.error);
    expect(next.error, 'boom');
    expect(next.copyWith(clearError: true).error, isNull);
    expect(next.copyWith(error: 'other').error, 'other');
  });

  test('barrel re-exports state, controller and cache', () {
    expect(barrel.BooklistsState, isA<Type>());
    expect(barrel.BooklistsController, isA<Type>());
    expect(barrel.BooklistsCache, isA<Type>());
    expect(barrel.BooklistTab, isA<Type>());
    expect(barrel.BooklistsPhase, isA<Type>());
    expect(barrel.booklistsControllerProvider, isNotNull);
    // The barrel's state type is the state file's type.
    expect(const barrel.BooklistsState(), const BooklistsState());
    expect(const barrel.BooklistsState(), isA<BooklistsState>());
  });

  test('controller file declares the provider with the same type', () {
    expect(booklistsControllerProvider, barrel.booklistsControllerProvider);
  });
}
