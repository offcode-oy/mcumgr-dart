import 'dart:async';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:cbor/cbor.dart';
import 'package:mcumgr/client.dart';
import 'package:mcumgr/msg.dart';
import 'package:mcumgr/util.dart';

const _imgGroup = 1;
const _imgCmdState = 0;
const _imgCmdUpload = 1;
const _imgCmdErase = 5;

/// The state of the images on a devices.
class ImageState {
  /// The list of images on the device.
  final List<ImageStateImage> images;
  final int splitStatus;

  ImageState(CborMap input)
      : images = (input[CborString("images")] as CborList).map((value) => ImageStateImage(value as CborMap)).toList(),
        splitStatus = (input[CborString("splitStatus")] as CborInt).toInt();

  @override
  String toString() {
    return 'ImageState{images: $images, splitStatus: $splitStatus}';
  }
}

/// An image on a device.
class ImageStateImage {
  final int slot;
  final String version;
  final List<int> hash;
  final bool bootable;
  final bool pending;
  final bool confirmed;
  final bool active;
  final bool permanent;

  ImageStateImage(CborMap input)
      : slot = (input[CborString("slot")] as CborInt).toInt(),
        version = (input[CborString("version")] as CborString).toString(),
        hash = (input[CborString("hash")] as CborBytes).bytes,
        bootable = (input[CborString("bootable")] as CborBool).value,
        pending = (input[CborString("pending")] as CborBool).value,
        confirmed = (input[CborString("confirmed")] as CborBool).value,
        active = (input[CborString("active")] as CborBool).value,
        permanent = (input[CborString("permanent")] as CborBool).value;

  @override
  String toString() {
    return 'Image{slot: $slot, version: $version, hash: $hash, bootable: $bootable, pending: $pending, confirmed: $confirmed, active: $active, permanent: $permanent}';
  }
}

class ImageUploadResponse {
  final int nextOffset;

  ImageUploadResponse(CborMap input) : nextOffset = (input[CborString("off")] as CborInt).toInt();
}

class _ImageUploadChunk {
  final int offset;
  final int size;
  final int end;

  _ImageUploadChunk(this.offset, this.size) : end = offset + size;
}

class _ImageUpload {
  final Client client;
  final int image;
  final List<int> data;
  final List<int> hash;
  final Duration chunkTimeout;
  final int maxChunkSize;
  final void Function(int)? onProgress;
  final int windowSize;
  final List<_ImageUploadChunk> pending = [];
  final completer = Completer<void>();

  _ImageUpload({
    required this.client,
    required this.image,
    required this.data,
    required this.hash,
    required this.chunkTimeout,
    required this.maxChunkSize,
    required this.onProgress,
    required this.windowSize,
  });

  int sendChunk(int offset) {
    int chunkSize = data.length - offset;
    if (chunkSize > maxChunkSize) {
      chunkSize = maxChunkSize;
    }
    if (chunkSize <= 0) {
      return 0;
    }
    List<int> chunkData = data.sublist(offset, offset + chunkSize);

    final chunk = _ImageUploadChunk(offset, chunkSize);
    pending.add(chunk);

    final Future<ImageUploadResponse> future;
    if (offset == 0) {
      future = client.startImageUpload(
        image,
        chunkData,
        data.length,
        hash,
        chunkTimeout,
      );
    } else {
      future = client.continueImageUpload(
        offset,
        chunkData,
        chunkTimeout,
      );
    }

    future.then(
      (response) => _onChunkDone(chunk, response),
      onError: (error, stackTrace) => _onChunkError(chunk, error, stackTrace),
    );
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

  void _onChunkDone(_ImageUploadChunk chunk, ImageUploadResponse response) {
    // remove this chunk and abandon earlier chunks
    // (if an earlier chunk is still pending, its packet was probably lost)
    final index = pending.indexOf(chunk);
    pending.removeRange(0, index + 1);
    if (index == -1) {
      // ignore abandoned chunks
      return;
    }

    onProgress?.call(response.nextOffset);

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
    _ImageUploadChunk chunk,
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
}

extension ClientImgExtension on Client {
  /// Reads which images are currently present on the device.
  Future<ImageState> readImageState(Duration timeout) {
    return execute(
      Message(
        op: Operation.read,
        group: _imgGroup,
        id: _imgCmdState,
        flags: 0,
        data: CborMap({}),
      ),
      timeout,
    ).unwrap().then((value) => ImageState(value.data));
  }

  /// Marks the image with the specified hash as pending.
  ///
  /// If [confirm] is false, the device will boot the image only once.
  Future<ImageState> setPendingImage(List<int> hash, bool confirm, Duration timeout) {
    return execute(
      Message(
        op: Operation.write,
        group: _imgGroup,
        id: _imgCmdState,
        flags: 0,
        data: CborMap({
          CborString("hash"): CborBytes(hash),
          CborString("confirm"): CborBool(confirm),
        }),
      ),
      timeout,
    ).unwrap().then((value) => ImageState(value.data));
  }

  /// Confirms the currently running image.
  ///
  /// The device will keep using this image after future reboots.
  Future<ImageState> confirmImageState(Duration timeout) {
    // empty hash = currently booted image
    return setPendingImage([], true, timeout);
  }

  /// Sends the first chunk of a firmware upload.
  ///
  /// This is a low-level API. You are probably looking for [uploadImage].
  Future<ImageUploadResponse> startImageUpload(
    int image,
    List<int> data,
    int length,
    List<int> sha256,
    Duration timeout,
  ) {
    return execute(
      Message(
        op: Operation.write,
        group: _imgGroup,
        id: _imgCmdUpload,
        flags: 0,
        data: CborMap({
          CborString("image"): CborSmallInt(image),
          CborString("data"): CborBytes(data),
          CborString("len"): CborSmallInt(length),
          CborString("off"): CborSmallInt(0),
          CborString("sha"): CborBytes(sha256),
        }),
      ),
      timeout,
    ).unwrap().then((value) => ImageUploadResponse(value.data));
  }

  /// Sends a chunk of a firmware upload.
  ///
  /// The first chunk should be uploaded using [startImageUpload] instead.
  ///
  /// This is a low-level API. You are probably looking for [uploadImage].
  Future<ImageUploadResponse> continueImageUpload(
    int offset,
    List<int> data,
    Duration timeout,
  ) {
    return execute(
      Message(
        op: Operation.write,
        group: _imgGroup,
        id: _imgCmdUpload,
        flags: 0,
        data: CborMap({
          CborString("data"): CborBytes(data),
          CborString("off"): CborSmallInt(offset),
        }),
      ),
      timeout,
    ).unwrap().then((value) => ImageUploadResponse(value.data));
  }

  /// Uploads an image to the device.
  ///
  /// [image] is the type of the image (usually 0).
  /// The [data] will be sent to the device in chunks.
  /// Use [McuImage.decode] to obtain the [hash].
  ///
  /// If specified, [onProgress] will be called after each uploaded chunk.
  /// Its parameter is the number bytes uploaded so far.
  ///
  /// [windowSize] is the maximum number of in-flight chunks.
  /// Defaults to 3.
  /// Use 1 for no concurrency (send packet, wait for response, send next).
  Future<void> uploadImage(
    int image,
    List<int> data,
    List<int> hash,
    Duration chunkTimeout, {
    int chunkSize = 128,
    void Function(int)? onProgress,
    int windowSize = 3,
  }) async {
    final upload = _ImageUpload(
      client: this,
      image: image,
      data: data,
      hash: hash,
      chunkTimeout: chunkTimeout,
      maxChunkSize: chunkSize,
      onProgress: onProgress,
      windowSize: windowSize,
    );
    upload.start();
    return upload.completer.future;
  }

  /// Erases the image in the inactive slot.
  ///
  /// There is no need to call this before uploading an image, it will be
  /// overwritten automatically.
  Future<void> erase(Duration timeout) {
    return execute(
      Message(
        op: Operation.write,
        group: _imgGroup,
        id: _imgCmdErase,
        flags: 0,
        data: CborMap({}),
      ),
      timeout,
    ).unwrap();
  }
}

const _imageHeaderMagic = 0x96f3b83d;
const _imageTLVMagic = 0x6907;

int _decodeInt(List<int> input, int offset, int length) {
  var result = 0;
  for (var i = 0; i < length; i++) {
    result |= input[offset + i] << (8 * i);
  }
  return result;
}

/// The version number of an image.
class ImageVersion {
  final int major;
  final int minor;
  final int revision;
  final int build;

  ImageVersion(
    this.major,
    this.minor,
    this.revision,
    this.build,
  );

  ImageVersion.decode(List<int> input)
      : this(
          _decodeInt(input, 0, 1),
          _decodeInt(input, 1, 1),
          _decodeInt(input, 2, 2),
          _decodeInt(input, 4, 4),
        );

  @override
  String toString() {
    var result = '$major.$minor.$revision';
    if (build != 0) {
      result += '.$build';
    }
    return result;
  }
}

/// The header of an image file.
class McuImageHeader {
  final int loadAddress;
  final int headerSize;
  final int imageSize;
  final int flags;
  final ImageVersion version;

  McuImageHeader(
    this.loadAddress,
    this.headerSize,
    this.imageSize,
    this.flags,
    this.version,
  );

  factory McuImageHeader.decode(List<int> input) {
    final magic = _decodeInt(input, 0, 4);
    if (magic != _imageHeaderMagic) {
      throw FormatException("incorrect magic");
    }

    return McuImageHeader(
      _decodeInt(input, 4, 4),
      _decodeInt(input, 8, 2),
      _decodeInt(input, 12, 4),
      _decodeInt(input, 16, 4),
      ImageVersion.decode(input.sublist(20, 28)),
    );
  }

  @override
  String toString() {
    return 'McuImageHeader{loadAddress: $loadAddress, headerSize: $headerSize, imageSize: $imageSize, flags: $flags, version: $version}';
  }
}

/// TLV section of an image file.
class McuImageTLV {
  final List<McuImageTLVEntry> entries;

  McuImageTLV(this.entries);

  factory McuImageTLV.decode(List<int> input, int offset) {
    final magic = _decodeInt(input, offset, 2);
    if (magic != _imageTLVMagic) {
      throw FormatException("incorrect magic");
    }

    final length = _decodeInt(input, offset + 2, 2);
    final end = offset + length;
    offset += 4;

    final entries = <McuImageTLVEntry>[];
    while (offset < end) {
      final entry = McuImageTLVEntry.decode(input, offset, end);
      entries.add(entry);
      offset += entry.length + 4;
    }

    return McuImageTLV(entries);
  }

  @override
  String toString() {
    return 'McuImageTLV{entries: $entries}';
  }
}

/// An entry of the TLV section of an image file.
class McuImageTLVEntry {
  final int type;
  final int length;
  final List<int> value;

  McuImageTLVEntry(this.type, this.length, this.value);

  factory McuImageTLVEntry.decode(List<int> input, int start, int end) {
    if (start + 4 > end) {
      throw FormatException("tlv header doesn't fit");
    }
    final type = _decodeInt(input, start, 1);
    final length = _decodeInt(input, start + 2, 2);
    if (start + 4 + length > end) {
      throw FormatException("tlv value doesn't fit");
    }
    final value = input.sublist(start + 4, start + 4 + length);
    return McuImageTLVEntry(type, length, value);
  }

  @override
  String toString() {
    return 'McuImageTLVEntry{type: $type, length: $length, value: $value}';
  }
}

/// An image file which can be uploaded to a device.
class McuImage {
  final McuImageHeader header;
  final McuImageTLV tlv;
  final List<int> hash;

  static List<int> _getHash(McuImageTLV tlv) {
    for (final entry in tlv.entries) {
      if (entry.type == 0x10) {
        return entry.value;
      }
    }
    throw FormatException("image doesn't contain hash");
  }

  McuImage(this.header, this.tlv) : hash = _getHash(tlv);

  /// Decodes an image file.
  factory McuImage.decode(List<int> input) {
    final header = McuImageHeader.decode(input);
    final tlv = McuImageTLV.decode(input, header.headerSize + header.imageSize);
    return McuImage(header, tlv);
  }

  /// The content might be also a zip file. which contains 2 binaries and a manifest file.
  /// The manifest file contains the information about the binaries.
  /// // Example of the manifest file:
  /*
    {
      "format-version": 0,
      "time": 1687863040,
      "files": [
          {
              "type": "application",
              "board": "stethoscope_cpuapp",
              "soc": "nRF5340_CPUAPP_QKAA",
              "load_address": 66048,
              "image_index": "0",
              "slot_index_primary": "1",
              "slot_index_secondary": "2",
              "version_MCUBOOT": "0.1.9+76",
              "size": 559016,
              "file": "app_update.bin",
              "modtime": 1687863040
          },
          {
              "type": "application",
              "board": "stethoscope_cpunet",
              "soc": "nRF5340_CPUNET_QKAA",
              "image_index": "1",
              "slot_index_primary": "3",
              "slot_index_secondary": "4",
              "load_address": 16812032,
              "version": "1",
              "size": 189760,
              "file": "net_core_app_update.bin",
              "modtime": 1687863023
          }
      ],
      "name": "fw-stethoscope",
      "firmware": {
          "zephyr": {
              "revision": "e0293e9301140f940925b3970307df4fc68b23fa-dirty"
          },
          "nrf": {
              "revision": "0677b0991e4c3ea58efd14e9e33b6c29a1919113"
          }
      }
  }
  */
  // Implement the decoder for the zip file and return the list of binaries as McuImage objects.
  static List<McuImage> decodeZip(List<int> input) {
    final archive = ZipDecoder().decodeBytes(input);
    var manifestFile = archive.files
        .firstWhere((f) => f.name == "manifest.json", orElse: () => throw FormatException("manifest file not found"));
    final manifest = Manifest.fromJson(jsonDecode(utf8.decode(manifestFile.content)));
    final binaries = <McuImage>[];
    for (final file in manifest.files!) {
      final binaryFile = archive.files
          .firstWhere((f) => f.name == file.file, orElse: () => throw FormatException("binary file not found"));
      binaries.add(McuImage.decode(binaryFile.content));
    }
    return binaries;
  }

  @override
  String toString() {
    return 'McuImage{header: $header, tlv: $tlv, hash: $hash}';
  }
}

class Manifest {
  int? formatVersion;
  int? time;
  List<DfuFile>? files;
  String? name;
  Firmware? firmware;

  Manifest({this.formatVersion, this.time, this.files, this.name, this.firmware});

  Manifest.fromJson(Map<String, dynamic> json) {
    formatVersion = json['format-version'];
    time = json['time'];
    if (json['files'] != null) {
      files = <DfuFile>[];
      json['files'].forEach((v) {
        files?.add(DfuFile.fromJson(v));
      });
    }
    name = json['name'];
    firmware = json['firmware'] != null ? Firmware.fromJson(json['firmware']) : null;
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['format-version'] = formatVersion;
    data['time'] = time;
    if (files != null) {
      data['files'] = files?.map((v) => v.toJson()).toList();
    }
    data['name'] = name;
    if (firmware != null) {
      data['firmware'] = firmware?.toJson();
    }
    return data;
  }
}

class DfuFile {
  String? type;
  String? board;
  String? soc;
  int? loadAddress;
  String? imageIndex;
  String? slotIndexPrimary;
  String? slotIndexSecondary;
  String? versionMCUBOOT;
  int? size;
  String? file;
  int? modtime;
  String? version;

  DfuFile(
      {this.type,
      this.board,
      this.soc,
      this.loadAddress,
      this.imageIndex,
      this.slotIndexPrimary,
      this.slotIndexSecondary,
      this.versionMCUBOOT,
      this.size,
      this.file,
      this.modtime,
      this.version});

  DfuFile.fromJson(Map<String, dynamic> json) {
    type = json['type'];
    board = json['board'];
    soc = json['soc'];
    loadAddress = json['load_address'];
    imageIndex = json['image_index'];
    slotIndexPrimary = json['slot_index_primary'];
    slotIndexSecondary = json['slot_index_secondary'];
    versionMCUBOOT = json['version_MCUBOOT'];
    size = json['size'];
    file = json['file'];
    modtime = json['modtime'];
    version = json['version'];
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['type'] = type;
    data['board'] = board;
    data['soc'] = soc;
    data['load_address'] = loadAddress;
    data['image_index'] = imageIndex;
    data['slot_index_primary'] = slotIndexPrimary;
    data['slot_index_secondary'] = slotIndexSecondary;
    data['version_MCUBOOT'] = versionMCUBOOT;
    data['size'] = size;
    data['file'] = file;
    data['modtime'] = modtime;
    data['version'] = version;
    return data;
  }
}

class Firmware {
  Zephyr? zephyr;
  Nrf? nrf;

  Firmware({this.zephyr, this.nrf});

  Firmware.fromJson(Map<String, dynamic> json) {
    zephyr = json['zephyr'] != null ? Zephyr.fromJson(json['zephyr']) : null;
    nrf = json['nrf'] != null ? Nrf.fromJson(json['nrf']) : null;
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    if (zephyr != null) {
      data['zephyr'] = zephyr?.toJson();
    }
    if (nrf != null) {
      data['nrf'] = nrf?.toJson();
    }
    return data;
  }
}

class Zephyr {
  String? revision;

  Zephyr({this.revision});

  Zephyr.fromJson(Map<String, dynamic> json) {
    revision = json['revision'];
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['revision'] = revision;
    return data;
  }
}

class Nrf {
  String? revision;

  Nrf({this.revision});

  Nrf.fromJson(Map<String, dynamic> json) {
    revision = json['revision'];
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['revision'] = revision;
    return data;
  }
}
