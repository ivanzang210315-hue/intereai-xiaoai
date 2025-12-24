import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:file_picker/file_picker.dart'; // 添加文件选择器
import 'package:path/path.dart' as path; // 添加路径处理
import 'package:gal/gal.dart'; // 添加gal库
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart'; // 替换video_compress
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path_provider/path_provider.dart';   // 添加路径提供器
import 'package:share_plus/share_plus.dart'; // 添加分享功能
// 已优化：使用流式写入文件，不再占用大量内存，避免OOM
// 优化内容：
// 1. 使用BytesBuilder替代Uint8List减少内存复制
// 2. 接收数据时直接写入临时文件，不累积在内存中
// 3. 相册模式改为逐个处理文件，不再使用队列
// 4. 减少setState调用频率，提升UI性能
// 消息类型定义（与设备端保持一致）
class MessageType {
  static const int config = 0x01;
  static const int imageStart = 0x10;
  static const int imageData = 0x11;
  static const int imageEnd = 0x12;
  static const int imageAck = 0x13;
  static const int imageREStart = 0x22;
  static const int requestImage = 0x23;  // 请求发送图片（识图模式）
  static const int saveToAlbum = 0x24;   // 保存到相册模式
  static const int albumSyncStart = 0x25; // 相册同步开始
  static const int albumSyncEnd = 0x26;   // 相册同步结束
  static const int albumClean = 0x27;   // 相册清空
  // 新增系统更新相关消息类型
  static const int updateStart = 0x30;  // MSG_UPDATE_START
  static const int updateData = 0x31;    // MSG_UPDATE_DATA
  static const int updateEnd = 0x32;     // MSG_UPDATE_END
  static const int updateAck = 0x33;     // MSG_UPDATE_ACK
}

// API配置
class APIConfig {
  static const String qianwenURL = 'https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation';
  static const String qianwenKey = 'sk-7887c3*******************5';
  
  static const String gpt4oURL = 'https://aihubmix.com/v1/chat/completions';
  static const String gpt4oKey = 'sk-jXGpf18rOFk*******************A68f';
}

class ImageReceiverPage extends StatefulWidget {
  const ImageReceiverPage({super.key});

  @override
  State<ImageReceiverPage> createState() => _ImageReceiverPageState();
}

class _ImageReceiverPageState extends State<ImageReceiverPage> {
  bool isReceiving = false;
  int totalReceivedBytes = 0;
  int chunkCount = 0;
  String statusMessage = '等待连接设备...';
  List<String> logMessages = [];
  Socket? _socket;
  StreamSubscription<List<int>>? _socketSubscription;
  bool imageStarted = false;
  
  final TextEditingController _ipController = TextEditingController();
  Uint8List? receivedImageData;
  ui.Image? displayImage;
  bool isImageReceived = false;

  // 修改：使用BytesBuilder替代Uint8List以提高性能
  final BytesBuilder _dataBuffer = BytesBuilder(copy: false);
  bool _processingData = false;
  Completer<void>? _connectionCompleter;
  
  // 新增：流式文件写入相关变量
  RandomAccessFile? _currentReceivingFile;
  String? _currentTempFilePath;
  int _currentFileSize = 0;

  // 添加AI识别相关变量
  String recognitionResult = '';
  bool isRecognizing = false;

  // 新增：系统更新相关变量
  File? selectedUpdateFile;
  bool isUpdating = false;
  double updateProgress = 0.0;
  bool isUpdateExpanded = false; // 新增：控制折叠状态

  // 新增：接收模式
  String receiveMode = ''; // 'recognize' 或 'album'

  // 新增：相册同步相关变量
  int totalImages = 0;
  int receivedImages = 0;
  bool isAlbumSync = false;

  // 新增：当前接收的文件信息
  String? currentFileName;
  String? currentFileExtension;

  // 新增：文件预览相关变量
  List<SavedFile> savedFiles = [];
  bool isLoadingFiles = false;
  Set<String> selectedFiles = {}; // 新增：选中的文件路径集合

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _ipController.text = '192.168.199.198';
    _loadSavedFiles();
  }

  @override
  void dispose() {
    _socketSubscription?.cancel();
    _socket?.close();
    _ipController.dispose();
    _cleanupCurrentReceivingFile();
    super.dispose();
  }
  
  // 新增：清理当前接收文件资源
  Future<void> _cleanupCurrentReceivingFile() async {
    try {
      if (_currentReceivingFile != null) {
        await _currentReceivingFile!.close();
        _currentReceivingFile = null;
      }
      if (_currentTempFilePath != null) {
        final tempFile = File(_currentTempFilePath!);
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
        _currentTempFilePath = null;
      }
      _currentFileSize = 0;
    } catch (e) {
      print('清理临时文件失败: $e');
    }
  }

  Future<void> _requestPermissions() async {
    final permissions = [
      Permission.storage,
      Permission.manageExternalStorage,
      Permission.photos, // 添加相册权限
    ];

    Map<Permission, PermissionStatus> statuses = 
        await permissions.request();
    
    bool allGranted = statuses.values.every(
        (status) => status == PermissionStatus.granted);
    
    if (!allGranted) {
      _addLogMessage('⚠️ 需要存储权限才能保存图片');
    }
  }

  void _addLogMessage(String message) {
    setState(() {
      logMessages.add('${DateTime.now().toString().substring(11, 19)}: $message');
      if (logMessages.length > 50) {
        logMessages.removeAt(0);
      }
    });
    print(' [LOG] $message');
  }

  Future<void> _startReceiving(String mode) async {
    if (isReceiving) return;
    
    final inputIp = _ipController.text.trim();
    if (inputIp.isEmpty || !_isValidIp(inputIp)) {
      _addLogMessage('❌ 请输入有效的IP地址');
      return;
    }

    setState(() {
      isReceiving = true;
      totalReceivedBytes = 0;
      chunkCount = 0;
      imageStarted = false;
      receiveMode = mode;
      statusMessage = mode == 'recognize' ? '正在连接设备进行识图...' : '正在连接设备进行相册同步...';
      logMessages.clear();
      receivedImageData = null;
      displayImage = null;
      isImageReceived = false;
      recognitionResult = ''; // 清空识别结果
      _dataBuffer.clear();
      // 重置相册同步状态
      totalImages = 0;
      receivedImages = 0;
      isAlbumSync = false;
      currentFileName = null;
      currentFileExtension = null;
    });

    try {
      await _connectAndSetupSocket(inputIp);
      _addLogMessage('✅ 连接和监听器设置完成，等待数据...');
      
      // 发送对应的请求消息
      if (mode == 'recognize') {
        await _sendRequestMessage(MessageType.requestImage);
        _addLogMessage('📤 发送识图请求 (0x23)');
      } else {
        await _sendRequestMessage(MessageType.saveToAlbum);
        _addLogMessage('📤 发送相册同步请求 (0x24)');
      }
      
    } catch (e) {
      _addLogMessage('❌ 连接失败: $e');
      setState(() {
        statusMessage = '连接失败: $e';
        isReceiving = false;
      });
    }
  }

  Future<void> _connectAndSetupSocket(String ip) async {
    _connectionCompleter = Completer<void>();
    
    _addLogMessage('🔗 正在连接: $ip:8080');
    
    // 先创建Socket连接
    _socket = await Socket.connect(ip, 8080, timeout: Duration(seconds: 10));
    _addLogMessage('✅ Socket连接成功');
    
    // 立即设置监听器（在连接完成之前）
    _setupSocketListener();
    
    // 完成连接
    _connectionCompleter!.complete();
    await _connectionCompleter!.future;
    
    _addLogMessage('🎯 连接流程完成，准备接收数据');
  }

  void _setupSocketListener() {
    if (_socket == null) return;

    _addLogMessage('📡 立即设置Socket数据监听器...');
    
    _socketSubscription = _socket!.listen(
      (data) {
        //_addLogMessage('📥 收到数据: ${data.length} 字节');
        _handleIncomingData(Uint8List.fromList(data));
      },
      onError: (error) {
        _addLogMessage('❌ Socket错误: $error');
        _cleanupConnection();
      },
      onDone: () {
        _addLogMessage('🔌 Socket连接关闭');
        _cleanupConnection();
      },
      cancelOnError: true,
    );

    _addLogMessage('✅ 数据监听器设置完成');
  }

  void _handleIncomingData(Uint8List newData) {
    // 将新数据添加到缓冲区（使用BytesBuilder，避免内存复制）
    _dataBuffer.add(newData);
    
    //_addLogMessage('📦 缓冲区大小: ${_dataBuffer.length} 字节');
    
    // 异步处理缓冲区（不阻塞Socket接收）
    _processBuffer().then((_) {
      // 处理完成后，如果缓冲区还有数据，继续处理
      if (_dataBuffer.isNotEmpty && !_processingData) {
        _processBuffer();
      }
    });
  }

  Future<void> _processBuffer() async {
    if (_processingData || _dataBuffer.isEmpty) return;
    
    _processingData = true;
    
    try {
      // 将BytesBuilder转换为Uint8List进行处理
      Uint8List bufferBytes = _dataBuffer.toBytes();
      
      while (bufferBytes.length >= 5) {
        // 解析消息头
        final msgType = bufferBytes[0];
        final dataLength = (bufferBytes[1] << 24) | 
                         (bufferBytes[2] << 16) | 
                         (bufferBytes[3] << 8) | 
                         bufferBytes[4];
        
        //_addLogMessage('📋 解析消息头: 类型=0x${msgType.toRadixString(16).padLeft(2, '0')}, 长度=$dataLength');
        
        // 检查是否有足够的数据
        if (bufferBytes.length < 5 + dataLength) {
          //_addLogMessage('⏳ 等待更多数据: 需要 ${5 + dataLength} 字节，当前 ${bufferBytes.length} 字节');
          // 将剩余数据放回缓冲区
          _dataBuffer.clear();
          _dataBuffer.add(bufferBytes);
          break;
        }
        
        // 提取消息数据
        Uint8List messageData;
        if (dataLength > 0) {
          messageData = bufferBytes.sublist(5, 5 + dataLength);
        } else {
          messageData = Uint8List(0);
        }
        
        // 移除已处理的数据
        bufferBytes = bufferBytes.sublist(5 + dataLength);
        //_addLogMessage('✅ 提取数据成功，剩余缓冲区: ${bufferBytes.length} 字节');
        
        // 处理消息 - 添加await确保ACK发送完成
        await _processMessage(msgType, messageData);
      }
      
      // 如果还有剩余数据，放回缓冲区
      if (bufferBytes.isNotEmpty) {
        _dataBuffer.clear();
        _dataBuffer.add(bufferBytes);
      } else {
        _dataBuffer.clear();
      }
    } catch (e) {
      _addLogMessage('❌ 处理缓冲区数据时出错: $e');
    } finally {
      _processingData = false;
    }
  }

  Future<void> _processMessage(int msgType, Uint8List data) async {
    //_addLogMessage('🔄 处理消息: 类型=0x${msgType.toRadixString(16).padLeft(2, '0')}, 数据长度=${data.length}');
    
    switch (msgType) {
      case MessageType.config:
        final config = String.fromCharCodes(data);
        _addLogMessage('📋 配置信息: $config');
        
        // 解析配置信息获取文件名
        try {
          final configJson = jsonDecode(config);
          if (configJson['filename'] != null) {
            currentFileName = configJson['filename'];
            currentFileExtension = path.extension(currentFileName!).toLowerCase();
            _addLogMessage('📄 文件信息: $currentFileName, 扩展名: $currentFileExtension');
          }
        } catch (e) {
          _addLogMessage('⚠️ 配置信息解析失败: $e');
        }
        break;

      case MessageType.imageStart:
        _addLogMessage('🚀 开始接收文件数据');
        
        // 清理之前的临时文件
        await _cleanupCurrentReceivingFile();
        
        // 创建临时文件用于流式写入
        final tempDir = Directory.systemTemp;
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final extension = currentFileExtension ?? '.tmp';
        _currentTempFilePath = '${tempDir.path}/receiving_$timestamp$extension';
        final tempFile = File(_currentTempFilePath!);
        _currentReceivingFile = await tempFile.open(mode: FileMode.write);
        _currentFileSize = 0;
        
        setState(() {
          imageStarted = true;
          totalReceivedBytes = 0;
          chunkCount = 0;
          receivedImageData = null;
          recognitionResult = '';
        });
        
        _addLogMessage('📁 临时文件已创建: $_currentTempFilePath');
        break;

      case MessageType.imageData:
        if (imageStarted && _currentReceivingFile != null) {
          // 直接将数据写入文件，不占用内存
          await _currentReceivingFile!.writeFrom(data);
          _currentFileSize += data.length;
          
          // 每收到一个数据块立即发送ACK（与C端流式发送同步）
          await _sendAckMessage();
          
          // 减少setState调用频率，每100个数据块才更新一次UI
          if (chunkCount % 100 == 0) {
            setState(() {
              totalReceivedBytes = _currentFileSize;
              chunkCount++;
            });
          } else {
            totalReceivedBytes = _currentFileSize;
            chunkCount++;
          }
        }
        break;

      case MessageType.imageEnd:
        _addLogMessage('🏁 文件数据接收完成');
        _addLogMessage('📊 总计接收: ${(totalReceivedBytes / 1024).toStringAsFixed(1)} KB');
        
        // 关闭文件
        if (_currentReceivingFile != null) {
          await _currentReceivingFile!.close();
          _currentReceivingFile = null;
        }
        
        if (_currentTempFilePath != null && await File(_currentTempFilePath!).exists()) {
          await _sendAckMessage();
          
          // 根据模式处理
          if (receiveMode == 'album') {
            // 相册模式：后台异步处理文件（不阻塞消息循环）
            final extension = currentFileExtension ?? '.unknown';
            final ts = DateTime.now().millisecondsSinceEpoch;
            final fileName = currentFileName ?? '眼镜_$ts$extension';
            final tempFilePath = _currentTempFilePath!;  // 保存临时文件路径
            
            receivedImages++;
            _addLogMessage('📥 已接收: $fileName ($receivedImages/$totalImages)，后台处理中...');
            
            // 立即重置状态准备接收下一个文件（不等待文件处理完成）
            _currentReceivingFile = null;
            _currentTempFilePath = null;
            _currentFileSize = 0;
            
            setState(() {
              totalReceivedBytes = 0;
              chunkCount = 0;
              imageStarted = false;
              receivedImageData = null;
              displayImage = null;
              isImageReceived = false;
              currentFileName = null;
              currentFileExtension = null;
            });
            
            // 在后台异步处理文件（不阻塞）
            _processFileInBackground(fileName, extension, tempFilePath);
            
          } else {
            // 识图模式：需要读取文件到内存用于AI识别
            final tempFile = File(_currentTempFilePath!);
            receivedImageData = await tempFile.readAsBytes();
            await _processReceivedFile();
            _callImageRecognition();
            
            // 清理临时文件
            await _cleanupCurrentReceivingFile();
            
            setState(() {
              statusMessage = '图片接收完成！';
              isReceiving = false;
            });
          }
        }
        break;

      case MessageType.albumSyncStart:
        // 相册同步开始
        final syncInfo = String.fromCharCodes(data);
        final parts = syncInfo.split(':');
        if (parts.length == 2) {
          totalImages = int.tryParse(parts[1]) ?? 0;
          _addLogMessage('📁 相册同步开始，共 $totalImages 张图片');
          setState(() {
            isAlbumSync = true;
            receivedImages = 0;
          });
        }
        break;

      case MessageType.albumSyncEnd:
        // 相册同步结束（文件已经在接收时逐个处理）
        _addLogMessage('✅ 相册同步完成，共处理 $receivedImages 个文件');
        setState(() {
          isAlbumSync = false;
          statusMessage = '相册同步完成！';
          isReceiving = false;
        });
        break;

      case MessageType.updateStart:
        _addLogMessage('📁 [UPDATE] 收到更新开始消息');
        final startMessage = String.fromCharCodes(data);
        final parts = startMessage.split(':');
        if (parts.length == 2) {
          final fileName = parts[0];
          final fileSize = int.tryParse(parts[1]);
          if (fileSize != null) {
            setState(() {
              selectedUpdateFile = File(fileName);
            });
            _addLogMessage('📁 [UPDATE] 文件名: $fileName, 大小: $fileSize 字节');
          } else {
            _addLogMessage('⚠️ [UPDATE] 文件大小格式错误');
          }
        } else {
          _addLogMessage('⚠️ [UPDATE] 更新开始消息格式错误');
        }
        break;

      case MessageType.updateData:
        if (selectedUpdateFile != null) {
          try {
            await selectedUpdateFile!.writeAsBytes(data, mode: FileMode.append);
            final currentSize = await selectedUpdateFile!.length();
            final progress = currentSize / (selectedUpdateFile!.lengthSync());
            setState(() {
              updateProgress = progress;
            });
            _addLogMessage('📁 [UPDATE] 接收数据块: ${data.length} 字节, 当前大小: $currentSize 字节, 进度: ${(progress * 100).toStringAsFixed(1)}%');
          } catch (e) {
            _addLogMessage('❌ [UPDATE] 写入文件失败: $e');
          }
        }
        break;

      case MessageType.updateEnd:
        _addLogMessage('🏁 [UPDATE] 更新文件接收完成');
        _addLogMessage('📁 [UPDATE] 最终文件大小: ${await selectedUpdateFile!.length()} 字节');
        setState(() {
          selectedUpdateFile = null;
          updateProgress = 0.0;
        });
        break;

      default:
        _addLogMessage('⚠️ 未知消息类型: 0x${msgType.toRadixString(16).padLeft(2, '0')}');
        break;
    }
  }

  // 调用AI图像识别
  Future<void> _callImageRecognition() async {
    if (receivedImageData == null) return;
    
    setState(() {
      isRecognizing = true;
      recognitionResult = '识别中...';
    });
    
    try {
      // 上传"正在识别"信息到设备端
      await _sendClientInfo("正在识别");
      
      //_addLogMessage('🤖 开始AI图像识别...');
      
      // 暂时屏蔽通义千问，只使用GPT-4o
      // final useQianwen = DateTime.now().millisecond % 2 == 0;
      
      // if (useQianwen) {
      //   _addLogMessage('🔍 使用通义千问API进行识别');
      //   await _callQianwenAPI();
      // } else {
        _addLogMessage('🔍 使用GPT-4o API进行识别');
        await _callGpt4oAPI();
      // }
      
    } catch (e) {
      _addLogMessage('❌ AI识别失败: $e');
      setState(() {
        recognitionResult = '识别失败: ${e.toString()}';
      });
    } finally {
      setState(() {
        isRecognizing = false;
      });
    }
  }

  // 添加发送客户端信息的方法
  Future<void> _sendClientInfo(String message) async {
    if (_socket == null) return;
    
    try {
      _addLogMessage('📤 发送客户端信息: $message');
      
      // 将消息转换为字节数组
      final messageBytes = utf8.encode(message);
      
      // 构建消息头：消息类型(1字节) + 数据长度(4字节，网络字节序)
      final header = Uint8List(5);
      header[0] = 0x20; // MSG_CLIENT_INFO
      header[1] = (messageBytes.length >> 24) & 0xFF;
      header[2] = (messageBytes.length >> 16) & 0xFF;
      header[3] = (messageBytes.length >> 8) & 0xFF;
      header[4] = messageBytes.length & 0xFF;
      
      // 发送消息
      _socket!.add(header);
      _socket!.add(messageBytes);
      await _socket!.flush();
      
      _addLogMessage('✅ 客户端信息发送成功');
    } catch (e) {
      _addLogMessage('❌ 发送客户端信息失败: $e');
    }
  }

  // 新增：加载已保存的文件
  Future<void> _loadSavedFiles() async {
    setState(() {
      isLoadingFiles = true;
    });

    try {
      List<SavedFile> files = [];
      
      // 加载Documents目录下的文件
      final documentsDir = await getApplicationDocumentsDirectory();
      final eyeglassDir = Directory('${documentsDir.path}/眼镜文件');
      
      if (await eyeglassDir.exists()) {
        final documentFiles = await eyeglassDir.list().toList();
        for (var file in documentFiles) {
          if (file is File) {
            final stat = await file.stat();
            final extension = path.extension(file.path).toLowerCase();
            String type = 'document';
            
            if (['.jpg', '.jpeg', '.png', '.gif'].contains(extension)) {
              type = 'image';
            } else if (['.mp4', '.avi', '.mov'].contains(extension)) {
              type = 'video';
            } else if (['.pcm', '.wav', '.mp3'].contains(extension)) {
              type = 'audio';
            }
            
            files.add(SavedFile(
              name: path.basename(file.path),
              path: file.path,
              type: type,
              dateCreated: stat.modified,
              size: stat.size,
            ));
          }
        }
      }
      
      // 按修改时间排序（最新的在前）
      files.sort((a, b) => b.dateCreated.compareTo(a.dateCreated));
      
      // 清理选中列表中已被删除的文件
      final currentFilePaths = files.map((f) => f.path).toSet();
      selectedFiles.removeWhere((path) => !currentFilePaths.contains(path));
      
      setState(() {
        savedFiles = files;
        isLoadingFiles = false;
      });
      
      _addLogMessage('📁 已加载 ${files.length} 个已保存文件');
    } catch (e) {
      _addLogMessage('❌ 加载已保存文件失败: $e');
      setState(() {
        isLoadingFiles = false;
      });
    }
  }

  // 新增：删除选中的文件
  Future<void> _deleteSelectedFiles() async {
    if (selectedFiles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先选择要删除的文件'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // 显示确认对话框
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除选中的 ${selectedFiles.length} 个文件吗？\n此操作不可恢复！'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      int successCount = 0;
      int failCount = 0;

      for (String filePath in selectedFiles) {
        try {
          final file = File(filePath);
          if (await file.exists()) {
            await file.delete();
            successCount++;
            _addLogMessage('🗑️ 已删除: ${file.path}');
          } else {
            failCount++;
            _addLogMessage('⚠️ 文件不存在: $filePath');
          }
        } catch (e) {
          failCount++;
          _addLogMessage('❌ 删除失败: $filePath, $e');
        }
      }

      // 清空选中列表
      setState(() {
        selectedFiles.clear();
      });

      // 刷新文件列表
      await _loadSavedFiles();

      // 显示结果
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('删除完成：成功 $successCount 个，失败 $failCount 个'),
          backgroundColor: failCount > 0 ? Colors.orange : Colors.green,
        ),
      );
    } catch (e) {
      _addLogMessage('❌ 删除文件失败: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('删除失败: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // 新增：分享文件（带同步检查）
  Future<void> _shareFile(SavedFile file) async {
    try {
      // 检查文件是否仍然存在
      final fileExists = await File(file.path).exists();
      if (!fileExists) {
        _addLogMessage('❌ 文件不存在，可能已被删除: ${file.name}');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('文件不存在: ${file.name}'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
      
      // 检查文件大小是否匹配（防止文件被截断）
      final currentSize = await File(file.path).length();
      if (currentSize != file.size) {
        _addLogMessage('⚠️ 文件大小不匹配，可能已被修改: ${file.name}');
      }
      
      await Share.shareXFiles([XFile(file.path)], text: '分享文件: ${file.name}');
      _addLogMessage('✅ 文件分享成功: ${file.name}');
    } catch (e) {
      _addLogMessage('❌ 分享文件失败: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('分享失败: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // 新增：构建文件预览卡片
  Widget _buildFilePreviewCard(SavedFile file) {
    IconData iconData;
    Color iconColor;
    
    switch (file.type) {
      case 'image':
        iconData = Icons.image;
        iconColor = Colors.blue;
        break;
      case 'video':
        iconData = Icons.videocam;
        iconColor = Colors.purple;
        break;
      case 'audio':
        iconData = Icons.audiotrack;
        iconColor = Colors.orange;
        break;
      default:
        iconData = Icons.description;
        iconColor = Colors.grey;
        break;
    }

    final isSelected = selectedFiles.contains(file.path);

    return Container(
      width: 100,
      margin: const EdgeInsets.only(right: 8),
      child: Card(
        elevation: 2,
        color: isSelected ? Colors.blue[50] : null,
        child: InkWell(
          onTap: () {
            setState(() {
              if (isSelected) {
                selectedFiles.remove(file.path);
              } else {
                selectedFiles.add(file.path);
              }
            });
          },
          onLongPress: () => _shareFile(file),
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      iconData,
                      color: iconColor,
                      size: 32,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      file.name,
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _formatFileSize(file.size),
                      style: TextStyle(
                        fontSize: 8,
                        color: Colors.grey[600],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _formatDate(file.dateCreated),
                      style: TextStyle(
                        fontSize: 8,
                        color: Colors.grey[500],
                      ),
                    ),
                  ],
                ),
              ),
              // 左上角的复选框
              Positioned(
                top: 4,
                left: 4,
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: isSelected ? Colors.blue : Colors.white,
                    border: Border.all(
                      color: isSelected ? Colors.blue : Colors.grey,
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: isSelected
                      ? const Icon(
                          Icons.check,
                          size: 14,
                          color: Colors.white,
                        )
                      : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 新增：格式化文件大小
  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }

  // 新增：格式化日期
  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final difference = now.difference(date);
    
    if (difference.inDays > 0) {
      return '${difference.inDays}天前';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}小时前';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}分钟前';
    } else {
      return '刚刚';
    }
  }

  // 调用通义千问API
  Future<void> _callQianwenAPI() async {
    if (receivedImageData == null) return;
    
    try {
      // 将图片转换为base64
      final base64Image = base64Encode(receivedImageData!);
      
      final requestData = {
        "model": "qwen-vl-max-latest",
        "input": {
          "messages": [
            {
              "role": "user",
              "content": [
                {"image": "data:image/jpeg;base64,$base64Image"},
                {"text": "10字内描述图片"}
              ]
            }
          ]
        }
      };
      
      final response = await http.post(
        Uri.parse(APIConfig.qianwenURL),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${APIConfig.qianwenKey}',
        },
        body: jsonEncode(requestData),
      );
      
      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);
        _addLogMessage('✅ 通义千问API响应: ${response.body}');
        
        // 解析响应
        String resultText = '';
        if (responseData['output'] != null && 
            responseData['output']['choices'] != null &&
            responseData['output']['choices'].isNotEmpty) {
          final choice = responseData['output']['choices'][0];
          if (choice['message'] != null && choice['message']['content'] != null) {
            final content = choice['message']['content'];
            if (content is List && content.isNotEmpty) {
              resultText = content[0]['text'] ?? content[0].toString();
            } else if (content is String) {
              resultText = content;
            }
          }
        }
        
        if (resultText.isEmpty) {
          resultText = '无法解析识别结果';
        }
        
        setState(() {
          recognitionResult = resultText;
        });
        
        _addLogMessage('📝 识别结果: $resultText');
        
        // 上传识别结果到设备端
        await _sendClientInfo("识别结果: $resultText");
        
        // 注释掉自动发送重新开始发图指令
        // await _sendImageREStart();
        
      } else {
        throw Exception('API请求失败: ${response.statusCode}');
      }
    } catch (e) {
      _addLogMessage('❌ 通义千问API调用失败: $e');
      rethrow;
    }
  }

  // 调用GPT-4o API
  Future<void> _callGpt4oAPI() async {
    if (receivedImageData == null) return;
    
    try {
      // 将图片转换为base64
      final base64Image = base64Encode(receivedImageData!);
      
      final requestData = {
        "model": "gpt-4o",
        "messages": [
          {
            "role": "user",
            "content": [
              {"type": "text", "text": "10字内描述图片"},
              {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,$base64Image"}}
            ]
          }
        ],
        "max_tokens": 300
      };
      
      final response = await http.post(
        Uri.parse(APIConfig.gpt4oURL),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${APIConfig.gpt4oKey}',
        },
        body: jsonEncode(requestData),
      );
      
      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);
        _addLogMessage('✅ GPT-4o API响应: ${response.body}');
        
        // 解析响应
        String resultText = '';
        if (responseData['choices'] != null && responseData['choices'].isNotEmpty) {
          final choice = responseData['choices'][0];
          if (choice['message'] != null && choice['message']['content'] != null) {
            resultText = choice['message']['content'];
          }
        }
        
        if (resultText.isEmpty) {
          resultText = '无法解析识别结果';
        }
        
        setState(() {
          recognitionResult = resultText;
        });
        
        _addLogMessage('📝 识别结果: $resultText');
        
        // 上传识别结果到设备端
        await _sendClientInfo("识别结果: $resultText");
        
        // 注释掉自动发送重新开始发图指令
        // await _sendImageREStart();
        
      } else {
        throw Exception('API请求失败: ${response.statusCode}');
      }
    } catch (e) {
      _addLogMessage('❌ GPT-4o API调用失败: $e');
      rethrow;
    }
  }

  Future<void> _sendAckMessage() async {
    if (_socket == null) return;
    
    try {
      _addLogMessage('📤 发送确认消息...');
      final header = Uint8List(5);
      header[0] = MessageType.imageAck;
      header[1] = 0; header[2] = 0; header[3] = 0; header[4] = 0;
      
      _socket!.add(header);
      await _socket!.flush();
      _addLogMessage('✅ 确认消息发送成功');
    } catch (e) {
      _addLogMessage('⚠️ 发送确认消息失败: $e');
    }
  }

  void _cleanupConnection() {
    _socketSubscription?.cancel();
    _socket?.close();
    _socket = null;
    _socketSubscription = null;
    
    setState(() {
      isReceiving = false;
    });
  }

  bool _isValidIp(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return false;
    for (String part in parts) {
      final num = int.tryParse(part);
      if (num == null || num < 0 || num > 255) return false;
    }
    return true;
  }

  // 修改：处理接收到的文件
  Future<void> _processReceivedFile() async {
    if (receivedImageData == null) return;
    
    if (receiveMode == 'album') {
      await _saveFileByType();
    } else {
      // 识图模式：尝试解码图片
      await _processReceivedImage();
    }
  }

  // 新增：根据文件类型保存文件
  Future<void> _saveFileByType() async {
    if (receivedImageData == null) return;
    
    try {
      final extension = currentFileExtension ?? '.unknown';
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = currentFileName ?? '眼镜_$timestamp$extension';
      
      _addLogMessage('📁 处理文件: $fileName, 类型: $extension');
      
      switch (extension) {
        case '.txt':
        case '.pcm':
          await _saveToDocuments(fileName);
          break;
        case '.h264':
          await _convertAndSaveVideo(fileName);
          break;
        case '.jpg':
        case '.jpeg':
        case '.png':
          await _saveImageToAlbum(fileName);
          break;
        default:
          // 默认保存到Documents
          await _saveToDocuments(fileName);
          break;
      }
    } catch (e) {
      _addLogMessage('❌ 文件处理失败: $e');
    }
  }

  // 新增：后台异步处理文件（不阻塞消息循环）
  void _processFileInBackground(String fileName, String extension, String tempFilePath) {
    // 使用 Future.microtask 确保在下一个事件循环中执行，不阻塞当前消息处理
    Future.microtask(() async {
      try {
        _addLogMessage('🔄 后台处理文件: $fileName, 类型: $extension');
        
        final tempFile = File(tempFilePath);
        if (!await tempFile.exists()) {
          _addLogMessage('❌ 临时文件不存在: $tempFilePath');
          return;
        }
        
        switch (extension) {
          case '.txt':
          case '.pcm':
            await _saveToDocumentsFromFile(fileName, tempFilePath);
            break;
          case '.h264':
            await _convertAndSaveVideoFromFile(fileName, tempFilePath);
            break;
          case '.jpg':
          case '.jpeg':
          case '.png':
            await _saveImageToAlbumFromFile(fileName, tempFilePath);
            break;
          default:
            // 默认保存到Documents
            await _saveToDocumentsFromFile(fileName, tempFilePath);
            break;
        }
        
        // 处理完成后删除临时文件
        try {
          if (await tempFile.exists()) {
            await tempFile.delete();
            _addLogMessage('🗑️ 临时文件已清理: $fileName');
          }
        } catch (e) {
          _addLogMessage('⚠️ 清理临时文件失败: $e');
        }
        
        _addLogMessage('✅ 文件处理完成: $fileName');
      } catch (e) {
        _addLogMessage('❌ 后台文件处理失败: $fileName, $e');
        // 即使失败也尝试清理临时文件
        try {
          final tempFile = File(tempFilePath);
          if (await tempFile.exists()) {
            await tempFile.delete();
          }
        } catch (_) {}
      }
    });
  }

  // 新增：从临时文件处理接收到的文件
  Future<void> _processReceivedFileFromTemp(String fileName, String extension) async {
    if (_currentTempFilePath == null) return;
    
    try {
      _addLogMessage('🔄 处理文件: $fileName, 类型: $extension');
      
      final tempFile = File(_currentTempFilePath!);
      if (!await tempFile.exists()) {
        _addLogMessage('❌ 临时文件不存在');
        return;
      }
      
      switch (extension) {
        case '.txt':
        case '.pcm':
          await _saveToDocumentsFromTemp(fileName);
          break;
        case '.h264':
          await _convertAndSaveVideoFromTemp(fileName);
          break;
        case '.jpg':
        case '.jpeg':
        case '.png':
          await _saveImageToAlbumFromTemp(fileName);
          break;
        default:
          // 默认保存到Documents
          await _saveToDocumentsFromTemp(fileName);
          break;
      }
    } catch (e) {
      _addLogMessage('❌ 文件处理失败: $e');
    }
  }

  // 新增：保存到Documents目录
  Future<void> _saveToDocuments(String fileName) async {
    try {
      // 获取Documents目录
      final documentsDir = await getApplicationDocumentsDirectory();
      final eyeglassDir = Directory('${documentsDir.path}/眼镜文件');
      
      // 创建目录（如果不存在）
      if (!await eyeglassDir.exists()) {
        await eyeglassDir.create(recursive: true);
      }
      
      // 保存文件
      final filePath = '${eyeglassDir.path}/$fileName';
      final file = File(filePath);
      await file.writeAsBytes(receivedImageData!);
      
      _addLogMessage('✅ 文件已保存到Documents: $fileName');
      _addLogMessage('📁 保存路径: $filePath');
      
      // 保存完成后刷新文件列表
      _loadSavedFiles();
      
    } catch (e) {
      _addLogMessage('❌ 保存到Documents失败: $e');
    }
  }

  // 新增：从指定文件路径保存到Documents目录
  Future<void> _saveToDocumentsFromFile(String fileName, String filePath) async {
    try {
      // 获取Documents目录
      final documentsDir = await getApplicationDocumentsDirectory();
      final eyeglassDir = Directory('${documentsDir.path}/眼镜文件');
      
      // 创建目录（如果不存在）
      if (!await eyeglassDir.exists()) {
        await eyeglassDir.create(recursive: true);
      }
      
      // 直接复制文件
      final targetPath = '${eyeglassDir.path}/$fileName';
      final sourceFile = File(filePath);
      await sourceFile.copy(targetPath);
      
      _addLogMessage('✅ 文件已保存到Documents: $fileName');
      _addLogMessage('📁 保存路径: $targetPath');
      
      // 保存完成后刷新文件列表
      _loadSavedFiles();
      
    } catch (e) {
      _addLogMessage('❌ 保存到Documents失败: $e');
    }
  }

  // 新增：从临时文件保存到Documents目录
  Future<void> _saveToDocumentsFromTemp(String fileName) async {
    try {
      // 获取Documents目录
      final documentsDir = await getApplicationDocumentsDirectory();
      final eyeglassDir = Directory('${documentsDir.path}/眼镜文件');
      
      // 创建目录（如果不存在）
      if (!await eyeglassDir.exists()) {
        await eyeglassDir.create(recursive: true);
      }
      
      // 直接复制临时文件
      final filePath = '${eyeglassDir.path}/$fileName';
      final tempFile = File(_currentTempFilePath!);
      await tempFile.copy(filePath);
      
      _addLogMessage('✅ 文件已保存到Documents: $fileName');
      _addLogMessage('📁 保存路径: $filePath');
      
      // 保存完成后刷新文件列表
      _loadSavedFiles();
      
    } catch (e) {
      _addLogMessage('❌ 保存到Documents失败: $e');
    }
  }

  // 修改：更稳健的H264处理流程（封装到MP4 + 写入旋转元数据，失败时轻量转码）
  Future<void> _convertAndSaveVideo(String fileName) async {
    try {
      // 检查相册权限
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final granted = await Gal.requestAccess();
        if (!granted) {
          _addLogMessage('❌ 需要相册权限才能保存视频');
          return;
        }
      }

      // 创建临时H264文件
      final tempDir = Directory.systemTemp;
      final h264File = File('${tempDir.path}/$fileName');
      await h264File.writeAsBytes(receivedImageData!);
      
      _addLogMessage('🎬 开始处理H264视频（封装到MP4后仅一次实际旋转）...');
      
      // 生成路径：中间MP4与最终旋转后的MP4
      final mp4FileName = fileName.replaceAll('.h264', '.mp4');
      final rotatedFileName = fileName.replaceAll('.h264', '_rotated.mp4');
      final mp4File = File('${tempDir.path}/$mp4FileName');
      final rotatedFile = File('${tempDir.path}/$rotatedFileName');
      
      // 第一步：仅封装（不转码），把H264裸流快速封装到MP4
      final muxCmd = '-f h264 -r 30 -i "${h264File.path}" -c:v copy -movflags +faststart -y "${mp4File.path}"';
      _addLogMessage('🔧 FFmpeg封装命令: $muxCmd');
      var session = await FFmpegKit.execute(muxCmd);
      var returnCode = await session.getReturnCode();
      if (!ReturnCode.isSuccess(returnCode)) {
        final logs = await session.getLogs();
        String errorMsg = '';
        for (var log in logs) {
          final message = await log.getMessage();
          errorMsg += message + '\n';
        }
        _addLogMessage('❌ MP4封装失败: $returnCode');
        _addLogMessage('❌ 错误信息: $errorMsg');
        throw Exception('封装失败');
      }

      // 第二步：进行一次轻量转码并实际旋转（仅一次旋转，避免双重旋转）
      final rotateTranscodeCmd = '-i "${mp4File.path}" '
          '-vf transpose=2,format=yuv420p '
          '-c:v libx264 -preset ultrafast -crf 23 -r 30 -threads 1 '
          '-movflags +faststart -y "${rotatedFile.path}"';
      _addLogMessage('🔧 FFmpeg旋转转码命令: $rotateTranscodeCmd');
      session = await FFmpegKit.execute(rotateTranscodeCmd);
      returnCode = await session.getReturnCode();
      if (!ReturnCode.isSuccess(returnCode) || !await rotatedFile.exists()) {
        final logs = await session.getLogs();
        String errorMsg = '';
        for (var log in logs) {
          final message = await log.getMessage();
          errorMsg += message + '\n';
        }
        _addLogMessage('❌ 旋转转码失败: $returnCode');
        _addLogMessage('❌ 错误信息: $errorMsg');
        throw Exception('旋转转码失败');
      }

      // 保存最终视频到Documents目录
      final documentsDir = await getApplicationDocumentsDirectory();
      final eyeglassDir = Directory('${documentsDir.path}/眼镜文件');
      
      // 创建目录（如果不存在）
      if (!await eyeglassDir.exists()) {
        await eyeglassDir.create(recursive: true);
      }
      
      if (await rotatedFile.exists()) {
        // 保存旋转后的视频到Documents
        final documentsFile = File('${eyeglassDir.path}/$rotatedFileName');
        await rotatedFile.copy(documentsFile.path);
        
        // 同时保存到系统相册
        try {
          final hasAccess = await Gal.hasAccess();
          if (hasAccess) {
            await Gal.putVideo(documentsFile.path);
            _addLogMessage('✅ H264视频已封装并旋转（90°）后保存到Documents和系统相册: $rotatedFileName');
          } else {
            _addLogMessage('✅ H264视频已封装并旋转（90°）后保存到Documents: $rotatedFileName');
          }
        } catch (e) {
          _addLogMessage('✅ H264视频已封装并旋转（90°）后保存到Documents: $rotatedFileName');
          _addLogMessage('⚠️ 保存到系统相册失败: $e');
        }
        
        final size = await documentsFile.length();
        _addLogMessage('📊 输出文件大小: ${(size / 1024 / 1024).toStringAsFixed(2)} MB');
      } else if (await mp4File.exists()) {
        // 极端情况下仍保存未旋转的mp4
        final documentsFile = File('${eyeglassDir.path}/$mp4FileName');
        await mp4File.copy(documentsFile.path);
        
        // 同时保存到系统相册
        try {
          final hasAccess = await Gal.hasAccess();
          if (hasAccess) {
            await Gal.putVideo(documentsFile.path);
            _addLogMessage('✅ H264视频已封装（未旋转）保存到Documents和系统相册: $mp4FileName');
          } else {
            _addLogMessage('✅ H264视频已封装（未旋转）保存到Documents: $mp4FileName');
          }
        } catch (e) {
          _addLogMessage('✅ H264视频已封装（未旋转）保存到Documents: $mp4FileName');
          _addLogMessage('⚠️ 保存到系统相册失败: $e');
        }
      } else {
        _addLogMessage('❌ 未找到可保存的视频文件');
      }

      // 清理临时文件
      try {
        if (await h264File.exists()) {
          await h264File.delete();
        }
        if (await mp4File.exists()) {
          await mp4File.delete();
        }
        if (await rotatedFile.exists()) {
          await rotatedFile.delete();
        }
      } catch (e) {
        _addLogMessage('⚠️ 清理临时文件失败: $e');
      }

      // 保存完成后刷新文件列表
      _loadSavedFiles();

    } catch (e) {
      _addLogMessage('❌ H264视频处理失败: $e');
    }
  }

  // 新增：从指定文件路径转换并保存H264视频
  Future<void> _convertAndSaveVideoFromFile(String fileName, String filePath) async {
    try {
      // 检查相册权限
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final granted = await Gal.requestAccess();
        if (!granted) {
          _addLogMessage('❌ 需要相册权限才能保存视频');
          return;
        }
      }

      // 直接使用提供的文件路径作为H264源文件
      final h264File = File(filePath);
      
      _addLogMessage('🎬 开始处理H264视频（封装到MP4后仅一次实际旋转）...');
      
      // 生成路径：中间MP4与最终旋转后的MP4
      final tempDir = Directory.systemTemp;
      final mp4FileName = fileName.replaceAll('.h264', '.mp4');
      final rotatedFileName = fileName.replaceAll('.h264', '_rotated.mp4');
      final mp4File = File('${tempDir.path}/$mp4FileName');
      final rotatedFile = File('${tempDir.path}/$rotatedFileName');
      
      // 第一步：仅封装（不转码），把H264裸流快速封装到MP4
      final muxCmd = '-f h264 -r 30 -i "${h264File.path}" -c:v copy -movflags +faststart -y "${mp4File.path}"';
      _addLogMessage('🔧 FFmpeg封装命令: $muxCmd');
      var session = await FFmpegKit.execute(muxCmd);
      var returnCode = await session.getReturnCode();
      if (!ReturnCode.isSuccess(returnCode)) {
        final logs = await session.getLogs();
        String errorMsg = '';
        for (var log in logs) {
          final message = await log.getMessage();
          errorMsg += message + '\n';
        }
        _addLogMessage('❌ MP4封装失败: $returnCode');
        _addLogMessage('❌ 错误信息: $errorMsg');
        throw Exception('封装失败');
      }

      // 第二步：进行一次轻量转码并实际旋转（仅一次旋转，避免双重旋转）
      final rotateTranscodeCmd = '-i "${mp4File.path}" '
          '-vf transpose=2,format=yuv420p '
          '-c:v libx264 -preset ultrafast -crf 23 -r 30 -threads 1 '
          '-movflags +faststart -y "${rotatedFile.path}"';
      _addLogMessage('🔧 FFmpeg旋转转码命令: $rotateTranscodeCmd');
      session = await FFmpegKit.execute(rotateTranscodeCmd);
      returnCode = await session.getReturnCode();
      if (!ReturnCode.isSuccess(returnCode) || !await rotatedFile.exists()) {
        final logs = await session.getLogs();
        String errorMsg = '';
        for (var log in logs) {
          final message = await log.getMessage();
          errorMsg += message + '\n';
        }
        _addLogMessage('❌ 旋转转码失败: $returnCode');
        _addLogMessage('❌ 错误信息: $errorMsg');
        throw Exception('旋转转码失败');
      }

      // 保存最终视频到Documents目录
      final documentsDir = await getApplicationDocumentsDirectory();
      final eyeglassDir = Directory('${documentsDir.path}/眼镜文件');
      
      // 创建目录（如果不存在）
      if (!await eyeglassDir.exists()) {
        await eyeglassDir.create(recursive: true);
      }
      
      if (await rotatedFile.exists()) {
        // 保存旋转后的视频到Documents
        final documentsFile = File('${eyeglassDir.path}/$rotatedFileName');
        await rotatedFile.copy(documentsFile.path);
        
        // 同时保存到系统相册
        try {
          final hasAccess = await Gal.hasAccess();
          if (hasAccess) {
            await Gal.putVideo(documentsFile.path);
            _addLogMessage('✅ H264视频已封装并旋转（90°）后保存到Documents和系统相册: $rotatedFileName');
          } else {
            _addLogMessage('✅ H264视频已封装并旋转（90°）后保存到Documents: $rotatedFileName');
          }
        } catch (e) {
          _addLogMessage('✅ H264视频已封装并旋转（90°）后保存到Documents: $rotatedFileName');
          _addLogMessage('⚠️ 保存到系统相册失败: $e');
        }
        
        final size = await documentsFile.length();
        _addLogMessage('📊 输出文件大小: ${(size / 1024 / 1024).toStringAsFixed(2)} MB');
      } else if (await mp4File.exists()) {
        // 极端情况下仍保存未旋转的mp4
        final documentsFile = File('${eyeglassDir.path}/$mp4FileName');
        await mp4File.copy(documentsFile.path);
        
        // 同时保存到系统相册
        try {
          final hasAccess = await Gal.hasAccess();
          if (hasAccess) {
            await Gal.putVideo(documentsFile.path);
            _addLogMessage('✅ H264视频已封装（未旋转）保存到Documents和系统相册: $mp4FileName');
          } else {
            _addLogMessage('✅ H264视频已封装（未旋转）保存到Documents: $mp4FileName');
          }
        } catch (e) {
          _addLogMessage('✅ H264视频已封装（未旋转）保存到Documents: $mp4FileName');
          _addLogMessage('⚠️ 保存到系统相册失败: $e');
        }
      } else {
        _addLogMessage('❌ 未找到可保存的视频文件');
      }

      // 清理临时文件
      try {
        if (await mp4File.exists()) {
          await mp4File.delete();
        }
        if (await rotatedFile.exists()) {
          await rotatedFile.delete();
        }
      } catch (e) {
        _addLogMessage('⚠️ 清理临时文件失败: $e');
      }

      // 保存完成后刷新文件列表
      _loadSavedFiles();

    } catch (e) {
      _addLogMessage('❌ H264视频处理失败: $e');
    }
  }

  // 新增：从临时文件转换并保存H264视频
  Future<void> _convertAndSaveVideoFromTemp(String fileName) async {
    try {
      // 检查相册权限
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final granted = await Gal.requestAccess();
        if (!granted) {
          _addLogMessage('❌ 需要相册权限才能保存视频');
          return;
        }
      }

      // 直接使用临时文件作为H264源文件
      final h264File = File(_currentTempFilePath!);
      
      _addLogMessage('🎬 开始处理H264视频（封装到MP4后仅一次实际旋转）...');
      
      // 生成路径：中间MP4与最终旋转后的MP4
      final tempDir = Directory.systemTemp;
      final mp4FileName = fileName.replaceAll('.h264', '.mp4');
      final rotatedFileName = fileName.replaceAll('.h264', '_rotated.mp4');
      final mp4File = File('${tempDir.path}/$mp4FileName');
      final rotatedFile = File('${tempDir.path}/$rotatedFileName');
      
      // 第一步：仅封装（不转码），把H264裸流快速封装到MP4
      final muxCmd = '-f h264 -r 30 -i "${h264File.path}" -c:v copy -movflags +faststart -y "${mp4File.path}"';
      _addLogMessage('🔧 FFmpeg封装命令: $muxCmd');
      var session = await FFmpegKit.execute(muxCmd);
      var returnCode = await session.getReturnCode();
      if (!ReturnCode.isSuccess(returnCode)) {
        final logs = await session.getLogs();
        String errorMsg = '';
        for (var log in logs) {
          final message = await log.getMessage();
          errorMsg += message + '\n';
        }
        _addLogMessage('❌ MP4封装失败: $returnCode');
        _addLogMessage('❌ 错误信息: $errorMsg');
        throw Exception('封装失败');
      }

      // 第二步：进行一次轻量转码并实际旋转（仅一次旋转，避免双重旋转）
      final rotateTranscodeCmd = '-i "${mp4File.path}" '
          '-vf transpose=2,format=yuv420p '
          '-c:v libx264 -preset ultrafast -crf 23 -r 30 -threads 1 '
          '-movflags +faststart -y "${rotatedFile.path}"';
      _addLogMessage('🔧 FFmpeg旋转转码命令: $rotateTranscodeCmd');
      session = await FFmpegKit.execute(rotateTranscodeCmd);
      returnCode = await session.getReturnCode();
      if (!ReturnCode.isSuccess(returnCode) || !await rotatedFile.exists()) {
        final logs = await session.getLogs();
        String errorMsg = '';
        for (var log in logs) {
          final message = await log.getMessage();
          errorMsg += message + '\n';
        }
        _addLogMessage('❌ 旋转转码失败: $returnCode');
        _addLogMessage('❌ 错误信息: $errorMsg');
        throw Exception('旋转转码失败');
      }

      // 保存最终视频到Documents目录
      final documentsDir = await getApplicationDocumentsDirectory();
      final eyeglassDir = Directory('${documentsDir.path}/眼镜文件');
      
      // 创建目录（如果不存在）
      if (!await eyeglassDir.exists()) {
        await eyeglassDir.create(recursive: true);
      }
      
      if (await rotatedFile.exists()) {
        // 保存旋转后的视频到Documents
        final documentsFile = File('${eyeglassDir.path}/$rotatedFileName');
        await rotatedFile.copy(documentsFile.path);
        
        // 同时保存到系统相册
        try {
          final hasAccess = await Gal.hasAccess();
          if (hasAccess) {
            await Gal.putVideo(documentsFile.path);
            _addLogMessage('✅ H264视频已封装并旋转（90°）后保存到Documents和系统相册: $rotatedFileName');
          } else {
            _addLogMessage('✅ H264视频已封装并旋转（90°）后保存到Documents: $rotatedFileName');
          }
        } catch (e) {
          _addLogMessage('✅ H264视频已封装并旋转（90°）后保存到Documents: $rotatedFileName');
          _addLogMessage('⚠️ 保存到系统相册失败: $e');
        }
        
        final size = await documentsFile.length();
        _addLogMessage('📊 输出文件大小: ${(size / 1024 / 1024).toStringAsFixed(2)} MB');
      } else if (await mp4File.exists()) {
        // 极端情况下仍保存未旋转的mp4
        final documentsFile = File('${eyeglassDir.path}/$mp4FileName');
        await mp4File.copy(documentsFile.path);
        
        // 同时保存到系统相册
        try {
          final hasAccess = await Gal.hasAccess();
          if (hasAccess) {
            await Gal.putVideo(documentsFile.path);
            _addLogMessage('✅ H264视频已封装（未旋转）保存到Documents和系统相册: $mp4FileName');
          } else {
            _addLogMessage('✅ H264视频已封装（未旋转）保存到Documents: $mp4FileName');
          }
        } catch (e) {
          _addLogMessage('✅ H264视频已封装（未旋转）保存到Documents: $mp4FileName');
          _addLogMessage('⚠️ 保存到系统相册失败: $e');
        }
      } else {
        _addLogMessage('❌ 未找到可保存的视频文件');
      }

      // 清理临时文件（不删除h264源文件，因为它就是_currentTempFilePath）
      try {
        if (await mp4File.exists()) {
          await mp4File.delete();
        }
        if (await rotatedFile.exists()) {
          await rotatedFile.delete();
        }
      } catch (e) {
        _addLogMessage('⚠️ 清理临时文件失败: $e');
      }

      // 保存完成后刷新文件列表
      _loadSavedFiles();

    } catch (e) {
      _addLogMessage('❌ H264视频处理失败: $e');
    }
  }

  // 修改：保存图片到Documents目录（对JPG图片进行顺时针旋转90度）
  Future<void> _saveImageToAlbum(String fileName) async {
    try {
      // 获取Documents目录
      final documentsDir = await getApplicationDocumentsDirectory();
      final eyeglassDir = Directory('${documentsDir.path}/眼镜文件');
      
      // 创建目录（如果不存在）
      if (!await eyeglassDir.exists()) {
        await eyeglassDir.create(recursive: true);
      }
      
      // 创建临时文件用于处理
      final tempDir = Directory.systemTemp;
      final tempFile = File('${tempDir.path}/$fileName');
      await tempFile.writeAsBytes(receivedImageData!);
      
      String finalFileName = fileName;
      
      // 检查是否为JPG图片，如果是则进行顺时针旋转90度
      if (fileName.toLowerCase().endsWith('.jpg') || fileName.toLowerCase().endsWith('.jpeg')) {
        finalFileName = await _rotateJpgImageClockwise(tempFile, fileName);
      }
      
      // 保存到Documents目录
      final documentsFile = File('${eyeglassDir.path}/$finalFileName');
      if (finalFileName != fileName) {
        // 如果文件名改变了（旋转后），使用旋转后的文件
        final rotatedFile = File('${tempFile.parent.path}/${finalFileName}');
        if (await rotatedFile.exists()) {
          await rotatedFile.copy(documentsFile.path);
          await rotatedFile.delete(); // 删除临时旋转文件
        } else {
          await tempFile.copy(documentsFile.path);
        }
      } else {
        await tempFile.copy(documentsFile.path);
      }
      
      // 同时保存到系统相册（用于用户查看）
      try {
        final hasAccess = await Gal.hasAccess();
        if (hasAccess) {
          await Gal.putImage(documentsFile.path);
          _addLogMessage('✅ 图片已保存到Documents和系统相册: $finalFileName');
        } else {
          _addLogMessage('✅ 图片已保存到Documents: $finalFileName');
        }
      } catch (e) {
        _addLogMessage('✅ 图片已保存到Documents: $finalFileName');
        _addLogMessage('⚠️ 保存到系统相册失败: $e');
      }
      
      // 删除临时文件
      await tempFile.delete();
      
      // 保存完成后刷新文件列表
      _loadSavedFiles();
      
    } catch (e) {
      _addLogMessage('❌ 保存图片失败: $e');
    }
  }

  // 新增：从指定文件路径保存图片到Documents目录（对JPG图片进行顺时针旋转90度）
  Future<void> _saveImageToAlbumFromFile(String fileName, String filePath) async {
    try {
      // 获取Documents目录
      final documentsDir = await getApplicationDocumentsDirectory();
      final eyeglassDir = Directory('${documentsDir.path}/眼镜文件');
      
      // 创建目录（如果不存在）
      if (!await eyeglassDir.exists()) {
        await eyeglassDir.create(recursive: true);
      }
      
      // 使用提供的文件路径
      final tempFile = File(filePath);
      
      String finalFileName = fileName;
      
      // 检查是否为JPG图片，如果是则进行顺时针旋转90度
      if (fileName.toLowerCase().endsWith('.jpg') || fileName.toLowerCase().endsWith('.jpeg')) {
        finalFileName = await _rotateJpgImageClockwise(tempFile, fileName);
      }
      
      // 保存到Documents目录
      final documentsFile = File('${eyeglassDir.path}/$finalFileName');
      if (finalFileName != fileName) {
        // 如果文件名改变了（旋转后），使用旋转后的文件
        final rotatedFile = File('${tempFile.parent.path}/$finalFileName');
        if (await rotatedFile.exists()) {
          await rotatedFile.copy(documentsFile.path);
          await rotatedFile.delete(); // 删除临时旋转文件
        } else {
          await tempFile.copy(documentsFile.path);
        }
      } else {
        await tempFile.copy(documentsFile.path);
      }
      
      // 同时保存到系统相册（用于用户查看）
      try {
        final hasAccess = await Gal.hasAccess();
        if (hasAccess) {
          await Gal.putImage(documentsFile.path);
          _addLogMessage('✅ 图片已保存到Documents和系统相册: $finalFileName');
        } else {
          _addLogMessage('✅ 图片已保存到Documents: $finalFileName');
        }
      } catch (e) {
        _addLogMessage('✅ 图片已保存到Documents: $finalFileName');
        _addLogMessage('⚠️ 保存到系统相册失败: $e');
      }
      
      // 保存完成后刷新文件列表
      _loadSavedFiles();
      
    } catch (e) {
      _addLogMessage('❌ 保存图片失败: $e');
    }
  }

  // 新增：从临时文件保存图片到Documents目录（对JPG图片进行顺时针旋转90度）
  Future<void> _saveImageToAlbumFromTemp(String fileName) async {
    try {
      // 获取Documents目录
      final documentsDir = await getApplicationDocumentsDirectory();
      final eyeglassDir = Directory('${documentsDir.path}/眼镜文件');
      
      // 创建目录（如果不存在）
      if (!await eyeglassDir.exists()) {
        await eyeglassDir.create(recursive: true);
      }
      
      // 使用临时文件
      final tempFile = File(_currentTempFilePath!);
      
      String finalFileName = fileName;
      
      // 检查是否为JPG图片，如果是则进行顺时针旋转90度
      if (fileName.toLowerCase().endsWith('.jpg') || fileName.toLowerCase().endsWith('.jpeg')) {
        finalFileName = await _rotateJpgImageClockwise(tempFile, fileName);
      }
      
      // 保存到Documents目录
      final documentsFile = File('${eyeglassDir.path}/$finalFileName');
      if (finalFileName != fileName) {
        // 如果文件名改变了（旋转后），使用旋转后的文件
        final rotatedFile = File('${tempFile.parent.path}/$finalFileName');
        if (await rotatedFile.exists()) {
          await rotatedFile.copy(documentsFile.path);
          await rotatedFile.delete(); // 删除临时旋转文件
        } else {
          await tempFile.copy(documentsFile.path);
        }
      } else {
        await tempFile.copy(documentsFile.path);
      }
      
      // 同时保存到系统相册（用于用户查看）
      try {
        final hasAccess = await Gal.hasAccess();
        if (hasAccess) {
          await Gal.putImage(documentsFile.path);
          _addLogMessage('✅ 图片已保存到Documents和系统相册: $finalFileName');
        } else {
          _addLogMessage('✅ 图片已保存到Documents: $finalFileName');
        }
      } catch (e) {
        _addLogMessage('✅ 图片已保存到Documents: $finalFileName');
        _addLogMessage('⚠️ 保存到系统相册失败: $e');
      }
      
      // 保存完成后刷新文件列表
      _loadSavedFiles();
      
    } catch (e) {
      _addLogMessage('❌ 保存图片失败: $e');
    }
  }

  // 新增：使用FFmpeg对JPG图片进行顺时针旋转90度
  Future<String> _rotateJpgImageClockwise(File inputFile, String fileName) async {
    try {
      _addLogMessage('🖼️ 开始旋转JPG图片（顺时针旋转90度）...');
      
      // 生成旋转后的文件名
      final rotatedFileName = fileName.replaceAll(RegExp(r'\.(jpg|jpeg)$', caseSensitive: false), '_rotated.jpg');
      final rotatedFile = File('${inputFile.parent.path}/$rotatedFileName');
      
      // 构建FFmpeg命令
      // -i: 输入文件
      // -vf transpose=1: 顺时针旋转90度
      // -q:v 2: 设置高质量输出
      // -y: 覆盖输出文件
      final ffmpegCommand = '-i "${inputFile.path}" -vf transpose=1 -q:v 2 -y "${rotatedFile.path}"';
      
      _addLogMessage('🔧 FFmpeg命令: $ffmpegCommand');
      
      // 执行FFmpeg转换
      final session = await FFmpegKit.execute(ffmpegCommand);
      final returnCode = await session.getReturnCode();
      
      if (ReturnCode.isSuccess(returnCode)) {
        // 转换成功，检查输出文件是否存在
        if (await rotatedFile.exists()) {
          _addLogMessage('✅ JPG图片已顺时针旋转90度: $rotatedFileName');
          
          // 获取文件大小信息
          final rotatedSize = await rotatedFile.length();
          _addLogMessage('📊 旋转后文件大小: ${(rotatedSize / 1024).toStringAsFixed(1)} KB');
          
          return rotatedFileName;
        } else {
          _addLogMessage('❌ FFmpeg旋转完成但输出文件不存在');
          return fileName; // 返回原文件名
        }
      } else {
        // 转换失败，获取错误信息
        final logs = await session.getLogs();
        String errorMsg = '';
        for (var log in logs) {
          final message = await log.getMessage();
          errorMsg += message + '\n';
        }
        _addLogMessage('❌ FFmpeg旋转失败，返回码: $returnCode');
        _addLogMessage('❌ 错误信息: $errorMsg');
        return fileName; // 返回原文件名
      }
      
    } catch (e) {
      _addLogMessage('❌ JPG图片旋转失败: $e');
      return fileName; // 返回原文件名
    }
  }


  // 保留原有的图片解码逻辑（用于识图模式）
  Future<void> _processReceivedImage() async {
    if (receivedImageData == null) return;
    
    try {
      final codec = await ui.instantiateImageCodec(receivedImageData!);
      final frame = await codec.getNextFrame();
      setState(() {
        displayImage = frame.image;
        isImageReceived = true;
      });
      _addLogMessage('✅ 图片解码成功');
    } catch (e) {
      _addLogMessage('❌ 图片解码失败: $e');
    }
  }

  // 删除原有的_saveToAlbum方法，因为已经拆分为不同的保存方法

  // 新增：发送重新开始发图指令的方法
  Future<void> _sendImageREStart() async {
    if (_socket == null) return;
    
    try {
      _addLogMessage('📤 发送重新开始发图指令...');
      
      // 构建消息头：消息类型(1字节) + 数据长度(4字节，网络字节序)
      final header = Uint8List(5);
      header[0] = MessageType.imageREStart; // 0x22
      header[1] = 0; header[2] = 0; header[3] = 0; header[4] = 0; // 无数据
      
      // 发送消息
      _socket!.add(header);
      await _socket!.flush();
      
      _addLogMessage('✅ 重新开始发图指令发送成功');
    } catch (e) {
      _addLogMessage('❌ 发送重新开始发图指令失败: $e');
    }
  }

  // 新增：发送请求消息
  Future<void> _sendRequestMessage(int messageType) async {
    if (_socket == null) return;
    
    try {
      // 构建消息头：消息类型(1字节) + 数据长度(4字节，网络字节序)
      final header = Uint8List(5);
      header[0] = messageType;
      header[1] = 0; header[2] = 0; header[3] = 0; header[4] = 0; // 无数据
      
      // 发送消息
      _socket!.add(header);
      await _socket!.flush();
      
      _addLogMessage('✅ 请求消息发送成功');
    } catch (e) {
      _addLogMessage('❌ 发送请求消息失败: $e');
    }
  }

  // 新增：连接后发送清空相册请求
  Future<void> _cleanAlbum() async {
    if (isReceiving || isUpdating) return;
    
    final inputIp = _ipController.text.trim();
    if (inputIp.isEmpty || !_isValidIp(inputIp)) {
      _addLogMessage('❌ 请输入有效的IP地址');
      return;
    }
    
    setState(() {
      isReceiving = true;
      statusMessage = '正在连接设备清空相册...';
      logMessages.clear();
      // 清空模式不进入接收流程，不设置 receiveMode
      recognitionResult = '';
      _dataBuffer.clear();
      totalImages = 0;
      receivedImages = 0;
      isAlbumSync = false;
      currentFileName = null;
      currentFileExtension = null;
    });
    
    try {
      await _connectAndSetupSocket(inputIp);
      _addLogMessage('✅ 连接和监听器设置完成');
      await _sendRequestMessage(MessageType.albumClean);
      _addLogMessage('🧹 已发送清空相册请求 (0x27)');
      setState(() {
        statusMessage = '清空相册请求已发送';
      });
    } catch (e) {
      _addLogMessage('❌ 连接失败: $e');
      setState(() {
        statusMessage = '连接失败: $e';
      });
    } finally {
      setState(() {
        isReceiving = false;
      });
    }
  }

  // 新增：选择更新文件
  Future<void> _pickUpdateFile() async {
    try {
      // 请求存储权限
      final storageStatus = await Permission.storage.request();
      final photosStatus = await Permission.photos.request();
      
      if (storageStatus != PermissionStatus.granted && 
          photosStatus != PermissionStatus.granted) {
        _addLogMessage('⚠️ 需要存储权限才能访问文件');
        return;
      }
      
      // 使用file_picker选择文件，不限制文件格式
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.any, // 改为any，允许选择任何文件类型
        allowMultiple: false,
      );
      
      if (result != null && result.files.single.path != null) {
        setState(() {
          selectedUpdateFile = File(result.files.single.path!);
        });
        
        _addLogMessage('✅ 已选择更新文件: ${path.basename(selectedUpdateFile!.path)}');
      }
    } catch (e) {
      _addLogMessage('❌ 选择文件失败: $e');
    }
  }

  // 新增：发送系统更新文件
  Future<void> _sendUpdateFile() async {
    if (selectedUpdateFile == null) {
      _addLogMessage('❌ 请先选择更新文件');
      return;
    }

    setState(() {
      isUpdating = true;
      updateProgress = 0.0;
    });

    try {
      // 建立系统更新专用的socket连接
      final inputIp = _ipController.text.trim();
      if (inputIp.isEmpty || !_isValidIp(inputIp)) {
        _addLogMessage('❌ 请输入有效的IP地址');
        return;
      }

      _addLogMessage('🔗 正在连接设备进行系统更新: $inputIp:8080');
      
      // 创建新的socket连接用于系统更新
      final updateSocket = await Socket.connect(inputIp, 8080, timeout: Duration(seconds: 10));
      _addLogMessage('✅ 系统更新连接成功');

      try {
        // 读取文件数据
        final fileBytes = await selectedUpdateFile!.readAsBytes();
        final fileName = path.basename(selectedUpdateFile!.path);
        final fileSize = fileBytes.length;
        
        _addLogMessage('📁 [UPDATE] 开始发送更新文件: $fileName, 大小: $fileSize 字节');
        
        // 发送更新开始消息（格式：文件名:文件大小）
        final startMessage = '$fileName:$fileSize';
        await _sendUpdateMessageToSocket(updateSocket, MessageType.updateStart, utf8.encode(startMessage));
        
        // 分块发送文件数据
        const int chunkSize = 4096; // 与C代码保持一致
        int sentBytes = 0;
        
        for (int i = 0; i < fileBytes.length; i += chunkSize) {
          if (!isUpdating) break; // 检查是否被取消
          
          int currentChunkSize = (i + chunkSize > fileBytes.length) 
              ? fileBytes.length - i 
              : chunkSize;
          
          Uint8List chunk = fileBytes.sublist(i, i + currentChunkSize);
          await _sendUpdateMessageToSocket(updateSocket, MessageType.updateData, chunk);
          
          sentBytes += currentChunkSize;
          double progress = sentBytes / fileSize;
          
          setState(() {
            updateProgress = progress;
          });
          
          // 打印进度
          if (sentBytes % (chunkSize * 10) == 0 || sentBytes == fileSize) {
            _addLogMessage('📊 [UPDATE] 发送进度: ${(progress * 100).toStringAsFixed(1)}% ($sentBytes/$fileSize 字节)');
          }
          
          // 添加小延迟避免发送过快
          await Future.delayed(const Duration(milliseconds: 10));
        }
        
        // 发送更新结束消息
        await _sendUpdateMessageToSocket(updateSocket, MessageType.updateEnd, Uint8List(0));
        
        _addLogMessage('✅ 系统更新文件发送成功: $fileName');
        
        setState(() {
          selectedUpdateFile = null;
          updateProgress = 0.0;
        });
      } finally {
        // 关闭系统更新socket连接
        updateSocket.close();
        _addLogMessage('🔌 系统更新连接已关闭');
      }
    } catch (e) {
      _addLogMessage('❌ 系统更新发送失败: $e');
    } finally {
      setState(() {
        isUpdating = false;
      });
    }
  }

  // 新增：发送更新消息到指定socket的辅助方法
  Future<void> _sendUpdateMessageToSocket(Socket socket, int messageType, Uint8List data) async {
    try {
      // 构建消息：消息类型(1字节) + 数据长度(4字节) + 数据
      Uint8List message = Uint8List(5 + data.length);
      
      // 消息类型
      message[0] = messageType;
      
      // 数据长度（大端序）
      int dataLength = data.length;
      message[1] = (dataLength >> 24) & 0xFF;
      message[2] = (dataLength >> 16) & 0xFF;
      message[3] = (dataLength >> 8) & 0xFF;
      message[4] = dataLength & 0xFF;
      
      // 数据内容
      message.setRange(5, 5 + data.length, data);
      
      socket.add(message);
      await socket.flush();
    } catch (e) {
      throw Exception('发送更新消息失败: $e');
    }
  }

  // 修改：保存到相册
  Future<void> _saveToAlbum() async {
    if (receivedImageData == null) return;
    
    try {
      // 检查相册权限
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final granted = await Gal.requestAccess();
        if (!granted) {
          _addLogMessage('❌ 需要相册权限才能保存图片');
          return;
        }
      }

      // 创建临时文件
      final tempDir = Directory.systemTemp;
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = '眼镜_$timestamp.jpg';
      final tempFile = File('${tempDir.path}/$fileName');
      
      // 写入临时文件
      await tempFile.writeAsBytes(receivedImageData!);
      
      // 使用gal保存到相册
      await Gal.putImage(tempFile.path);
      
      // 删除临时文件
      await tempFile.delete();
      
      _addLogMessage('✅ 图片已保存到系统相册: $fileName');
      
    } catch (e) {
      _addLogMessage('❌ 保存到相册失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SingleChildScrollView(
        child: Column(
          children: [
            // IP输入区域
            Container(
              width: double.infinity,
              margin: const EdgeInsets.all(16),
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
                      Icon(Icons.computer, color: Colors.blue[800]),
                      const SizedBox(width: 8),
                      Text(
                        '设备IP地址',
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
                    controller: _ipController,
                    enabled: !isReceiving && !isUpdating,
                    decoration: InputDecoration(
                      labelText: '请输入设备IP地址',
                      hintText: '例如: 192.168.199.198',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      prefixIcon: Icon(Icons.lan, color: Colors.blue[600]),
                      suffixIcon: IconButton(
                        icon: Icon(Icons.clear, color: Colors.grey[600]),
                        onPressed: (isReceiving || isUpdating) ? null : () {
                          _ipController.clear();
                        },
                      ),
                    ),
                    keyboardType: TextInputType.numberWithOptions(decimal: true),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '格式: 192.168.x.x (例如: 192.168.199.198)',
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),

            // 修改：系统更新区域 - 添加折叠功能
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              decoration: BoxDecoration(
                color: Colors.orange[50],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange, width: 1),
              ),
              child: Column(
                children: [
                  // 标题栏 - 可点击展开/折叠
                  InkWell(
                    onTap: () {
                      setState(() {
                        isUpdateExpanded = !isUpdateExpanded;
                      });
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Icon(Icons.system_update, color: Colors.orange[800]),
                          const SizedBox(width: 8),
                          Text(
                            '系统更新',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.orange[800],
                            ),
                          ),
                          const Spacer(),
                          Icon(
                            isUpdateExpanded ? Icons.expand_less : Icons.expand_more,
                            color: Colors.orange[800],
                          ),
                        ],
                      ),
                    ),
                  ),
                  
                  // 可折叠内容
                  if (isUpdateExpanded) ...[
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 文件选择按钮
                          SizedBox(
                            width: double.infinity,
                            height: 48,
                            child: OutlinedButton.icon(
                              onPressed: _pickUpdateFile,
                              icon: const Icon(Icons.folder_open),
                              label: const Text('选择更新文件'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.orange[700],
                                side: BorderSide(color: Colors.orange[300]!),
                              ),
                            ),
                          ),

                          const SizedBox(height: 16),

                          // 文件信息显示
                          if (selectedUpdateFile != null) ...[
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
                                    '选中文件:',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Colors.grey[700],
                                      fontSize: 12,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    path.basename(selectedUpdateFile!.path),
                                    style: TextStyle(
                                      color: Colors.grey[600],
                                      fontSize: 14,
                                    ),
                                  ),
                                  FutureBuilder<int>(
                                    future: selectedUpdateFile!.length(),
                                    builder: (context, snapshot) {
                                      if (snapshot.hasData) {
                                        final sizeInMB = (snapshot.data! / (1024 * 1024)).toStringAsFixed(2);
                                        return Text(
                                          '文件大小: ${sizeInMB} MB',
                                          style: TextStyle(
                                            color: Colors.grey[600],
                                            fontSize: 12,
                                          ),
                                        );
                                      }
                                      return const SizedBox.shrink();
                                    },
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),
                          ],

                          // 进度条
                          if (isUpdating) ...[
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '发送进度: ${(updateProgress * 100).toStringAsFixed(1)}%',
                                  style: TextStyle(
                                    color: Colors.orange[700],
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                LinearProgressIndicator(
                                  value: updateProgress,
                                  backgroundColor: Colors.orange[100],
                                  valueColor: AlwaysStoppedAnimation<Color>(Colors.orange[600]!),
                                ),
                                const SizedBox(height: 16),
                              ],
                            ),
                          ],

                          // 发送按钮
                          SizedBox(
                            width: double.infinity,
                            height: 48,
                            child: ElevatedButton.icon(
                              onPressed: (isUpdating || selectedUpdateFile == null) ? null : _sendUpdateFile,
                              icon: isUpdating 
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : const Icon(Icons.upload),
                              label: Text(isUpdating ? '发送中...' : '发送更新文件'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.orange[600],
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
                                  '支持的文件格式:',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.grey[700],
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '任意文件格式',
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    color: Colors.grey[600],
                                    fontSize: 11,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '消息类型:',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.grey[700],
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'MSG_UPDATE_START (0x30)',
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    color: Colors.grey[600],
                                    fontSize: 11,
                                  ),
                                ),
                                Text(
                                  'MSG_UPDATE_DATA (0x31)',
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    color: Colors.grey[600],
                                    fontSize: 11,
                                  ),
                                ),
                                Text(
                                  'MSG_UPDATE_END (0x32)',
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
                ],
              ),
            ),

            // 状态卡片
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isReceiving ? Colors.blue[50] : Colors.green[50],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isReceiving ? Colors.blue : Colors.green,
                  width: 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        isReceiving ? Icons.sync : Icons.check_circle,
                        color: isReceiving ? Colors.blue : Colors.green,
                        size: 24,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          statusMessage,
                          style: TextStyle(
                            color: isReceiving ? Colors.blue[800] : Colors.green[800],
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (totalReceivedBytes > 0) ...[
                    const SizedBox(height: 8),
                    Text(
                      '已接收: ${(totalReceivedBytes / 1024).toStringAsFixed(1)} KB ($totalReceivedBytes 字节)',
                      style: TextStyle(
                        color: Colors.grey[700],
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      '数据块: $chunkCount 个',
                      style: TextStyle(
                        color: Colors.grey[600],
                        fontSize: 12,
                      ),
                    ),
                    if (receiveMode.isNotEmpty) ...[
                      Text(
                        '模式: ${receiveMode == 'recognize' ? '识图模式' : '相册模式'}',
                        style: TextStyle(
                          color: Colors.grey[600],
                          fontSize: 12,
                        ),
                      ),
                    ],
                    if (isAlbumSync && totalImages > 0) ...[
                      Text(
                        '相册同步进度: $receivedImages/$totalImages',
                        style: TextStyle(
                          color: Colors.orange[700],
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),

            // 图片显示区域
            if (isImageReceived && displayImage != null)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
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
                          '接收到的图片',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.purple[800],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Center(
                      child: Container(
                        constraints: BoxConstraints(
                          maxWidth: 300,
                          maxHeight: 300,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey[300]!),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: RawImage(
                            image: displayImage,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '图片大小: ${(totalReceivedBytes / 1024).toStringAsFixed(1)} KB',
                      style: TextStyle(
                        color: Colors.grey[600],
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),

            // AI识别结果区域
            if (recognitionResult.isNotEmpty)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.orange[50],
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.orange, width: 1),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.psychology, color: Colors.orange[800]),
                        const SizedBox(width: 8),
                        Text(
                          'AI识别结果',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.orange[800],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      recognitionResult,
                      style: TextStyle(
                        color: Colors.grey[700],
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),

            // 控制按钮 - 三个按钮：识图 / 相册 / 清空相册
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  // 识图按钮
                  Expanded(
                    child: SizedBox(
                      height: 50,
                      child: ElevatedButton.icon(
                        onPressed: (isReceiving || isUpdating) ? null : () => _startReceiving('recognize'),
                        icon: isReceiving && receiveMode == 'recognize'
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.psychology),
                        label: Text(
                          isReceiving && receiveMode == 'recognize' ? '识图中...' : '识图',
                          style: const TextStyle(fontSize: 16),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: (isReceiving || isUpdating) ? Colors.grey : Colors.blue,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 相册按钮
                  Expanded(
                    child: SizedBox(
                      height: 50,
                      child: ElevatedButton.icon(
                        onPressed: (isReceiving || isUpdating) ? null : () => _startReceiving('album'),
                        icon: isReceiving && receiveMode == 'album'
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.photo_library),
                        label: Text(
                          isReceiving && receiveMode == 'album' ? '保存中...' : '相册',
                          style: const TextStyle(fontSize: 16),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: (isReceiving || isUpdating) ? Colors.grey : Colors.purple,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 清空相册按钮
                  Expanded(
                    child: SizedBox(
                      height: 50,
                      child: ElevatedButton.icon(
                        onPressed: (isReceiving || isUpdating) ? null : _cleanAlbum,
                        icon: const Icon(Icons.delete_sweep),
                        label: const Text(
                          '清空相册',
                          style: TextStyle(fontSize: 16),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: (isReceiving || isUpdating) ? Colors.grey : Colors.red,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // 日志区域 - 修改这部分
            Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey[300]!),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.list_alt, color: Colors.grey[700], size: 20),
                      const SizedBox(width: 8),
                      Text(
                        '接收日志',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.grey[700],
                          fontSize: 16,
                        ),
                      ),
                      const Spacer(),
                      if (logMessages.isNotEmpty)
                        TextButton.icon(
                          onPressed: () {
                            setState(() {
                              logMessages.clear();
                            });
                          },
                          icon: const Icon(Icons.clear, size: 16),
                          label: const Text('清空'),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.grey[600],
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // 设置固定高度的日志区域
                  SizedBox(
                    height: 300, // 固定高度，可以滚动
                    child: logMessages.isEmpty
                        ? Center(
                            child: Text(
                              '暂无日志信息',
                              style: TextStyle(
                                color: Colors.grey[500],
                                fontSize: 14,
                              ),
                            ),
                          )
                        : ListView.builder(
                            itemCount: logMessages.length,
                            itemBuilder: (context, index) {
                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: 2),
                                child: Text(
                                  logMessages[index],
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                    color: Colors.grey[700],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),

            // 新增：已保存文件预览区域
            Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.green[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.green[300]!),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.folder_open, color: Colors.green[700], size: 20),
                      const SizedBox(width: 8),
                      Text(
                        '已保存文件',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.green[700],
                          fontSize: 16,
                        ),
                      ),
                      if (selectedFiles.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Text(
                          '(已选 ${selectedFiles.length})',
                          style: TextStyle(
                            color: Colors.blue[700],
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                      const Spacer(),
                      // 当有选中文件时，显示全选和删除按钮
                      if (selectedFiles.isNotEmpty) ...[
                        TextButton.icon(
                          onPressed: () {
                            setState(() {
                              if (selectedFiles.length == savedFiles.length) {
                                // 全部已选中，取消全选
                                selectedFiles.clear();
                              } else {
                                // 全选
                                selectedFiles = savedFiles.map((f) => f.path).toSet();
                              }
                            });
                          },
                          icon: Icon(
                            selectedFiles.length == savedFiles.length
                                ? Icons.check_box
                                : Icons.check_box_outline_blank,
                            size: 16,
                          ),
                          label: Text(selectedFiles.length == savedFiles.length ? '取消全选' : '全选'),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.blue[600],
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _deleteSelectedFiles,
                          icon: const Icon(Icons.delete, size: 16),
                          label: const Text('删除'),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.red[600],
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                        ),
                      ],
                      // 当没有选中文件时，显示全选和刷新按钮
                      if (selectedFiles.isEmpty && savedFiles.isNotEmpty)
                        TextButton.icon(
                          onPressed: () {
                            setState(() {
                              selectedFiles = savedFiles.map((f) => f.path).toSet();
                            });
                          },
                          icon: const Icon(Icons.check_box_outline_blank, size: 16),
                          label: const Text('全选'),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.blue[600],
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                        ),
                      if (selectedFiles.isEmpty)
                        TextButton.icon(
                          onPressed: _loadSavedFiles,
                          icon: const Icon(Icons.refresh, size: 16),
                          label: const Text('刷新'),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.green[600],
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (isLoadingFiles)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(20),
                        child: CircularProgressIndicator(),
                      ),
                    )
                  else if (savedFiles.isEmpty)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(
                          '暂无已保存文件',
                          style: TextStyle(
                            color: Colors.grey[500],
                            fontSize: 14,
                          ),
                        ),
                      ),
                    )
                  else
                    SizedBox(
                      height: 120, // 固定高度，可以滚动
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: savedFiles.length,
                        itemBuilder: (context, index) {
                          final file = savedFiles[index];
                          return _buildFilePreviewCard(file);
                        },
                      ),
                    ),
                ],
              ),
            ),

            const SizedBox(height: 20), // 底部留白
          ],
        ),
      ),
    );
  }
}

// 新增：已保存文件结构
class SavedFile {
  final String name;
  final String path;
  final String type; // 'image', 'video', 'audio', 'document'
  final DateTime dateCreated;
  final int size;
  
  SavedFile({
    required this.name,
    required this.path,
    required this.type,
    required this.dateCreated,
    required this.size,
  });
}