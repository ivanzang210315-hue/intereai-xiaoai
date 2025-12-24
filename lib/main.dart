import 'package:flutter/material.dart';
import 'main_tab_page.dart';

void main() {
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '小爱蓝牙助手',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const MainTabPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}
