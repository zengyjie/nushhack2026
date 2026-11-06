import 'package:flutter/material.dart';

import 'screens/enrol_screen.dart';
import 'screens/home_shell.dart';
import 'screens/unlock_screen.dart';
import 'state/app_state.dart';
import 'theme.dart';
import 'widgets/common.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MeshApp(store: AppState()));
}

class MeshApp extends StatelessWidget {
  const MeshApp({super.key, required this.store});
  final AppState store;

  @override
  Widget build(BuildContext context) => StoreScope(
        store: store,
        child: MaterialApp(
          title: 'MESH',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(),
          home: const _Root(),
        ),
      );
}

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: switch (store.phase) {
        Phase.loading => const Scaffold(body: Center(child: LogoTile(size: 72))),
        Phase.enrol => const EnrolScreen(),
        Phase.locked => const UnlockScreen(),
        Phase.ready => const HomeShell(),
      },
    );
  }
}
