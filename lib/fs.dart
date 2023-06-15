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
  /// Download a chunk from the device.
  ///
  /// [path] is the path to the file to download.
  ///
  /// [offset] is the offset in the file to start downloading from.
  ///
  /// [timeout] is the maximum time to wait for a response.
  ///
  /// Returns a [_FsDownloadResponse] with the data and metadata.
  Future<_FsDownloadResponse> downloadChunk(String path, int offset, Duration timeout) {
    return execute(
      Message(
        op: Operation.write,
        group: _fsGroup,
        id: _fsFileId,
        flags: 0,
        data: CborMap({
          CborString("off"): CborSmallInt(offset),
          CborString("name"): CborString(path),
        }),
      ),
      timeout,
    ).unwrap().then((msg) => _FsDownloadResponse(msg.data));
  }

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
    download.startFileDownload(deviceFilePath, savePath, timeout);
    return download.completer.future;
  }
}

/// Class for downloading a file from the device.
///
/// [bytesReseivedTotal] is the total number of bytes received.
///
/// [offset] is the offset of the next chunk to download.
///
/// [fileLength] is the length of the file to download.
///
/// [client] is the client to use for downloading.
class _FsFileDownload {
  final Client client;
  final void Function(double)? onProgress;
  final String deviceFilePath;
  final String savePath;
  final Duration timeout;
  final completer = Completer<void>();

  _FsFileDownload({
    required this.client,
    required this.onProgress,
    required this.deviceFilePath,
    required this.savePath,
    required this.timeout,
  });

  /// Downloads a file from the device.
  ///
  /// [deviceFilePath] is the path to the file on the device.
  ///
  /// [savePath] is the name of the file to download to.
  ///
  /// [timeout] is the timeout for the request.
  void startFileDownload(String deviceFilePath, String savePath, Duration timeout) async {
    print("Starting file download");
    print("Device file path: $deviceFilePath");
    print("Save path: $savePath");

    File file = File(savePath);
    final Future<_FsDownloadResponse> future;
    int bytesReseivedTotal = 0;
    int offset = 0;
    int fileLength = 0;

    final FileDownloadObj fDownObj =
        FileDownloadObj(file, deviceFilePath, offset, fileLength, bytesReseivedTotal, timeout);

    future = client.downloadChunk(fDownObj.path, fDownObj.offset, fDownObj.timeout);

    future.then((response) => _onDownloadDone(response, fDownObj),
        onError: (error, stackTrace) => _onDownloadError(error, stackTrace));
    completer.complete();
  }

  /// Downloads the next chunk of a file from the device.
  void _downloadNextChunk(FileDownloadObj fDownObj) {
    final Future<_FsDownloadResponse> future;
    future = client.downloadChunk(fDownObj.path, fDownObj.offset, fDownObj.timeout);

    future.then((response) => _onDownloadDone(response, fDownObj),
        onError: (error, stackTrace) => _onDownloadError(error, stackTrace));
  }

  void _onDownloadDone(_FsDownloadResponse response, FileDownloadObj fDownObj) {
    // File length is only set on the first response
    if (response.offset == 0) {
      fDownObj.length = response.fileLength!;
      fDownObj.bytesReseivedTotal = 0;
    }

    fDownObj.bytesReseivedTotal += response.bytesReseived;
    fDownObj.offset = response.offset;

    onProgress?.call((response.offset / fDownObj.length).toDouble());

    print("Bytes received: ${response.bytesReseived}");
    print("Total bytes received : ${fDownObj.bytesReseivedTotal}");
    print("Total file length: ${fDownObj.length}");

    // Write data to file
    fDownObj.file!.writeAsBytes((response.data).bytes, mode: FileMode.append);

    // Check that if the file is complete (reseived bytes equal to file length)
    if (fDownObj.bytesReseivedTotal == fDownObj.length) {
      print("File is complete");
      return;
    } else if (fDownObj.bytesReseivedTotal > fDownObj.length) {
      print("Error: File is too long!");
    } else {
      _downloadNextChunk(fDownObj);
    }
  }

  /// Error handler for downloadFile
  void _onDownloadError(
    Object error,
    StackTrace stackTrace,
  ) {
    print("Error: $error");
    print("Stack trace: $stackTrace");
    print("Error downloading file: $error");
    completer.completeError(error, stackTrace);
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
class _FsDownloadResponse {
  final int offset;
  final int bytesReseived;
  final int? fileLength;
  final CborBytes data;

  _FsDownloadResponse(CborMap input)
      : offset = (input[CborString("off")] as CborInt).toInt(),
        bytesReseived = (input[CborString("data")] as CborBytes).bytes.length,
        fileLength = (input[CborString("len")] as CborInt?)?.toInt(),
        data = input[CborString("data")] as CborBytes;
}

/// Class for holding the file download information.
class FileDownloadObj {
  File? file;
  String path;
  int offset;
  int length;
  int bytesReseivedTotal;
  Duration timeout;

  FileDownloadObj(this.file, this.path, this.offset, this.length, this.bytesReseivedTotal, this.timeout);
}
