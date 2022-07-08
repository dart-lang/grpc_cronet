import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'dart:async';

import 'package:grpc/grpc.dart';
import 'package:grpc/grpc_connection_interface.dart';
import 'package:grpc_cronet/grpc_cronet.dart' as grpc_cronet;
import 'package:flutter/services.dart' show rootBundle;

import 'generated/helloworld.pbgrpc.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  _MyAppState createState() => _MyAppState();
}

class GreeterService extends GreeterServiceBase {
  @override
  Future<HelloReply> sayHello(ServiceCall call, HelloRequest request) async {
    return HelloReply()..message = 'Hello, ${request.name}!'; 
  } 
} 

Future<String> connectAndSayHello(channel) async {
  final stub = GreeterClient(channel);
  
  try {  
    final response = await stub.sayHello( 
      HelloRequest()..name = 'world', 
      options: CallOptions(compression: const GzipCodec()),
    ); 
    print('Greeter client received: ${response.message}');
    return response.message;
  } catch (e) {  
    print('Caught error: $e'); 
    return e.toString();
  } 
//  return await channel.shutdown();
}

class SecurityContextChannelCredentials extends ChannelCredentials {
  final SecurityContext _securityContext;

  SecurityContextChannelCredentials(SecurityContext securityContext,
      {String? authority, BadCertificateHandler? onBadCertificate})
      : _securityContext = securityContext,
        super.secure(authority: authority, onBadCertificate: onBadCertificate);
  @override
  SecurityContext get securityContext => _securityContext;

  static SecurityContext baseSecurityContext() {
    return createSecurityContext(false);
  }
}

class SecurityContextServerCredentials extends ServerTlsCredentials {
  final SecurityContext _securityContext;

  SecurityContextServerCredentials(SecurityContext securityContext)
      : _securityContext = securityContext,
        super();
  @override
  SecurityContext get securityContext => _securityContext;
  static SecurityContext baseSecurityContext() {
    return createSecurityContext(true);
  }
}

class _MyAppState extends State<MyApp> {
  Completer<ClientChannelBase> channel = Completer<ClientChannelBase>();

  @override
  void initState() {
    super.initState();

    final server = Server(
      [GreeterService()],
      const <Interceptor>[],
      CodecRegistry(codecs: const [GzipCodec(), IdentityCodec()]),
    );
    final serverContext = SecurityContextServerCredentials.baseSecurityContext();
    final clientContext =
        SecurityContextChannelCredentials.baseSecurityContext();
    rootBundle.load('packages/grpc_cronet_example/assets/data/private.crt').then((bytes) {
      List<int> list = Uint8List.view(bytes.buffer);
      serverContext.useCertificateChainBytes(list);
      serverContext.setTrustedCertificatesBytes(list);
      clientContext.useCertificateChainBytes(list);
      clientContext.setTrustedCertificatesBytes(list);
      rootBundle.load('packages/grpc_cronet_example/assets/data/private.key').then((bytes) {
        List<int> list = Uint8List.view(bytes.buffer);
        serverContext.usePrivateKeyBytes(list);
        clientContext.usePrivateKeyBytes(list);
        final ServerCredentials serverCredentials =
            SecurityContextServerCredentials(serverContext);
        server.serve(port: 0, security: serverCredentials).then((_) {
          print('Server listening on port ${server.port}...');

          final channelCredentials = SecurityContextChannelCredentials(clientContext);
          channel.complete(grpc_cronet.CronetGrpcClientChannel(
            'localhost',
            port: server.port!,
            options: ChannelOptions(
              credentials: channelCredentials, // ChannelCredentials.insecure(), //
              codecRegistry:
                  CodecRegistry(codecs: const [GzipCodec(), IdentityCodec()]),
            ),
          ));
        });
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    const textStyle = TextStyle(fontSize: 25);
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Native Packages'),
        ),
        body: SingleChildScrollView(
          child: Container(
            padding: const EdgeInsets.all(10),
            child: Column(
              children: [
                FutureBuilder<String>(
                  future: channel.future.then((value) => connectAndSayHello(value)),
                  builder: (BuildContext context, AsyncSnapshot<String> value) {
                    final displayValue =
                        (value.hasData) ? value.data : 'loading';
                    return Text(
                      displayValue ?? "<null>",
                      style: textStyle,
                      textAlign: TextAlign.center,
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
