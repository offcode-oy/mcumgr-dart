import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:mcumgr/mcumgr.dart';
import 'package:permission_handler/permission_handler.dart';

const String examplePath = "/lfs/hello.txt";

class DeviceScreen extends StatefulWidget {
  final FlutterReactiveBle ble;
  final DiscoveredDevice device;
  final Duration? connectionTimeout;

  const DeviceScreen({
    Key? key,
    required this.ble,
    required this.device,
    this.connectionTimeout,
  }) : super(key: key);

  @override
  State<StatefulWidget> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  static const Duration timeout = Duration(seconds: 5);
  StreamSubscription<ConnectionStateUpdate>? connection;
  DeviceConnectionState connectionState = DeviceConnectionState.connecting;
  Client? client;
  ImageState? imageState;
  bool installing = false;
  double progress = 0;

  @override
  void initState() {
    super.initState();
    connect();
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }

  void connect() {
    connection?.cancel();
    final stream = widget.ble.connectToDevice(
      id: widget.device.id,
      servicesWithCharacteristicsToDiscover: {
        Uuid.parse("8d53dc1d-1db7-4cd3-868b-8a527460aa84"): [Uuid.parse("da2e7828-fbce-4e01-ae9e-261174997c48")]
      },
      connectionTimeout: widget.connectionTimeout,
    );
    connection = stream.listen(
      handleConnectionState,
      onDone: reconnect,
    );
  }

  Future<void> disconnect() async {
    // don't really need to close the client
    // closing the connection causes the subscription stream to end anyways
    await client?.close();
    client = null;
    await connection?.cancel();
    connection = null;
  }

  void reconnect() async {
    print("Reconnecting...");
    await disconnect();
    connect();
  }

  void handleConnectionState(ConnectionStateUpdate event) async {
    if (event.connectionState == connectionState) {
      return;
    }

    Client? newClient;
    ImageState? newImageState;
    if (event.connectionState == DeviceConnectionState.connected) {
      await widget.ble.requestMtu(deviceId: widget.device.id, mtu: 517);
      final characteristic = QualifiedCharacteristic(
        serviceId: Uuid.parse("8d53dc1d-1db7-4cd3-868b-8a527460aa84"),
        characteristicId: Uuid.parse("da2e7828-fbce-4e01-ae9e-261174997c48"),
        deviceId: widget.device.id,
      );
      newClient = Client(
        input: widget.ble.subscribeToCharacteristic(characteristic).handleError(
          (error) {
            // ignore errors
            // disconnecting causes the stream to end anyways
          },
        ),
        output: (msg) => widget.ble.writeCharacteristicWithoutResponse(characteristic, value: msg),
      );
      try {
        // newImageState = await newClient.readImageState(timeout);
      } catch (e) {
        if (kDebugMode) print("Failed to read image state: $e");
      }
    }

    setState(() {
      connectionState = event.connectionState;
      imageState = newImageState;
      client = newClient;
    });
  }

  Widget buildBody(BuildContext context) {
    if (connectionState == DeviceConnectionState.connecting) {
      return const Center(child: CircularProgressIndicator());
    }

    final widgets = <Widget>[];
    if (imageState != null) {
      widgets.add(ImageStateWidget(
        imageState: imageState!,
        client: client!,
        onImageStateChanged: (state) {
          setState(() {
            imageState = state;
          });
        },
      ));
    }
    if (installing) {
      widgets.add(Card(
        child: ListTile(
          title: const Text("Installing..."),
          subtitle: LinearProgressIndicator(value: progress),
        ),
      ));
    }
    return SingleChildScrollView(
      child: Column(
        children: widgets,
      ),
    );
  }

  void _reset() {
    client!.reset(timeout);
  }

  void _update() async {
    final result = await FilePicker.platform.pickFiles();
    if (result == null) {
      return;
    }
    final resultFile = result.files.single;
    final file = File(resultFile.path!);
    final content = await file.readAsBytes();
    final image = McuImage.decode(content);
    if (client == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Not connected"),
      ));
      return;
    }
    McuMgrBufferParams params;

    params = await client!.params(const Duration(seconds: 5)).catchError((e) {
      if (kDebugMode) print("Error getting params: $e, defaulting to mtu size of 20");
      return const McuMgrBufferParams(bufCount: 1, bufSize: 20);
    });
    setState(() {
      installing = true;
      progress = 0;
    });
    try {
      await client!.uploadImage(
        image: 0,
        data: content,
        hash: image.hash,
        timeout: const Duration(seconds: 30),
        chunkSize: params.bufSize,
        windowSize: 1, // Use 1 for now, otherwise does not work
        sha: image.sha,
        onProgress: (count) {
          setState(() {
            progress = count.toDouble() / content.length;
          });
        },
      );
    } finally {
      setState(() {
        installing = false;
      });
    }
    final state = await client!.readImageState(timeout);
    setState(() {
      imageState = state;
    });
  }

  void _download() async {
    const String examplePath = "/lfs/example.txt";
    const String saveName = "example.txt";

    // Ask permission to access the file system
    final permission = await Permission.storage.request();
    if (permission != PermissionStatus.granted) {
      if (kDebugMode) print("Permission to storage not granted");
      return;
    }

    // Select a place to save the file
    final savePath = await FilePicker.platform.getDirectoryPath();
    if (savePath == null) {
      if (kDebugMode) print("No save path selected");
      return;
    }

    // Add the file name to the save path
    final savePathWithName = "$savePath/$saveName";

    if (client == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Not connected"),
      ));
      return;
    }

    setState(() {
      installing = true;
      progress = 0;
    });

    try {
      if (kDebugMode) print("Calling downloadFile");
      await client!.downloadFile(
        deviceFilePath: examplePath,
        savePath: savePathWithName,
        onProgress: (progress) {
          setState(() {
            progress = progress;
          });
        },
        timeout: const Duration(seconds: 5),
      );
    } finally {
      setState(() {
        installing = false;
      });
    }
  }

  Future<void> _upload() async {
    String filePath = "/lfs/example.txt";
    List<int> bytes = utf8.encode("Testing string");
    if (client == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Not connected"),
      ));
      return;
    }
    McuMgrBufferParams params;

    params = await client!.params(const Duration(seconds: 5)).catchError((e) {
      if (kDebugMode) print("Error getting params: $e, defaulting to mtu size of 20");
      return const McuMgrBufferParams(bufCount: 1, bufSize: 20);
    });

    if (kDebugMode) print("Params: $params");

    try {
      if (kDebugMode) print("Calling uploadFile");
      client!.uploadData(
        deviceFilePath: filePath,
        data: bytes,
        chunkSize: params.bufSize,
        windowSize: 1, // Use 1 for now, otherwise does not work
        onProgress: (progress) {
          if (kDebugMode) print("Upload progress: ${(progress * 100).toStringAsFixed(0)}%");
        },
        timeout: const Duration(seconds: 5),
      );
    } finally {}
  }

  List<Widget> buildActions(BuildContext context) {
    return [
      IconButton(
        icon: const Icon(Icons.refresh),
        onPressed: client != null ? _reset : null,
      ),
      IconButton(
        icon: const Icon(Icons.system_update),
        onPressed: client != null ? _update : null,
      ),
      IconButton(
        icon: const Icon(Icons.download),
        onPressed: client != null ? _download : null,
      ),
      IconButton(
        icon: const Icon(Icons.upload),
        onPressed: client != null ? _upload : null,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.device.name),
        actions: buildActions(context),
      ),
      body: buildBody(context),
    );
  }
}

class ImageStateWidget extends StatelessWidget {
  final ImageState imageState;
  final Client client;
  final void Function(ImageState) onImageStateChanged;

  const ImageStateWidget({
    Key? key,
    required this.imageState,
    required this.client,
    required this.onImageStateChanged,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final widgets = <Widget>[];
    for (final image in imageState.images) {
      widgets.add(ImageWidget(
        image: image,
        client: client,
        onImageStateChanged: onImageStateChanged,
      ));
    }
    return Column(
      children: widgets,
    );
  }
}

class ImageWidget extends StatelessWidget {
  final ImageStateImage image;
  final Client client;
  final void Function(ImageState) onImageStateChanged;

  const ImageWidget({
    Key? key,
    required this.image,
    required this.client,
    required this.onImageStateChanged,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final flags = <String>[];
    if (image.bootable) {
      flags.add("bootable");
    }
    if (image.pending) {
      flags.add("pending");
    }
    if (image.confirmed) {
      flags.add("confirmed");
    }
    if (image.active) {
      flags.add("active");
    }
    if (image.permanent) {
      flags.add("permanent");
    }
    Widget? trailing;
    if (image.active && !image.confirmed) {
      trailing = TextButton(
        child: const Text("CONFIRM"),
        onPressed: () async {
          onImageStateChanged(await client.confirmImageState(_DeviceScreenState.timeout));
        },
      );
    } else if (!image.active && !image.pending) {
      trailing = TextButton(
        child: const Text("TEST"),
        onPressed: () async {
          onImageStateChanged(await client.setPendingImage(image.hash, false, _DeviceScreenState.timeout));
        },
      );
    }
    return Card(
      child: ListTile(
        title: Text(image.version),
        subtitle: Text(flags.join(", ")),
        trailing: trailing,
      ),
    );
  }
}
