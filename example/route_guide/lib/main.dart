import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math' show Random;

import 'package:grpc/grpc.dart';
import 'package:grpc/grpc_connection_interface.dart';
import 'package:grpc_cronet/grpc_cronet.dart' as grpc_cronet;
import 'package:flutter/services.dart' show rootBundle;

import 'generated/route_guide.pbgrpc.dart';

const coordFactor = 1e7;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  MyAppState createState() => MyAppState();
}

class MyAppState extends State<MyApp> {
  late Client client;
  String log = "";

  @override
  void initState() {
    super.initState();
    client = Client(rootBundle, this);
    client.run();
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
                Text(
                  log,
                  style: textStyle,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void updateLog(String s) {
    setState(() {
      log += "$s\n";
    });
  }
}

class Client {
  late RouteGuideClient stub;
  final featuresDbCompleter = Completer<List<Feature>>();
  late List<Feature> featuresDb;
  late List<int> privateCertificate;

  final MyAppState state;

  printToWindow(s) {
    state.updateLog(s);
  }

  Client(rootBundle, this.state) {
    rootBundle
        .load('packages/route_guide/assets/data/private.crt')
        .then((bytes) {
      privateCertificate = Uint8List.view(bytes.buffer);
      rootBundle
          .load('packages/route_guide/assets/data/route_guide_db.json')
          .then((dbData) {
        String sData = utf8.decode(Uint8List.view(dbData.buffer));
        final List db = jsonDecode(sData);
        featuresDbCompleter.complete(db.map((entry) {
          final location = Point()
            ..latitude = entry['location']['latitude']
            ..longitude = entry['location']['longitude'];
          return Feature()
            ..name = entry['name']
            ..location = location;
        }).toList());
      });
    });
  }

  Future<String> run() async {
    try {
      featuresDb = await featuresDbCompleter.future;
      final channel = grpc_cronet.CronetGrpcClientChannel(
        'localhost',
        port: 8080,
        trustedCertificate: privateCertificate,
      );
      stub = RouteGuideClient(channel,
          options: CallOptions(timeout: const Duration(seconds: 30)));

      // Run all of the demos in order.
      try {
        await runGetFeature();
        await runListFeatures();
        await runRecordRoute();
        await runRouteChat();
      } catch (e) {
        printToWindow('Caught error: $e');
      }
      await channel.shutdown();
      return "All done!";
    } catch (e, st) {
      printToWindow('Got $e, $st');
      rethrow;
    }
  }

  void printFeature(Feature feature) {
    final latitude = feature.location.latitude;
    final longitude = feature.location.longitude;
    final name = feature.name.isEmpty
        ? 'no feature'
        : 'feature called "${feature.name}"';
    printToWindow(
        'Found $name at ${latitude / coordFactor}, ${longitude / coordFactor}');
  }

  /// Run the getFeature demo. Calls getFeature with a point known to have a
  /// feature and a point known not to have a feature.
  Future<void> runGetFeature() async {
    final point1 = Point()
      ..latitude = 409146138
      ..longitude = -746188906;
    final point2 = Point()
      ..latitude = 0
      ..longitude = 0;

    printFeature(await stub.getFeature(point1));
    printFeature(await stub.getFeature(point2));
  }

  /// Run the listFeatures demo. Calls listFeatures with a rectangle containing
  /// all of the features in the pre-generated database. Prints each response as
  /// it comes in.
  Future<void> runListFeatures() async {
    final lo = Point()
      ..latitude = 400000000
      ..longitude = -750000000;
    final hi = Point()
      ..latitude = 420000000
      ..longitude = -730000000;
    final rect = Rectangle()
      ..lo = lo
      ..hi = hi;

    printToWindow('Looking for features between 40, -75 and 42, -73');
    await for (var feature in stub.listFeatures(rect)) {
      printFeature(feature);
    }
  }

  /// Run the recordRoute demo. Sends several randomly chosen points from the
  /// pre-generated feature database with a variable delay in between. Prints
  /// the statistics when they are sent from the server.
  Future<void> runRecordRoute() async {
    Stream<Point> generateRoute(int count) async* {
      final random = Random();

      for (var i = 0; i < count; i++) {
        final point = featuresDb[random.nextInt(featuresDb.length)].location;
        printToWindow(
            'Visiting point ${point.latitude / coordFactor}, ${point.longitude / coordFactor}');
        yield point;
        await Future.delayed(Duration(milliseconds: 200 + random.nextInt(100)));
      }
    }

    final summary = await stub.recordRoute(generateRoute(10));
    printToWindow('Finished trip with ${summary.pointCount} points');
    printToWindow('Passed ${summary.featureCount} features');
    printToWindow('Travelled ${summary.distance} meters');
    printToWindow('It took ${summary.elapsedTime} seconds');
  }

  /// Run the routeChat demo. Send some chat messages, and print any chat
  /// messages that are sent from the server.
  Future<void> runRouteChat() async {
    RouteNote createNote(String message, int latitude, int longitude) {
      final location = Point()
        ..latitude = latitude
        ..longitude = longitude;
      return RouteNote()
        ..message = message
        ..location = location;
    }

    final notes = <RouteNote>[
      createNote('First message', 0, 0),
      createNote('Second message', 0, 1),
      createNote('Third message', 1, 0),
      createNote('Fourth message', 0, 0),
    ];

    Stream<RouteNote> outgoingNotes() async* {
      for (final note in notes) {
        // Short delay to simulate some other interaction.
        await Future.delayed(const Duration(milliseconds: 10));
        printToWindow(
            'Sending message ${note.message} at ${note.location.latitude}, '
            '${note.location.longitude}');
        yield note;
      }
    }

    final call = stub.routeChat(outgoingNotes());
    await for (var note in call) {
      printToWindow(
          'Got message ${note.message} at ${note.location.latitude}, ${note.location.longitude}');
    }
  }
}
