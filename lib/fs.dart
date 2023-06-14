import 'dart:io';
import 'dart:js_interop';

import 'package:cbor/cbor.dart';
import 'package:mcumgr/mcumgr.dart';
import 'package:mcumgr/msg.dart';
import 'package:mcumgr/util.dart';

const _fsGroup = 8;
const _fsFileId = 0;
const String testPath = "/lfs/test.txt";

extension ClientFsExtension on Client {
  Future<FsDownloadResponse> downloadChunk(String path, int offset, Duration timeout) {
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
    ).unwrap().then((msg) => FsDownloadResponse(msg.data));
  }
}

/// Response to a file download request.
class FsDownloadResponse {
  final int offset;
  final int bytesReseived;
  final int? fileLength;
  final CborBytes data;

  FsDownloadResponse(CborMap input)
      : offset = (input[CborString("off")] as CborInt).toInt(),
        bytesReseived = (input[CborString("data")] as CborBytes).bytes.length,
        fileLength = (input[CborString("len")] as CborInt?)?.toInt(),
        data = input[CborString("data")] as CborBytes;
}

/// Class for downloading a file from the device.
///
/// [file] is the file to download to.
///
/// [bytesReseivedTotal] is the total number of bytes received.
///
/// [offset] is the offset of the next chunk to download.
///
/// [fileLength] is the length of the file to download.
///
/// [client] is the client to use for downloading.
class FsFileDownload {
  final Client client;

  FsFileDownload(this.client);

  /// Downloads a file from the device.
  ///
  /// [path] is the path to the file on the device.
  ///
  /// [fileName] is the name of the file to download to.
  ///
  /// [timeout] is the timeout for the request.
  Future<bool> startFileDownload(String path, String fileName, Duration timeout) async {
    File file = File(fileName);
    final Future<FsDownloadResponse> future;
    int bytesReseivedTotal = 0;
    int offset = 0;
    int fileLength = 0;

    final FileDownloadObject fileDownloadObject =
        FileDownloadObject(file, path, offset, fileLength, bytesReseivedTotal);

    future = client.downloadChunk(fileDownloadObject.path, fileDownloadObject.offset, fileDownloadObject.timeout);

    future.then((response) => _onDownloadDone(response, fileDownloadObject), onError: (error, stackTrace) {
      _onDownloadError(error, stackTrace);
      print("Error downloading file: $error");
      return false;
    });
    return true;
  }

  /// Downloads the next chunk of a file from the device.
  void downloadNextChunk(FileDownloadObject fileDownloadObject) {
    final Future<FsDownloadResponse> future;
    future = client.downloadChunk(fileDownloadObject.path, fileDownloadObject.offset, fileDownloadObject.timeout);

    future.then((response) => _onDownloadDone(response, fileDownloadObject),
        onError: (error, stackTrace) => _onDownloadError(error, stackTrace));
  }

  void _onDownloadDone(FsDownloadResponse response, FileDownloadObject fileDownloadObject) {
    // File length is only set on the first response
    if (response.offset == 0) {
      fileDownloadObject.length = response.fileLength!;
      fileDownloadObject.bytesReseivedTotal = 0;
    }

    fileDownloadObject.bytesReseivedTotal += response.bytesReseived;
    fileDownloadObject.offset = response.offset;

    print("Bytes received: ${response.bytesReseived}");
    print("Total bytes received : ${fileDownloadObject.bytesReseivedTotal}");
    print("Total file length: ${fileDownloadObject.length}");

    // Write data to file
    fileDownloadObject.file!.writeAsBytes((response.data).bytes, mode: FileMode.append);

    // Check that if the file is complete (reseived bytes equal to file length)
    if (fileDownloadObject.bytesReseivedTotal == fileDownloadObject.length) {
      print("File is complete");
      return;
    } else if (fileDownloadObject.bytesReseivedTotal > fileDownloadObject.length) {
      print("Error: File is too long!");
    } else {
      downloadNextChunk(fileDownloadObject);
    }
  }

  /// Error handler for downloadFile
  void _onDownloadError(
    Object error,
    StackTrace stackTrace,
  ) {
    print("Error: $error");
    print("Stack trace: $stackTrace");
  }
}

class FileDownloadObject {
  File? file;
  String path;
  int offset;
  int length;
  int bytesReseivedTotal;
  Duration timeout;

  FileDownloadObject(this.file, this.path, this.offset, this.length, this.bytesReseivedTotal,
      {this.timeout = const Duration(seconds: 5)});
}
