import 'package:flutter/material.dart';
import 'bluetooth_page.dart';
import 'send_page.dart';
import 'image_receiver_page.dart';

class MainTabPage extends StatefulWidget {
  const MainTabPage({super.key});

  @override
  State<MainTabPage> createState() => _MainTabPageState();
}

class _MainTabPageState extends State<MainTabPage> with TickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('小爱蓝牙助手'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        elevation: 4,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          tabs: const [
            Tab(
              icon: Icon(Icons.bluetooth_searching),
              text: '设备扫描',
            ),
            Tab(
              icon: Icon(Icons.send),
              text: '发送内容',
            ),
            Tab(
              icon: Icon(Icons.download),
              text: '接收图片',
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          BluetoothPage(showAppBar: false),
          SendPage(),
          ImageReceiverPage(),
        ],
      ),
    );
  }
}