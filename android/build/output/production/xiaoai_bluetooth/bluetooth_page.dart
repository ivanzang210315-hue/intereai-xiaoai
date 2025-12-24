import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:async';

class BluetoothPage extends StatefulWidget {
  final bool showAppBar;
  
  const BluetoothPage({super.key, this.showAppBar = true});

  @override
  State<BluetoothPage> createState() => _BluetoothPageState();
}

class _BluetoothPageState extends State<BluetoothPage> {
  List<ScanResult> devices = [];
  bool isScanning = false;
  bool isBluetoothEnabled = false;
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<BluetoothAdapterState>? _adapterStateSubscription;
  BluetoothDevice? connectedDevice;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;

  @override
  void initState() {
    super.initState();
    _checkBluetoothState();
    _listenToAdapterState();
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    _adapterStateSubscription?.cancel();
    _connectionStateSubscription?.cancel();
    super.dispose();
  }

  void _listenToAdapterState() {
    _adapterStateSubscription = FlutterBluePlus.adapterState.listen((state) {
      setState(() {
        isBluetoothEnabled = state == BluetoothAdapterState.on;
      });
    });
  }

  Future<void> _checkBluetoothState() async {
    final state = await FlutterBluePlus.adapterState.first;
    setState(() {
      isBluetoothEnabled = state == BluetoothAdapterState.on;
    });
  }

  Future<void> _requestPermissions() async {
    final permissions = [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ];

    Map<Permission, PermissionStatus> statuses = 
        await permissions.request();
    
    bool allGranted = statuses.values.every(
        (status) => status == PermissionStatus.granted);
    
    if (!allGranted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('需要蓝牙和位置权限才能扫描设备')),
      );
    }
  }

  Future<void> _enableBluetooth() async {
    try {
      await FlutterBluePlus.turnOn();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请手动开启蓝牙')),
      );
    }
  }

  Future<void> _startScan() async {
    if (!isBluetoothEnabled) {
      await _enableBluetooth();
      return;
    }

    await _requestPermissions();

    setState(() {
      devices.clear();
      isScanning = true;
    });

    try {
      // 监听扫描结果
      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        setState(() {
          // 对设备进行排序，xiaoai设备置顶
          devices = _sortDevices(results);
        });
      });

      // 开始扫描，设置30秒超时
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 30),
      );

      // 扫描会自动在30秒后停止
      setState(() {
        isScanning = false;
      });
    } catch (e) {
      setState(() {
        isScanning = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('扫描失败: $e')),
      );
    }
  }

  Future<void> _stopScan() async {
    await FlutterBluePlus.stopScan();
    _scanSubscription?.cancel();
    setState(() {
      isScanning = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.showAppBar ? AppBar(
        title: const Text('蓝牙设备扫描'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        elevation: 4,
      ) : null,
      body: Column(
        children: [
          // 蓝牙状态卡片
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isBluetoothEnabled ? Colors.green[50] : Colors.red[50],
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isBluetoothEnabled ? Colors.green : Colors.red,
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  isBluetoothEnabled ? Icons.bluetooth : Icons.bluetooth_disabled,
                  color: isBluetoothEnabled ? Colors.green : Colors.red,
                  size: 24,
                ),
                const SizedBox(width: 12),
                Text(
                  isBluetoothEnabled ? '蓝牙已开启' : '蓝牙已关闭',
                  style: TextStyle(
                    color: isBluetoothEnabled ? Colors.green[800] : Colors.red[800],
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          ),

          // 连接状态卡片
          if (connectedDevice != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.purple[50],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Colors.purple,
                  width: 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.bluetooth_connected,
                        color: Colors.purple[800],
                        size: 24,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '已连接设备',
                        style: TextStyle(
                          color: Colors.purple[800],
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: Colors.green,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _getDeviceNameFromDevice(connectedDevice!),
                    style: TextStyle(
                      color: Colors.purple[700],
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    'MAC: ${connectedDevice!.remoteId}',
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          
          // 扫描按钮
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                onPressed: isScanning ? _stopScan : _startScan,
                icon: Icon(isScanning ? Icons.stop : Icons.search),
                label: Text(
                  isScanning ? '停止扫描' : '开始扫描',
                  style: const TextStyle(fontSize: 16),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: isScanning ? Colors.red : Colors.blue,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // 扫描指示器
          if (isScanning)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Text('正在扫描蓝牙设备...', style: TextStyle(fontSize: 14)),
                ],
              ),
            ),

          // 设备列表
          Expanded(
            child: devices.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.bluetooth_searching,
                          size: 64,
                          color: Colors.grey[400],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          isScanning ? '正在搜索设备...' : '点击上方按钮开始扫描',
                          style: TextStyle(
                            fontSize: 16,
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: devices.length,
                    itemBuilder: (context, index) {
                      final scanResult = devices[index];
                      final device = scanResult.device;
                      final rssi = scanResult.rssi;
                      final deviceName = _getDeviceName(scanResult);
                      final isXiaoai = _isXiaoaiDevice(scanResult);
                      final isConnected = connectedDevice?.remoteId == device.remoteId;
                      
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: isXiaoai ? Border.all(
                            color: Colors.purple,
                            width: 2,
                          ) : null,
                          gradient: isXiaoai ? LinearGradient(
                            colors: [
                              Colors.purple[50]!,
                              Colors.blue[50]!,
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ) : null,
                        ),
                        child: Card(
                          margin: EdgeInsets.zero,
                          elevation: isXiaoai ? 6 : 2,
                          color: isXiaoai ? Colors.transparent : null,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            children: [
                              // xiaoai设备的特殊标识
                              if (isXiaoai)
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.purple[100],
                                    borderRadius: const BorderRadius.only(
                                      topLeft: Radius.circular(12),
                                      topRight: Radius.circular(12),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.star,
                                        color: Colors.purple[800],
                                        size: 18,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        '小爱设备 - 优先显示',
                                        style: TextStyle(
                                          color: Colors.purple[800],
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                        ),
                                      ),
                                      const Spacer(),
                                      if (isConnected)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.green,
                                            borderRadius: BorderRadius.circular(8),
                                          ),
                                          child: const Text(
                                            '已连接',
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              
                              // 设备信息
                              ListTile(
                                leading: Container(
                                  width: 48,
                                  height: 48,
                                  decoration: BoxDecoration(
                                    color: isXiaoai ? Colors.purple[100] : Colors.blue[100],
                                    borderRadius: BorderRadius.circular(24),
                                  ),
                                  child: Icon(
                                    isXiaoai ? Icons.speaker : Icons.bluetooth,
                                    color: isXiaoai ? Colors.purple[800] : Colors.blue[800],
                                    size: 24,
                                  ),
                                ),
                                title: Text(
                                  deviceName,
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                    color: isXiaoai ? Colors.purple[800] : null,
                                  ),
                                ),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const SizedBox(height: 4),
                                    Text(
                                      'MAC: ${device.remoteId}',
                                      style: TextStyle(
                                        color: Colors.grey[600],
                                        fontSize: 12,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Row(
                                      children: [
                                        Icon(
                                          Icons.signal_cellular_alt,
                                          size: 14,
                                          color: _getRssiColor(rssi),
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          '$rssi dBm',
                                          style: TextStyle(
                                            color: _getRssiColor(rssi),
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        if (scanResult.advertisementData.connectable && !isXiaoai)
                                          Padding(
                                            padding: const EdgeInsets.only(left: 8),
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(
                                                horizontal: 6,
                                                vertical: 2,
                                              ),
                                              decoration: BoxDecoration(
                                                color: Colors.green[100],
                                                borderRadius: BorderRadius.circular(8),
                                              ),
                                              child: Text(
                                                '可连接',
                                                style: TextStyle(
                                                  color: Colors.green[800],
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                                trailing: isXiaoai ? null : Icon(
                                  Icons.arrow_forward_ios,
                                  color: Colors.grey[400],
                                  size: 16,
                                ),
                                onTap: !isXiaoai ? () {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('点击了设备: $deviceName'),
                                    ),
                                  );
                                } : null,
                              ),
                              
                              // xiaoai设备的连接按钮
                              if (isXiaoai && scanResult.advertisementData.connectable)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                                  child: SizedBox(
                                    width: double.infinity,
                                    height: 45,
                                    child: ElevatedButton.icon(
                                      onPressed: isConnected 
                                          ? _disconnectDevice
                                          : () => _connectToDevice(device),
                                      icon: Icon(
                                        isConnected 
                                            ? Icons.bluetooth_disabled 
                                            : Icons.bluetooth_connected,
                                      ),
                                      label: Text(
                                        isConnected ? '断开连接' : '连接设备',
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: isConnected 
                                            ? Colors.red[600] 
                                            : Colors.purple[600],
                                        foregroundColor: Colors.white,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        elevation: 3,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  List<ScanResult> _sortDevices(List<ScanResult> results) {
    // 分离xiaoai设备和其他设备
    List<ScanResult> xiaoaiDevices = [];
    List<ScanResult> otherDevices = [];
    
    for (var result in results) {
      final deviceName = _getDeviceName(result).toLowerCase();
      if (deviceName.contains('xiaoai') || deviceName.contains('小爱')) {
        xiaoaiDevices.add(result);
      } else {
        otherDevices.add(result);
      }
    }
    
    // xiaoai设备按信号强度排序
    xiaoaiDevices.sort((a, b) => b.rssi.compareTo(a.rssi));
    // 其他设备按信号强度排序
    otherDevices.sort((a, b) => b.rssi.compareTo(a.rssi));
    
    // xiaoai设备置顶
    return [...xiaoaiDevices, ...otherDevices];
  }

  String _getDeviceName(ScanResult scanResult) {
    final device = scanResult.device;
    if (device.platformName.isNotEmpty) {
      return device.platformName;
    }
    if (scanResult.advertisementData.localName.isNotEmpty) {
      return scanResult.advertisementData.localName;
    }
    return '未知设备';
  }

  bool _isXiaoaiDevice(ScanResult scanResult) {
    final deviceName = _getDeviceName(scanResult).toLowerCase();
    return deviceName.contains('xiaoai') || deviceName.contains('小爱');
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    try {
      // 显示连接中状态
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
              const SizedBox(width: 16),
              Text('正在连接到 ${_getDeviceNameFromDevice(device)}...'),
            ],
          ),
          duration: const Duration(seconds: 10),
          backgroundColor: Colors.blue,
        ),
      );

      // 先监听连接状态
      _connectionStateSubscription?.cancel();
      _connectionStateSubscription = device.connectionState.listen((state) {
        setState(() {
          if (state == BluetoothConnectionState.connected) {
            connectedDevice = device;
          } else if (state == BluetoothConnectionState.disconnected) {
            connectedDevice = null;
          }
        });
      });

      // 尝试连接，设置15秒超时
      await device.connect(timeout: const Duration(seconds: 15));
      
      // 等待一小段时间确保连接稳定
      await Future.delayed(const Duration(milliseconds: 500));
      
      // 验证连接状态
      final connectionState = await device.connectionState.first;
      
      if (connectionState == BluetoothConnectionState.connected) {
        // 尝试发现服务来验证连接是否真正有效
        try {
          final services = await device.discoverServices();
          
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('✅ 成功连接到 ${_getDeviceNameFromDevice(device)}\\n发现 ${services.length} 个服务'),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 3),
            ),
          );
        } catch (serviceError) {
          // 即使服务发现失败，连接可能仍然有效
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('⚠️ 连接到 ${_getDeviceNameFromDevice(device)}，但无法发现服务'),
              backgroundColor: Colors.orange,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      } else {
        throw Exception('连接状态验证失败');
      }
    } catch (e) {
      // 连接失败，清理状态
      setState(() {
        connectedDevice = null;
      });
      
      String errorMessage = '连接失败';
      if (e.toString().contains('timeout')) {
        errorMessage = '连接超时，请确保设备在附近且可连接';
      } else if (e.toString().contains('already connected')) {
        errorMessage = '设备已经连接';
      } else if (e.toString().contains('device not found')) {
        errorMessage = '设备未找到，请重新扫描';
      } else {
        errorMessage = '连接失败: ${e.toString()}';
      }
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ $errorMessage'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  Future<void> _disconnectDevice() async {
    if (connectedDevice != null) {
      try {
        final deviceName = _getDeviceNameFromDevice(connectedDevice!);
        
        // 显示断开中状态
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                ),
                const SizedBox(width: 16),
                Text('正在断开连接...'),
              ],
            ),
            duration: const Duration(seconds: 3),
            backgroundColor: Colors.orange,
          ),
        );
        
        await connectedDevice!.disconnect();
        
        // 等待确认断开
        await Future.delayed(const Duration(milliseconds: 500));
        
        // 清理连接状态
        _connectionStateSubscription?.cancel();
        setState(() {
          connectedDevice = null;
        });
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ 已成功断开与 $deviceName 的连接'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ 断开连接失败: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  String _getDeviceNameFromDevice(BluetoothDevice device) {
    return device.platformName.isNotEmpty ? device.platformName : '未知设备';
  }

  Color _getRssiColor(int? rssi) {
    if (rssi == null) return Colors.grey;
    if (rssi > -50) return Colors.green;
    if (rssi > -70) return Colors.orange;
    return Colors.red;
  }
}