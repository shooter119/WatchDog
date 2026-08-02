import 'package:flutter/material.dart';

import 'pages/board_page.dart';
import 'pages/home_page.dart';
import 'pages/roster_page.dart';
import 'pages/settings_page.dart';
import 'state/app_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const WatchDogApp());
}

class WatchDogApp extends StatefulWidget {
  const WatchDogApp({super.key});

  @override
  State<WatchDogApp> createState() => _WatchDogAppState();
}

class _WatchDogAppState extends State<WatchDogApp> {
  final AppController controller = AppController();
  int _tab = 1;

  @override
  void initState() {
    super.initState();
    controller.init();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '安全员助手',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFD32F2F),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF121417),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1A1D21),
          centerTitle: true,
        ),
      ),
      home: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final pages = [
            BoardPage(controller: controller),
            HomePage(controller: controller),
            RosterPage(controller: controller),
            SettingsPage(controller: controller),
          ];
          return Scaffold(
            body: pages[_tab],
            bottomNavigationBar: NavigationBar(
              selectedIndex: _tab,
              backgroundColor: const Color(0xFF1A1D21),
              onDestinationSelected: (i) => setState(() => _tab = i),
              destinations: const [
                NavigationDestination(icon: Icon(Icons.dashboard), label: '看板'),
                NavigationDestination(icon: Icon(Icons.mic), label: '语音录入'),
                NavigationDestination(icon: Icon(Icons.group), label: '名单'),
                NavigationDestination(icon: Icon(Icons.settings), label: '设置'),
              ],
            ),
          );
        },
      ),
    );
  }
}
