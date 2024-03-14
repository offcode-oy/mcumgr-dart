## 0.0.1

-   Basic support for device firmware upgrades

## 0.0.2

-   Added documentation
-   Added echo command
-   Made the chunkSize parameter of uploadImage optional (defaults to 128)

## 0.0.3

-   Client only subscribes to the input stream once
-   Added close() to Client
-   Added windowSize to uploadImage to send multiple chunks at once (defaults to 3, set to 1 to disable)

## 1.0.0

-   FS calls:
    -   upload
    -   download
-   OS call:
    -   params

## 1.1.0

-   Implement the zip package format
-   Fix upload related issues / bugs
    -   Fix TLV
    -   Add image index into the zip image class
    -   Fix cbor calculation
    -   Add ZIP image extension to the MCU image class

## 1.2.0

-   Implement Log download and metadata decoding related to the log files
