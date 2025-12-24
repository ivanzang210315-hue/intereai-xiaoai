import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path;
import 'dart:convert'; // Added for utf8.encode

class SendPage extends StatefulWidget {
  const SendPage({super.key});

  @override
  State<SendPage> createState() => _SendPageState();
}

class _SendPageState extends State<SendPage> {
  final TextEditingController _textController = TextEditingController();
  final ImagePicker _imagePicker = ImagePicker();
  List<BluetoothDevice> connectedDevices = [];
  BluetoothDevice? selectedDevice;
  File? selectedImage;
  bool isSending = false;

  @override
  void initState() {
    super.initState();
    _loadConnectedDevices();
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _loadConnectedDevices() async {
    try {
      final devices = FlutterBluePlus.connectedDevices;
      setState(() {
        connectedDevices = devices;
        if (devices.isNotEmpty) {
          selectedDevice = devices.first;
        }
      });
    } catch (e) {
      print('获取连接设备失败: $e');
    }
  }

  Future<void> _pickImage() async {
    try {
      // 请求存储权限
      final storageStatus = await Permission.storage.request();
      final photosStatus = await Permission.photos.request();
      
      if (storageStatus != PermissionStatus.granted && 
          photosStatus != PermissionStatus.granted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('需要存储权限才能访问相册'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }
      
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );
      
      if (image != null) {
        setState(() {
          selectedImage = File(image.path);
        });
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('选择图片失败: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _takePhoto() async {
    try {
      // 请求相机权限
      final cameraStatus = await Permission.camera.request();
      
      if (cameraStatus != PermissionStatus.granted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('需要相机权限才能拍照'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }
      
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );
      
      if (image != null) {
        setState(() {
          selectedImage = File(image.path);
        });
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('拍照失败: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _sendText() async {
    if (_textController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请输入要发送的文字'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    if (selectedDevice == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先连接设备'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      isSending = true;
    });

    try {
      // 发送文字内容到设备
      await _sendCommandToDevice(_textController.text);
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ 文字发送成功: "${_textController.text}"'),
          backgroundColor: Colors.green,
        ),
      );
      
      _textController.clear();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ 发送失败: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      setState(() {
        isSending = false;
      });
    }
  }

  Future<void> _sendAlbumSync() async {
    if (selectedDevice == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先连接设备'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      isSending = true;
    });

    try {
      // 发送相册同步命令到设备
      await _sendCommandToDevice('AlbumSync');
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ 相册同步命令发送成功: AlbumSync'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ 相册同步失败: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      setState(() {
        isSending = false;
      });
    }
  }

  Future<void> _sendImage() async {
    if (selectedImage == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先选择图片'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    if (selectedDevice == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先连接设备'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      isSending = true;
    });

    try {
      // 执行图片发送命令
      final fileName = path.basename(selectedImage!.path);
      final targetPath = '/tmp/$fileName';
      
      // 模拟您提供的命令格式
      final copyCommand = 'cp ${selectedImage!.path} $targetPath';
      final triggerCommand = 'touch /tmp/send';
      
      await _sendCommandToDevice(copyCommand);
      await Future.delayed(const Duration(milliseconds: 500));
      await _sendCommandToDevice(triggerCommand);
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ 图片发送成功\\n复制到: $targetPath\\n触发文件: /tmp/send'),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 4),
        ),
      );
      
      setState(() {
        selectedImage = null;
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ 发送失败: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      setState(() {
        isSending = false;
      });
    }
  }

  Future<void> _sendCommandToDevice(String command) async {
    if (selectedDevice == null) return;
    
    try {
      // 发现设备服务
      final services = await selectedDevice!.discoverServices();
      
      // 这里您需要根据设备的实际服务和特征值来实现
      // 以下是一个通用的示例，您可能需要根据设备文档调整
      for (var service in services) {
        for (var characteristic in service.characteristics) {
          if (characteristic.properties.write) {
            // 将命令转换为UTF-8字节数组
            final data = utf8.encode(command);  // 使用UTF-8编码
            await characteristic.write(data);
            return;
          }
        }
      }
      
      throw Exception('未找到可写入的特征值');
    } catch (e) {
      throw Exception('发送命令失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 连接状态卡片
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: connectedDevices.isNotEmpty ? Colors.green[50] : Colors.red[50],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: connectedDevices.isNotEmpty ? Colors.green : Colors.red,
                  width: 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        connectedDevices.isNotEmpty 
                            ? Icons.bluetooth_connected 
                            : Icons.bluetooth_disabled,
                        color: connectedDevices.isNotEmpty ? Colors.green : Colors.red,
                        size: 24,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        connectedDevices.isNotEmpty 
                            ? '设备已连接 (${connectedDevices.length})' 
                            : '无连接设备',
                        style: TextStyle(
                          color: connectedDevices.isNotEmpty 
                              ? Colors.green[800] 
                              : Colors.red[800],
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        onPressed: _loadConnectedDevices,
                        icon: const Icon(Icons.refresh),
                        tooltip: '刷新设备列表',
                      ),
                    ],
                  ),
                  if (connectedDevices.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    DropdownButtonFormField<BluetoothDevice>(
                      value: selectedDevice,
                      decoration: const InputDecoration(
                        labelText: '选择目标设备',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                      items: connectedDevices.map((device) {
                        return DropdownMenuItem(
                          value: device,
                          child: Text(
                            device.platformName.isNotEmpty 
                                ? device.platformName 
                                : device.remoteId.toString(),
                          ),
                        );
                      }).toList(),
                      onChanged: (device) {
                        setState(() {
                          selectedDevice = device;
                        });
                      },
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 24),

            // 文字发送区域
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.blue[50],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.blue, width: 1),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.text_fields, color: Colors.blue[800]),
                      const SizedBox(width: 8),
                      Text(
                        '发送文字',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.blue[800],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _textController,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: '输入要发送的文字内容...',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.all(12),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 48,
                          child: ElevatedButton.icon(
                            onPressed: isSending ? null : _sendText,
                            icon: isSending 
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.send),
                            label: Text(isSending ? '发送中...' : '发送文字'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blue[600],
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SizedBox(
                          height: 48,
                          child: ElevatedButton.icon(
                            onPressed: isSending ? null : _sendAlbumSync,
                            icon: isSending 
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.sync),
                            label: Text(isSending ? '同步中...' : '相册同步'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.orange[600],
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // 图片发送区域
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.purple[50],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.purple, width: 1),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.image, color: Colors.purple[800]),
                      const SizedBox(width: 8),
                      Text(
                        '发送图片',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.purple[800],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  
                  // 图片选择按钮
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _pickImage,
                          icon: const Icon(Icons.photo_library),
                          label: const Text('选择图片'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.purple[700],
                            side: BorderSide(color: Colors.purple[300]!),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _takePhoto,
                          icon: const Icon(Icons.camera_alt),
                          label: const Text('拍照'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.purple[700],
                            side: BorderSide(color: Colors.purple[300]!),
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),

                  // 图片预览
                  if (selectedImage != null) ...[
                    Container(
                      width: double.infinity,
                      height: 200,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey[300]!),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.file(
                          selectedImage!,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '文件: ${path.basename(selectedImage!.path)}',
                      style: TextStyle(
                        color: Colors.grey[600],
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // 发送按钮
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton.icon(
                      onPressed: (isSending || selectedImage == null) ? null : _sendImage,
                      icon: isSending 
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.upload),
                      label: Text(isSending ? '发送中...' : '发送图片'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.purple[600],
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  // 命令说明
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '执行命令:',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.grey[700],
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'cp /userdata/image.jpg /tmp/image.jpg',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            color: Colors.grey[600],
                            fontSize: 11,
                          ),
                        ),
                        Text(
                          'touch /tmp/send',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            color: Colors.grey[600],
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}