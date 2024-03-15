import 'dart:async';
import 'dart:io';

import 'package:cbor/cbor.dart';
import 'package:mcumgr/mcumgr.dart';
import 'package:mcumgr/msg.dart';
import 'package:mcumgr/util.dart';

const _fsGroup = 8;
const _fsFileId = 0;

/// Extension for the file system group.
extension ClientFsExtension on Client {
  //********************************************************************************************************************
  //************************************************ UPLOAD ************************************************************
  //********************************************************************************************************************
  /// Upload a data to the device.
  ///
  /// [deviceFilePath] is the path to the file to upload (from the target device).
  ///
  /// [data] is the data to upload.
  ///
  /// [chunkSize] is the size of each chunk to upload.
  ///
  /// [timeout] is the maximum time to wait for a response. (default: 5 seconds)
  ///
  /// If specified, [onProgress] will be called after each uploaded chunk.
  /// Its parameter is the number bytes uploaded so far.
  ///
  /// [windowSize] is the maximum number of in-flight chunks. (default: 1)
  /// Use 1 for no concurrency (send packet, wait for response, send next).
  Future<void> uploadData({
    required String deviceFilePath,
    required List<int> data,
    required int chunkSize,
    int windowSize = 1, // default: 1, curretly only 1 is supported
    void Function(double)? onProgress,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final upload = _FsFileUpload(
        deviceFilePath: deviceFilePath,
        client: this,
        onProgress: onProgress,
        data: data,
        timeout: timeout,
        maxBufferSize: chunkSize,
        windowSize: windowSize);
    upload.start();
    return upload.completer.future;
  }

  /// Upload data to the device.
  ///
  /// [filePath] is the path to the file to upload (filesystem on the target device).
  ///
  /// [data] is the data to upload.
  ///
  /// [lenght] is the length of the data to upload.
  ///
  /// [offset] is the offset in the file to start uploading from.
  ///
  /// [timeout] is the maximum time to wait for a response. (default: 5 seconds)
  Future<FsUploadResponse> _startUpload(
      {required String filePath,
      required List<int> data,
      required int lenght,
      required int offset,
      Duration timeout = const Duration(seconds: 5)}) {
    return execute(
      Message(
        op: Operation.write,
        group: _fsGroup,
        id: _fsFileId,
        flags: 0,
        data: CborMap({
          CborString("name"): CborString(filePath),
          CborString("data"): CborBytes(data),
          CborString("len"): CborSmallInt(lenght),
          CborString("off"): CborSmallInt(offset),
        }),
      ),
      timeout,
    ).unwrap().then((msg) => FsUploadResponse(msg.data));
  }

  /// Continue uploading data to the device.
  ///
  /// [filePath] is the path to the file to upload (filesystem on the target device).
  ///
  /// [offset] is the offset in the file to start uploading from.
  ///
  /// [data] is the data to upload.
  ///
  /// [timeout] is the maximum time to wait for a response. (default: 5 seconds)
  Future<FsUploadResponse> _continueUpload(
      {required filePath,
      required int offset,
      required List<int> data,
      Duration timeout = const Duration(seconds: 5)}) {
    return execute(
      Message(
        op: Operation.write,
        group: _fsGroup,
        id: _fsFileId,
        flags: 0,
        data: CborMap({
          CborString("name"): CborString(filePath),
          CborString("data"): CborBytes(data),
          CborString("off"): CborSmallInt(offset),
        }),
      ),
      timeout,
    ).unwrap().then((msg) => FsUploadResponse(msg.data));
  }

  //********************************************************************************************************************
  //************************************************ DOWNLOAD **********************************************************
  //********************************************************************************************************************
  /// Download a file from the device.
  ///
  /// [deviceFilePath] is the path to the file to download (from the target device).
  ///
  /// [savePath] is the name of the file to download to (save).
  ///
  /// If specified, [onProgress] will be called after each downloaded chunk.
  /// Its parameter is the number bytes uploaded so far.
  ///
  /// [timeout] is the maximum time to wait for a response. (default: 5 seconds)
  Future<void> downloadFile(
      {required String deviceFilePath,
      required String savePath,
      void Function(double)? onProgress,
      Duration timeout = const Duration(seconds: 5)}) async {
    final download = _FsFileDownload(
      client: this,
      onProgress: onProgress,
      deviceFilePath: deviceFilePath,
      savePath: savePath,
      timeout: timeout,
    );
    download.start(deviceFilePath, savePath, timeout);
    return download.completer.future;
  }

  /// Download a log file from the device.
  ///
  /// [deviceFilePath] is the path to the file to download (from the target device).
  ///
  /// [savePath] is the name of the file to download to (save).
  ///
  /// [deviceName] is the name of the device.
  ///
  /// [logName] is the index of the log.
  ///
  /// [setNewPath] is a function that sets the new path of the file.
  ///
  /// If specified, [onProgress] will be called after each downloaded chunk.
  ///
  /// [timeout] is the maximum time to wait for a response. (default: 5 seconds)
  Future<void> downloadLogFile(
      {required String deviceFilePath,
      required String savePath,
      void Function(double)? onProgress,
      required String deviceName,
      required String logName,
      required String fwVersion,
      required Function(String) setNewPath,
      Duration timeout = const Duration(seconds: 5)}) async {
    final download = _FsFileDownload(
      client: this,
      onProgress: onProgress,
      deviceFilePath: deviceFilePath,
      setNewPath: setNewPath,
      savePath: savePath,
      timeout: timeout,
      logDownload: true,
      deviceName: deviceName,
      logName: logName,
      fwVersion: fwVersion,
    );
    download.start(deviceFilePath, savePath, timeout);
    return download.completer.future;
  }

  /// Download a chunk from the device.
  ///
  /// [path] is the path to the file to download.
  ///
  /// [offset] is the offset in the file to start downloading from.
  ///
  /// [timeout] is the maximum time to wait for a response.
  ///
  /// Returns a [FsDownloadResponse] with the data and metadata.
  Future<FsDownloadResponse> downloadChunk(String path, int offset, Duration timeout) {
    return execute(
      Message(
        op: Operation.read,
        group: _fsGroup,
        id: _fsFileId,
        flags: 0,
        data: CborMap({
          CborString("off"): CborSmallInt(offset),
          CborString("name"): CborString(path),
        }),
      ),
      timeout,
    ).unwrap().then((msg) {
      return FsDownloadResponse(msg.data);
    });
  }
}

//**********************************************************************************************************************
//************************************************ UPLOAD **************************************************************
//**********************************************************************************************************************
/// Class for uploading data to the device.
class _FsFileUpload {
  final Client client;
  final String deviceFilePath;
  final List<int> data;
  final Duration timeout;
  final int maxBufferSize;
  final void Function(double)? onProgress;
  final int windowSize;
  final List<_FsUploadChunk> pending = [];
  final completer = Completer<void>();

  _FsFileUpload({
    required this.client,
    required this.deviceFilePath,
    required this.data,
    required this.timeout,
    required this.maxBufferSize,
    required this.onProgress,
    required this.windowSize,
  });

  int sendChunk(int offset) {
    int chunkSize = data.length - offset;
    int maxBufSize = getMaxChunkSize(
        offset: offset, dataLen: data.length, maxMcuMgrBuffLen: maxBufferSize, filename: deviceFilePath);
    if (chunkSize > maxBufSize) {
      chunkSize = maxBufSize;
    }
    if (chunkSize <= 0) {
      return 0;
    }
    List<int> chunckData = data.sublist(offset, offset + chunkSize);

    final chunk = _FsUploadChunk(offset, offset + chunkSize);
    pending.add(chunk);

    final Future<FsUploadResponse> future;
    if (offset == 0) {
      future = client._startUpload(
          filePath: deviceFilePath, data: chunckData, lenght: data.length, offset: offset, timeout: timeout);
    } else {
      future = client._continueUpload(filePath: deviceFilePath, offset: offset, data: chunckData);
    }

    future.then((response) => _onChunkDone(chunk, response),
        onError: (error, stackTrace) => _onChunkError(chunk, error, stackTrace));

    return chunkSize;
  }

  void _sendNext(int offset) {
    while (pending.length < windowSize) {
      final chunkSize = sendChunk(offset);
      if (chunkSize == 0) {
        break;
      }
      offset += chunkSize;
    }
  }

  void _onChunkDone(_FsUploadChunk chunk, FsUploadResponse response) {
    // remove this chunk and abandon earlier chunks
    // (if an earlier chunk is still pending, its packet was probably lost)
    final index = pending.indexOf(chunk);
    pending.removeRange(0, index + 1);
    if (index == -1) {
      // ignore abandoned chunks
      return;
    }

    onProgress?.call(response.nextOffset / data.length);

    while (pending.isNotEmpty && pending.first.offset != response.nextOffset) {
      // pending chunk has the wrong offset, abandon it
      pending.removeAt(0);
    }

    int nextOffset = response.nextOffset;
    if (pending.isNotEmpty) {
      nextOffset = pending.last.end;
    }
    _sendNext(nextOffset);

    if (response.nextOffset == data.length) {
      assert(pending.isEmpty);
      completer.complete();
    }
  }

  void _onChunkError(
    _FsUploadChunk chunk,
    Object error,
    StackTrace stackTrace,
  ) {
    if (!pending.remove(chunk)) {
      // ignore abandoned chunks
      return;
    }

    // abandon all chunks
    pending.clear();

    completer.completeError(error, stackTrace);
  }

  void start() {
    _sendNext(0);
  }

  int getMaxChunkSize(
      {required int offset, required int dataLen, required String filename, required int maxMcuMgrBuffLen}) {
    // The size of the header is based on the scheme. CoAP scheme is larger because there are
    // 4 additional bytes of CBOR.
    int headerSize = 8;

    // Size of the indefinite length map tokens (bf, ff)
    int mapSize = 2;

    // Size of the field name "data" utf8 string
    int dataStringSize = CborString("data").utf8Bytes.length;

    // Size of the string "off" plus the length of the offset integer
    int offsetSize = cbor.encode(CborMap({CborString("off"): CborSmallInt(offset)})).length;

    // Size of the string "len" plus the length of the data size integer
    // "len" is sent only in the initial packet.
    int lengthSize = (offset == 0) ? cbor.encode(CborMap({CborString("len"): CborSmallInt(dataLen)})).length : 1;

    // Implementation specific size
    int implSpecificSize = cbor.encode(CborMap({CborString("name"): CborString(filename)})).length;

    int combinedSize = headerSize + mapSize + offsetSize + lengthSize + implSpecificSize + dataStringSize;

    // Now we calculate the max amount of data that we can fit given the MTU.
    int maxDataLength = maxMcuMgrBuffLen - combinedSize;

    return maxDataLength;
  }
}

/// Response to a file download request.
///
/// [offset] is the offset of the next chunk to download.
///
/// [bytesReseived] is the number of bytes received in this chunk.
///
/// [fileLength] is the length of the file to download.
///
/// [data] is the data received in this chunk.

/// Response to a file upload request.
class FsUploadResponse {
  final int nextOffset;

  FsUploadResponse(CborMap input) : nextOffset = (input[CborString("off")] as CborInt).toInt();
}

/// A chunk of data to upload.
class _FsUploadChunk {
  final int offset;
  final int size;
  final int end;

  _FsUploadChunk(this.offset, this.size) : end = offset + size;
}

//**********************************************************************************************************************
//************************************************ DOWNLOAD ************************************************************
//**********************************************************************************************************************
/// Class for downloading a file from the device.
/// [client] is the client to use for downloading.
///
/// [onProgress] will be called after each downloaded chunk.
///
/// [deviceFilePath] is the path to the file to download (optional).
///
/// [savePath] is the name of the file to download to.
///
/// [timeout] is the maximum time to wait for a response.
///
/// [completer] is a completer that will be completed when the download is done.
///
/// FOR LOG DOWNLOADS ----->
///
/// [logDownload] is a flag that indicates if the download is a log download.
///
/// [setNewPath] is a function that sets the new path of the file.
///
/// [deviceName] is the name of the device.
///
/// [logName] is the index of the log.
///
/// [fwVersion] is the firmware version of the device.
class _FsFileDownload {
  final Client client;
  final void Function(double)? onProgress;
  final String deviceFilePath;
  final Duration timeout;
  final completer = Completer<void>();
  String savePath;
  bool logDownload;
  Function(String)? setNewPath;
  String? deviceName;
  String? logName;
  String? fwVersion;

  _FsFileDownload({
    required this.client,
    required this.onProgress,
    required this.deviceFilePath,
    required this.savePath,
    required this.timeout,
    this.logDownload = false,
    this.setNewPath,
    this.deviceName,
    this.logName,
    this.fwVersion,
  });

  /// Downloads a file from the device.
  ///
  /// [deviceFilePath] is the path to the file on the device.
  ///
  /// [savePath] is the name of the file to download to.
  ///
  /// [timeout] is the timeout for the request.
  void start(String deviceFilePath, String savePath, Duration timeout) async {
    File file = File(savePath);
    this.setNewPath?.call(savePath);
    final Future<FsDownloadResponse> future;
    int bytesReseivedTotal = 0;
    int offset = 0;
    int fileLength = 0;

    final _FileDownloadObj fDownObj =
        _FileDownloadObj(file, deviceFilePath, offset, fileLength, bytesReseivedTotal, timeout);

    future = client.downloadChunk(fDownObj.path, fDownObj.offset, fDownObj.timeout);

    future.then((response) => _onDownloadDone(response, fDownObj),
        onError: (error, stackTrace) => _onDownloadError(error, stackTrace));
  }

  /// Downloads the next chunk of a file from the device.
  void _downloadNextChunk(_FileDownloadObj fDownObj) {
    final Future<FsDownloadResponse> future;
    future = client.downloadChunk(fDownObj.path, fDownObj.offset, fDownObj.timeout);

    future.then((response) => _onDownloadDone(response, fDownObj),
        onError: (error, stackTrace) => _onDownloadError(error, stackTrace));
  }

  void _onDownloadDone(FsDownloadResponse response, _FileDownloadObj fDownObj) {
    if (fDownObj.offset == 0) {
      // File length is only set on the first response
      fDownObj.length = response.fileLength!;
      fDownObj.bytesReseivedTotal = 0;

      // ONLY FOR LOG DOWNLOADS
      if (this.logDownload) {
        try {
          // First byte of the first chunk is the lenght of the metadata in the file
          final metadataLength = response.data.bytes[0];
          // Extract metadata from the file. This will be cbor coded map with keys: ts, hw, fw
          final metadata = response.data.bytes.sublist(1, metadataLength + 1);
          // collect the metadata (timestamp, hw revision, firmware version)
          final metadataMap = cbor.decode(metadata) as CborMap;
          String firmwareVersion = (metadataMap[CborString("fw")] as CborString).toString();
          String hwVersion = (metadataMap[CborString("hw")] as CborString).toString();
          int timestamp = (metadataMap[CborString("ts")] as CborInt).toInt();

          // Make the timestamp human readable as a date string
          DateTime date = DateTime.fromMicrosecondsSinceEpoch(timestamp);
          String formatedTime = date.toString().split(".")[0].replaceAll(" ", "-").replaceAll(":", "");

          final newPath =
              "${this.savePath}/${this.deviceName}_${formatedTime}_${firmwareVersion}_${hwVersion}_${this.logName}";
          this.setNewPath?.call(newPath);

          // Create new file with different filename
          fDownObj.file = File(newPath);

          // Remove the metadata from the response.data bytes
          response.data.bytes.removeRange(0, metadataLength + 1);
        } catch (e) {
          print("Error parsing metadata: $e");
          print("Continuing with the data from the app");
          // if the metadata is not accessible or other error occurs, just continue downloading
          // with the data from the app

          // Get the current date and time for the file name
          String timeNow = DateTime.now().toString().split(".")[0].replaceAll(" ", "-").replaceAll(":", "");

          final newPath = "${this.savePath}/${this.deviceName}_${timeNow}_${this.fwVersion}_${this.logName}";
          print("New path: $newPath");
          this.setNewPath?.call(newPath);

          // Create new file with different filename
          fDownObj.file = File(newPath);
        }
      }
    }

    int newOffset = fDownObj.offset + response.bytesReseived;
    fDownObj.bytesReseivedTotal += response.bytesReseived;
    fDownObj.offset = newOffset;

    onProgress?.call(newOffset / fDownObj.length);

    // Write data to file
    fDownObj.file!.writeAsBytes((response.data).bytes, mode: FileMode.append);

    // Check that if the file is complete (reseived bytes equal to file length)
    if (fDownObj.bytesReseivedTotal == fDownObj.length) {
      // Complete the completer
      completer.complete();
    } else if (fDownObj.bytesReseivedTotal > fDownObj.length) {
      // If the file length is less than the number of bytes received, then the file is corrupt and we should stop
      // completer.completeError("File length is greater than the number of bytes received");
    } else {
      _downloadNextChunk(fDownObj);
    }
  }

  /// Error handler for downloadFile
  void _onDownloadError(
    Object error,
    StackTrace stackTrace,
  ) {
    completer.completeError(error, stackTrace);
  }
}

class FsDownloadResponse {
  // final int offset;
  final int bytesReseived;
  final int? fileLength;
  final CborBytes data;

  FsDownloadResponse(CborMap input)
      : bytesReseived = (input[CborString("data")] as CborBytes).bytes.length,
        fileLength = (input[CborString("len")] as CborInt?)?.toInt(),
        data = input[CborString("data")] as CborBytes;

  @override
  String toString() {
    return "bytesReseived: $bytesReseived, fileLength: $fileLength, data: $data";
  }
}

/// Class for holding the file download information.
class _FileDownloadObj {
  File? file;
  String path;
  int offset;
  int length;
  int bytesReseivedTotal;
  Duration timeout;

  _FileDownloadObj(this.file, this.path, this.offset, this.length, this.bytesReseivedTotal, this.timeout);
}
