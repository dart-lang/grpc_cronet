library grpc_cronet;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:http2/http2.dart' as http2;
import 'package:grpc/grpc_connection_interface.dart' as grpc;

import 'third_party/cronet/generated_bindings.dart' as cronet;
import 'third_party/cronet_dart/generated_bindings.dart';
import 'third_party/grpc_support/generated_bindings.dart' as grpc_support;

T throwIfNullptr<T>(T value) {
  if (value == ffi.nullptr) {
    print('bicronet_grpc: throwIfNullptr failed at ${StackTrace.current}');
    throw Exception("Unexpected cronet failure: got null");
  }
  return value;
}

void throwIfFailed<T>(T result) {
  if (result != cronet.Cronet_RESULT.Cronet_RESULT_SUCCESS) {
    print('bicronet_grpc: throwIfFailed failed at ${StackTrace.current}');
    throw Exception("Unexpected cronet failure: $result");
  }
}

ffi.DynamicLibrary openDynamicLibrary(String libname) {
  if (Platform.isMacOS || Platform.isIOS) {
    return ffi.DynamicLibrary.open('$libname.framework/$libname');
  }
  if (Platform.isAndroid || Platform.isLinux) {
    return ffi.DynamicLibrary.open('lib$libname.so');
  }
  if (Platform.isWindows) {
    return ffi.DynamicLibrary.open('$libname.dll');
  }
  throw UnsupportedError('Unknown platform: ${Platform.operatingSystem}');
}

// Owns ffi Cronet engine
class BicronetEngine {
  BicronetEngine(this._options) {
    ffilibGrpcSupport = grpc_support.GrpcSupport(openDynamicLibrary(
        'cronet.104.0.5108.0'));
    ffilibCronetDart = CronetDart(openDynamicLibrary('grpc_cronet'));
    ffilibCronetDart.InitDartApiDL(ffi.NativeApi.initializeApiDLData);

    streamEngine = ffilibGrpcSupport.bidirectional_stream_engine_create(
      /*enable_quic=*/true,
      /*quic_user_agent_id=*/"my_quic_user_agent_id".toNativeUtf8().cast<ffi.Char>(),
      /*enable_spdy=*/true,
      /*enable_brotli=*/true,
      /*accept_language=*/"en-us".toNativeUtf8().cast<ffi.Char>(),
      _options.userAgent.toNativeUtf8().cast<ffi.Char>());
  }

  BicronetEngine.fromAddress(int cronetEngineAddress, this._options) {
    final extension = Platform.isMacOS ? "dylib" : "so";
    ffilibGrpcSupport = grpc_support.GrpcSupport(ffi.DynamicLibrary.open(
        'libcronet.103.0.5060.42.${extension}'));
        // 'libcronet.104.0.5108.0.${extension}'));
    ffilibCronetDart = CronetDart(ffi.DynamicLibrary.open(
        'libcronet_dart.${extension}'));
    ffilibCronetDart.InitDartApiDL(ffi.NativeApi.initializeApiDLData);

    streamEngine = ffi.Pointer<grpc_support.stream_engine>.fromAddress(
        cronetEngineAddress);
  }

  CronetGrpcTransportStream startBidirectionalStream(Uri uri,
      {
        required Map<String, String> metadata,
        String? grpcAcceptEncodings,
        grpc.Codec? compressionCodec,
        Duration? timeout,
      }) {

    final headers =<String,String>{
        'content-type': 'application/grpc',
        'te': 'trailers',
        'user-agent': _options.userAgent,
        if (timeout != null)
          'grpc-timeout': grpc.toTimeoutString(timeout),
        ...metadata,
        if (grpcAcceptEncodings != null)
          'grpc-accept-encoding': grpcAcceptEncodings,
        if (compressionCodec != null)
          'grpc-encoding': compressionCodec.encodingName,
      };

    return CronetGrpcTransportStream(uri, headers, _options.codecRegistry,
        compressionCodec, this);
  }

  void shutdown() {
    ffilibGrpcSupport.bidirectional_stream_engine_destroy(streamEngine);
  }

  final grpc.ChannelOptions _options;

  late final grpc_support.GrpcSupport ffilibGrpcSupport;
  late final CronetDart ffilibCronetDart;
  late final ffi.Pointer<grpc_support.stream_engine> streamEngine;
}

// Owns ffi Cronet bidirectional stream
class CronetGrpcTransportStream implements grpc.GrpcTransportStream {
  final incomingStreamController = StreamController<http2.StreamMessage>();
  final outgoingStreamController = StreamController<List<int>>();

  final ffilibGrpcSupport;

  late final StreamSubscription<List<int>> outgoingSubscription;
  Completer<bool> isWriteStreamReady = Completer<bool>();

  final grpc.CodecRegistry? _codecRegistry;
  final grpc.Codec? _compressionCodec;

  void outgoingHandler(List<int> data) async {
    outgoingSubscription.pause();
    print('bicronet_grpc: outgoingStream waiting for isWriteStreamReady: ${isWriteStreamReady.isCompleted}');
    await isWriteStreamReady.future;
    print('bicronet_grpc: got isWriteStreamReady');
    isWriteStreamReady = Completer<bool>();
    outgoingSubscription.resume();
    final framedData = grpc.frame(data, _compressionCodec);
    print('bicronet_grpc: data: $data -> framedData: $framedData');

    ffi.Pointer<ffi.Char> buffer = calloc(framedData.length);
    print('bicronet_grpc: sending buffer: $buffer');
    try {
      buffer.cast<ffi.Int8>().asTypedList(framedData.length).setAll(0, framedData);
      
      ffilibGrpcSupport.bidirectional_stream_write(
        stream.cast<grpc_support.bidirectional_stream>(),
        buffer,
        framedData.length,
        /*end_of_stream=*/false
      );
    } catch(e) {
      // on a success, buffer will be freed in on_write_completed
      calloc.free(buffer);
      rethrow;
    }
  }

  void onDoneHandler() async {
    print('bicronet_grpc: onDone waiting for isWriteStreamReady: ${isWriteStreamReady.isCompleted}');
    outgoingSubscription.pause();
    await isWriteStreamReady.future;
    print('bicronet_grpc: got onDone isWriteStreamReady');
    isWriteStreamReady = Completer<bool>();
    outgoingSubscription.resume();
    print('bicronet_grpc: sending onDone');
    ffi.Pointer<ffi.Char> buffer = calloc(0);
    print('bicronet_grpc: sending buffer: $buffer');
    try {
      ffilibGrpcSupport.bidirectional_stream_write(
        stream.cast<grpc_support.bidirectional_stream>(),
        buffer,
        0,
        /*end_of_stream=*/true
      );
    } catch(e) {
      calloc.free(buffer);
      rethrow;
    }
  }

  List<http2.Header> receiveHeaders(
      ffi.Pointer<grpc_support.bidirectional_stream_header_array> array) {
    final array_headers = array.ref.headers.cast<
        grpc_support.bidirectional_stream_header>();
    print('bicronet_grpc: headers count: ${array.ref.count}');
    final count = array.ref.count;
    final http2_headers = <http2.Header>[];
    for (int i = 0; i < count; i++) {
      final header = array_headers.elementAt(i).cast<grpc_support.bidirectional_stream_header>();
      final p_key = header.ref.key;
      final p_value = header.ref.value;
      final key = p_key.cast<Utf8>().toDartString();
      final value = p_value.cast<Utf8>().toDartString();
      if (key.isNotEmpty) {
        http2_headers.add(http2.Header(ascii.encode(key), utf8.encode(value)));
      }
      print('bicronet_grpc:   header[$i]: $key->$value');
      calloc.free(p_key);
      calloc.free(p_value);
    }
    calloc.free(array_headers);
    calloc.free(array);
    return http2_headers;    
  }

  CronetGrpcTransportStream(Uri uri, Map<String, String> headers,
    this._codecRegistry, this._compressionCodec, this.engine):
    ffilibGrpcSupport = engine.ffilibGrpcSupport {
    const int read_buffer_size = 1024;
    ffi.Pointer<ffi.Char> read_buffer = calloc(read_buffer_size);

    // trailers are collected to be sent after all reading is done.
    final trailers = <http2.Header>[];

    final receivePort = ReceivePort();
    receivePort.listen(
      (dynamic message) {
        print('bicronet_grpc: dart received via receive port $message');
        final selector = message[0] as String;
        final arguments = message[1].buffer.asUint64List();
        switch (selector) {
          case 'on_stream_ready':
            print('bicronet_grpc: dart got on_stream_ready ${isWriteStreamReady.isCompleted}');
            if (!isWriteStreamReady.isCompleted) {
              isWriteStreamReady.complete(true);
            }
            break;
          case 'on_response_headers_received':
            // (
            //    bidirectional_stream* stream,
            //    const bidirectional_stream_header_array* headers,
            //    const char* negotiated_protocol
            //  )
            print('bicronet_grpc:   negotiated_protocol: ${ffi.Pointer.fromAddress(arguments[2]).cast<Utf8>().toDartString()}');

            final header_array = ffi.Pointer.fromAddress(arguments[1]).cast<grpc_support.bidirectional_stream_header_array>();
            final headers = receiveHeaders(header_array);
            incomingStreamController.add(http2.HeadersStreamMessage(headers));

            engine.ffilibGrpcSupport.bidirectional_stream_read(
                ffi.Pointer.fromAddress(arguments[0]).cast<grpc_support.bidirectional_stream>(),
                read_buffer, read_buffer_size);
            break;
          case 'on_response_trailers_received':
            // (
            //    const bidirectional_stream_header_array* trailers
            // )
            final trailer_array = ffi.Pointer.fromAddress(arguments[0]).cast<grpc_support.bidirectional_stream_header_array>();
            // Delay sending out trailers until on_read_completed
            trailers.addAll(receiveHeaders(trailer_array));
            break;
          case 'on_read_completed':
            // (
            //    bidirectional_stream* stream,
            //    char* data,
            //    int bytes_read
            // )
            final data = ffi.Pointer.fromAddress(arguments[1]);
            final bytesRead = arguments[2];
            print('bicronet_grpc:  data: $data bytes_read: $bytesRead');
            incomingStreamController.add(http2.DataStreamMessage(
                data.cast<ffi.Uint8>().asTypedList(bytesRead)));

            if (trailers.isNotEmpty) {
              print('bicronet_grpc: trailers is not empty: ${trailers.length}');
              incomingStreamController.add(http2.HeadersStreamMessage(
                  List<http2.Header>.from(trailers),
                  endStream: true));
              trailers.clear();
            }

            engine.ffilibGrpcSupport.bidirectional_stream_read(
                ffi.Pointer.fromAddress(arguments[0]).cast<grpc_support.bidirectional_stream>(),
                read_buffer, read_buffer_size);
            break;
          case 'on_write_completed':
            print('bicronet_grpc: dart got on_write_completed buf: ${ffi.Pointer.fromAddress(arguments[0])} ${isWriteStreamReady.isCompleted}');
            calloc.free(ffi.Pointer.fromAddress(arguments[0]));
            if (!isWriteStreamReady.isCompleted) {
              isWriteStreamReady.complete(true);
            }
            break;
          case 'on_succeeded':
            if (trailers.isNotEmpty) {
              print('bicronet_grpc: trailers is not empty: ${trailers.length}');
              incomingStreamController.add(http2.HeadersStreamMessage(
                  List<http2.Header>.from(trailers),
                  endStream: true));
              trailers.clear();
            }
            print('bicronet_grpc: closing receivePort');
            receivePort.close();
            break;
          case 'on_failed':
            receivePort.close();
            break;
          default:
            break;
        }
      },
      onDone: () {
        print('bicronet_grpc: CronetGrpcTransportStream native stream is done');
        calloc.free(read_buffer);
        incomingStreamController.close();
      },
      onError: (error, stackTrace) {
        print('bicronet_grpc: CronetGrpcTransportStream native stream received error: $error $stackTrace');
      }
    );

    String? grpcAcceptEncodings = _codecRegistry?.supportedEncodings;
    stream = engine.ffilibCronetDart.CreateStreamWithCallbackPort(
        engine.streamEngine.cast<stream_engine>(),
        receivePort.sendPort.nativePort);
    print(stream);

    outgoingSubscription = outgoingStreamController.stream.listen(
        outgoingHandler, onDone: onDoneHandler);

    final ffiHeaders = calloc<grpc_support.bidirectional_stream_header>(
        headers.entries.length);
    int i = 0;
    for (MapEntry<String, String> entry in headers.entries) {
      print('bicronet_grpc: ${entry.key}:${entry.value}');
      final ffiHeader = ffiHeaders.elementAt(i++).cast<grpc_support.bidirectional_stream_header>();
      ffiHeader.ref.key = entry.key.toNativeUtf8().cast<ffi.Char>();
      ffiHeader.ref.value = entry.value.toNativeUtf8().cast<ffi.Char>();
    }


    final ffiHeadersArray = calloc<grpc_support.bidirectional_stream_header_array>()
        ..ref.count = headers.entries.length
        ..ref.capacity = headers.entries.length
        ..ref.headers = ffiHeaders;

    final result = ffilibGrpcSupport.bidirectional_stream_start(
      stream.cast<grpc_support.bidirectional_stream>(),
      uri.toString().toNativeUtf8().cast<ffi.Char>(),
      /*priority=*/0,
      "POST".toNativeUtf8().cast<ffi.Char>(),
      ffiHeadersArray,
      /*end_of_stream=*/false);

    print('bicronet_grpc: result=$result');

    calloc.free(ffiHeaders);
    calloc.free(ffiHeadersArray);
  }

  @override
  Stream<grpc.GrpcMessage> get incomingMessages {
    return incomingStreamController.stream
        .transform(grpc.GrpcHttpDecoder())
        .transform(grpc.grpcDecompressor(codecRegistry: _codecRegistry));
  }

  @override
  StreamSink<List<int>> get outgoingMessages {
    return outgoingStreamController.sink;
  }

  @override
  Future<void> terminate() async {

  }

  final BicronetEngine engine;
  late final ffi.Pointer<bidirectional_stream> stream;
}

class CronetGrpcClientConnection implements grpc.ClientConnection {
  CronetGrpcClientConnection(this.host, this.port, this.options) :
    engine = new BicronetEngine(options) {}

  CronetGrpcClientConnection.withEngine(this.engine, this.host,
      this.port, this.options);

  @override
  String get authority => host;
  @override
  String get scheme => options.credentials.isSecure ? 'https' : 'http';

  /// Put [call] on the queue to be dispatched when the connection is ready.
  @override
  void dispatchCall(grpc.ClientCall call) {
    call.onConnectionReady(this);
    print('bicronet_grpc: CronetGrpcClientConnection dispatchCall $call');
  }

  /// Start a request for [path] with [metadata].
  @override
  grpc.GrpcTransportStream makeRequest(String path, Duration? timeout,
      Map<String, String> metadata, grpc.ErrorHandler onRequestFailure,
      {required grpc.CallOptions callOptions}) {
    print('bicronet_grpc: CronetGrpcClientConnection makeRequest $path, metadata: $metadata callOptions: $callOptions');

    return engine.startBidirectionalStream(
        Uri(scheme: scheme, host: authority, path: path, port: port),
        metadata: metadata,
        grpcAcceptEncodings:
          callOptions.metadata['grpc-accept-encoding'] ??
              options.codecRegistry?.supportedEncodings,
        timeout: timeout,
        compressionCodec: callOptions.compression);
  }

  /// Shuts down this connection.
  ///
  /// No further calls may be made on this connection, but existing calls
  /// are allowed to finish.
  @override
  Future<void> shutdown() async {
    print('bicronet_grpc: shutting down this GrpcClientConnection');
    engine.shutdown();
  }

  /// Terminates this connection.
  ///
  /// All open calls are terminated immediately, and no further calls may be
  /// made on this connection.
  @override
  Future<void> terminate() async {
    print('bicronet_grpc: terminating this GrpcClientConnection');
  }

  final String host;
  final int port;
  final grpc.ChannelOptions options;
  final BicronetEngine engine;
}

class CronetGrpcClientChannel extends grpc.ClientChannelBase {
  final BicronetEngine? _engine;
  final String _host;
  final int port;
  final grpc.ChannelOptions options;

  CronetGrpcClientChannel(this._host,
      {this.port = 443, this.options = const grpc.ChannelOptions()})
      : _engine = null, super();

  CronetGrpcClientChannel.withEngine(this._engine, this._host,
      {this.port = 443, this.options = const grpc.ChannelOptions()})
      : super();

  @override
  grpc.ClientConnection createConnection() {
    return _engine != null ?
      CronetGrpcClientConnection.withEngine(_engine!, _host, port, options) :
      CronetGrpcClientConnection(_host, port, options);
  }
}


// import 'dart:async';
// import 'dart:ffi';
// import 'dart:io';
// import 'dart:isolate';

// import 'grpc_cronet_bindings_generated.dart';

// /// A very short-lived native function.
// ///
// /// For very short-lived functions, it is fine to call them on the main isolate.
// /// They will block the Dart execution while running the native function, so
// /// only do this for native functions which are guaranteed to be short-lived.
// int sum(int a, int b) => _bindings.sum(a, b);

// /// A longer lived native function, which occupies the thread calling it.
// ///
// /// Do not call these kind of native functions in the main isolate. They will
// /// block Dart execution. This will cause dropped frames in Flutter applications.
// /// Instead, call these native functions on a separate isolate.
// ///
// /// Modify this to suit your own use case. Example use cases:
// ///
// /// 1. Reuse a single isolate for various different kinds of requests.
// /// 2. Use multiple helper isolates for parallel execution.
// Future<int> sumAsync(int a, int b) async {
//   final SendPort helperIsolateSendPort = await _helperIsolateSendPort;
//   final int requestId = _nextSumRequestId++;
//   final _SumRequest request = _SumRequest(requestId, a, b);
//   final Completer<int> completer = Completer<int>();
//   _sumRequests[requestId] = completer;
//   helperIsolateSendPort.send(request);
//   return completer.future;
// }

// const String _libName = 'grpc_cronet';

// /// The dynamic library in which the symbols for [GrpcCronetBindings] can be found.
// final DynamicLibrary _dylib = () {
//   if (Platform.isMacOS || Platform.isIOS) {
//     return DynamicLibrary.open('$_libName.framework/$_libName');
//   }
//   if (Platform.isAndroid || Platform.isLinux) {
//     return DynamicLibrary.open('lib$_libName.so');
//   }
//   if (Platform.isWindows) {
//     return DynamicLibrary.open('$_libName.dll');
//   }
//   throw UnsupportedError('Unknown platform: ${Platform.operatingSystem}');
// }();

// /// The bindings to the native functions in [_dylib].
// final GrpcCronetBindings _bindings = GrpcCronetBindings(_dylib);


// /// A request to compute `sum`.
// ///
// /// Typically sent from one isolate to another.
// class _SumRequest {
//   final int id;
//   final int a;
//   final int b;

//   const _SumRequest(this.id, this.a, this.b);
// }

// /// A response with the result of `sum`.
// ///
// /// Typically sent from one isolate to another.
// class _SumResponse {
//   final int id;
//   final int result;

//   const _SumResponse(this.id, this.result);
// }

// /// Counter to identify [_SumRequest]s and [_SumResponse]s.
// int _nextSumRequestId = 0;

// /// Mapping from [_SumRequest] `id`s to the completers corresponding to the correct future of the pending request.
// final Map<int, Completer<int>> _sumRequests = <int, Completer<int>>{};

// /// The SendPort belonging to the helper isolate.
// Future<SendPort> _helperIsolateSendPort = () async {
//   // The helper isolate is going to send us back a SendPort, which we want to
//   // wait for.
//   final Completer<SendPort> completer = Completer<SendPort>();

//   // Receive port on the main isolate to receive messages from the helper.
//   // We receive two types of messages:
//   // 1. A port to send messages on.
//   // 2. Responses to requests we sent.
//   final ReceivePort receivePort = ReceivePort()
//     ..listen((dynamic data) {
//       if (data is SendPort) {
//         // The helper isolate sent us the port on which we can sent it requests.
//         completer.complete(data);
//         return;
//       }
//       if (data is _SumResponse) {
//         // The helper isolate sent us a response to a request we sent.
//         final Completer<int> completer = _sumRequests[data.id]!;
//         _sumRequests.remove(data.id);
//         completer.complete(data.result);
//         return;
//       }
//       throw UnsupportedError('Unsupported message type: ${data.runtimeType}');
//     });

//   // Start the helper isolate.
//   await Isolate.spawn((SendPort sendPort) async {
//     final ReceivePort helperReceivePort = ReceivePort()
//       ..listen((dynamic data) {
//         // On the helper isolate listen to requests and respond to them.
//         if (data is _SumRequest) {
//           final int result = _bindings.sum_long_running(data.a, data.b);
//           final _SumResponse response = _SumResponse(data.id, result);
//           sendPort.send(response);
//           return;
//         }
//         throw UnsupportedError('Unsupported message type: ${data.runtimeType}');
//       });

//     // Send the the port to the main isolate on which we can receive requests.
//     sendPort.send(helperReceivePort.sendPort);
//   }, receivePort.sendPort);

//   // Wait until the helper isolate has sent us back the SendPort on which we
//   // can start sending requests.
//   return completer.future;
// }();
