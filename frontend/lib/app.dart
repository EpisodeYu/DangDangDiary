import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'config/router.dart';
import 'config/theme.dart';
import 'providers/auth_provider.dart';
import 'providers/notification_provider.dart';
import 'providers/pet_provider.dart';
import 'services/api_client.dart';
import 'services/notification_service.dart';

class DangDangDiaryApp extends ConsumerWidget {
  const DangDangDiaryApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);

    return _AppLifecycleHost(
      router: router,
      child: MaterialApp.router(
        title: '当当日记',
        theme: AppTheme.lightTheme,
        routerConfig: router,
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}

/// Host widget that owns app-lifecycle side-effects:
///   * Requests notification permission once the user is logged in.
///   * Rebuilds the local health reminder schedule on cold start, on
///     every resume from background, and whenever authentication
///     transitions to [AuthStatus.authenticated].
///   * Dispatches pending notification-tap payloads to the router so
///     clicking a health reminder opens the right pet's health page.
class _AppLifecycleHost extends ConsumerStatefulWidget {
  const _AppLifecycleHost({
    required this.router,
    required this.child,
  });

  final GoRouter router;
  final Widget child;

  @override
  ConsumerState<_AppLifecycleHost> createState() => _AppLifecycleHostState();
}

class _AppLifecycleHostState extends ConsumerState<_AppLifecycleHost>
    with WidgetsBindingObserver {
  bool _permissionRequested = false;
  bool _didInitialRefresh = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NotificationService.instance.pendingHealthPetId
        .addListener(_onPendingPayloadChanged);
  }

  @override
  void dispose() {
    NotificationService.instance.pendingHealthPetId
        .removeListener(_onPendingPayloadChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Drop any keep-alive TCP sockets dart:io was still holding
      // while we were backgrounded — the carrier's NAT almost
      // certainly expired their 4-tuple by now, and reusing one of
      // them silently wedges the first request after resume (observed
      // on `/photos/classify` but the hazard applies to any POST
      // returning to the foreground). See
      // `ApiClient.resetConnectionPool` for the full writeup.
      ApiClient().resetConnectionPool();
      _maybeRefreshReminders();
      _tryHandlePendingPayload();
      // Opt Step 4: another device / owner may have changed our role
      // or pet meta while we were backgrounded. silentRefresh fetches
      // the latest pet list and only swaps state when there's a real
      // diff, so no loading flicker hits the UI.
      final auth = ref.read(authProvider);
      if (auth.status == AuthStatus.authenticated) {
        ref.read(petListProvider.notifier).silentRefresh();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AuthState>(authProvider, (prev, next) {
      final becameAuthed = prev?.status != AuthStatus.authenticated &&
          next.status == AuthStatus.authenticated;
      if (becameAuthed) {
        _onAuthenticated();
      }
      if (next.status == AuthStatus.unauthenticated) {
        _didInitialRefresh = false;
        _permissionRequested = false;
        NotificationService.instance.cancelAllHealthReminders();
      }
    });

    final auth = ref.read(authProvider);
    if (!_didInitialRefresh && auth.status == AuthStatus.authenticated) {
      _didInitialRefresh = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _onAuthenticated();
      });
    }

    ref.listen(petListProvider, (prev, next) {
      if (next.hasValue) {
        _tryHandlePendingPayload();
      }
    });

    return widget.child;
  }

  Future<void> _onAuthenticated() async {
    if (!_permissionRequested) {
      _permissionRequested = true;
      try {
        await NotificationService.instance.requestPermission();
      } catch (_) {}
    }
    await _maybeRefreshReminders();
    _tryHandlePendingPayload();
  }

  Future<void> _maybeRefreshReminders() async {
    final auth = ref.read(authProvider);
    if (auth.status != AuthStatus.authenticated) return;
    try {
      await ref.read(healthReminderSchedulerProvider).refresh();
    } catch (_) {}
  }

  void _onPendingPayloadChanged() {
    _tryHandlePendingPayload();
  }

  void _tryHandlePendingPayload() {
    final petId = NotificationService.instance.pendingHealthPetId.value;
    if (petId == null) return;

    final auth = ref.read(authProvider);
    if (auth.status != AuthStatus.authenticated) return;

    final petsAsync = ref.read(petListProvider);
    final pets = petsAsync.valueOrNull?.pets;
    if (pets == null) return;

    final matched = pets.any((p) => p.id == petId);
    if (!matched) {
      NotificationService.instance.pendingHealthPetId.value = null;
      return;
    }

    ref.read(selectedPetIdProvider.notifier).select(petId);
    try {
      widget.router.go('/health');
    } catch (_) {}
    NotificationService.instance.pendingHealthPetId.value = null;
  }
}
