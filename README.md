[![package:grpc_cronet CI](https://github.com/dart-lang/grpc_cronet/actions/workflows/grpc_cronet.yml/badge.svg)](https://github.com/dart-lang/grpc_cronet/actions/workflows/grpc_cronet.yml)
[![pub package](https://img.shields.io/pub/v/grpc_cronet.svg)](https://pub.dev/packages/grpc_cronet)
[![package publisher](https://img.shields.io/pub/publisher/grpc_cronet.svg)](https://pub.dev/packages/grpc_cronet/publisher)

Flutter dart:grpc implementation that uses the Cronet native library.

Uses Chromium Cronet libraries patched in https://chromium-review.googlesource.com/c/chromium/src/+/3761158.

## Performance

As number of concurrent requests increases use of cronet for grpc client shows significant improvements over dart:io one.
This is what example/route_guide [flutter cronet client](example/route_guide/lib/main.dart) vs [dart cli dart:io client](example/route_guide/bin/client.dart) shows:

|number of concurrent requests |dart:io(ms) (less is better)|cronet (ms) (less is better)| speed-up factor
|----|------|-------|------
|100 |   615|    382|  1.61
|500 | 7,947|  2,081|  3.82
|1000| 28,406| 4,703|  6.04
