// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#include "grpc_cronet.h"

// // A very short-lived native function.
// //
// // For very short-lived functions, it is fine to call them on the main isolate.
// // They will block the Dart execution while running the native function, so
// // only do this for native functions which are guaranteed to be short-lived.
// FFI_PLUGIN_EXPORT intptr_t sum(intptr_t a, intptr_t b) { return a + b; }

// // A longer-lived native function, which occupies the thread calling it.
// //
// // Do not call these kind of native functions in the main isolate. They will
// // block Dart execution. This will cause dropped frames in Flutter applications.
// // Instead, call these native functions on a separate isolate.
// FFI_PLUGIN_EXPORT intptr_t sum_long_running(intptr_t a, intptr_t b) {
//   // Simulate work.
// #if _WIN32
//   Sleep(5000);
// #else
//   usleep(5000 * 1000);
// #endif
//   return a + b;
// }

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef ANDROID
#include <android/log.h>
#endif

#include "third_party/grpc_support/bidirectional_stream_c.h"
#include "third_party/cronet/native/bidirectional_stream_engine.h"

void log(const char* format, ...) {
  va_list args;
  va_start(args, format);
#ifdef ANDROID
    __android_log_vprint(ANDROID_LOG_INFO, "DartVM", format, args);
#else
    vfprintf(stderr, format, args);
#endif
  va_end(args);
}

intptr_t InitDartApiDL(void *data) {
  return Dart_InitializeApiDL(data);
}

const int read_buffer_size = 1024;
char read_buffer[read_buffer_size];

static void DispatchCallback(const char *methodname, Dart_Port dart_port,
                      Dart_CObject args) {
  Dart_CObject c_method_name;
  c_method_name.type = Dart_CObject_kString;
  c_method_name.value.as_string = const_cast<char*>(methodname);

  Dart_CObject *c_request_arr[] = {&c_method_name, &args};
  Dart_CObject c_request;

  c_request.type = Dart_CObject_kArray;
  c_request.value.as_array.values = c_request_arr;
  c_request.value.as_array.length =
      sizeof(c_request_arr) / sizeof(c_request_arr[0]);

  log("bicronet_grpc c++ DispatchCallback(%s) sendPort:%lld args count:%ld\n",
      methodname, dart_port, c_request.value.as_array.length);

  Dart_PostCObject_DL(dart_port, &c_request);
}

static void FreeFinalizer(void *, void *value) { free(value); }

// Builds the arguments to pass to the Dart side as a parameter to the
// callbacks. [num] is the number of arguments to be passed and rest are the
// arguments.
static Dart_CObject CallbackArgBuilder(int num, ...) {
  Dart_CObject c_request_data;
  va_list valist;
  va_start(valist, num);
  void *request_buffer = malloc(sizeof(uint64_t) * num);
  uint64_t *buf = reinterpret_cast<uint64_t *>(request_buffer);

  // uintptr_r will get implicitly casted to uint64_t. So, when the code is
  // executed in 32 bit mode, the upper 32 bit of buf[i] will be 0 extended
  // automatically. This is required because, on the Dart side these addresses
  // are viewed as 64 bit integers.
  for (int i = 0; i < num; i++) {
    buf[i] = va_arg(valist, uintptr_t);
  }

  c_request_data.type = Dart_CObject_kExternalTypedData;
  c_request_data.value.as_external_typed_data.type = Dart_TypedData_kUint8;
  c_request_data.value.as_external_typed_data.length = sizeof(uint64_t) * num;
  c_request_data.value.as_external_typed_data.data =
      static_cast<uint8_t *>(request_buffer);
  c_request_data.value.as_external_typed_data.peer = request_buffer;
  c_request_data.value.as_external_typed_data.callback = FreeFinalizer;

  va_end(valist);

  return c_request_data;
}

Dart_Port get_port_from_stream(bidirectional_stream* stream) {
  assert(stream->annotation != nullptr);
  return *static_cast<Dart_Port*>(stream->annotation);
}

void reset_port(bidirectional_stream* stream) {
  free(stream->annotation);
  stream->annotation = nullptr;
}

static void on_stream_ready(bidirectional_stream* stream) {
  log("bicronet_grpc c++ on_stream_ready %p\n", stream);
  DispatchCallback("on_stream_ready",
                   get_port_from_stream(stream),
                   CallbackArgBuilder(0));
}

static void on_response_headers_received(
    bidirectional_stream* stream,
    const bidirectional_stream_header_array* headers,
    const char* negotiated_protocol) {
  log("bicronet_grpc c++ on_response_headers_received %p negotiated_protocol:%s\n",
      stream, negotiated_protocol);
  for (size_t i = 0; i < headers->count; ++i) {
    log("bicronet_grpc c++ header[%lu]: %s %s\n", i, headers->headers[i].key,
            headers->headers[i].value);
  }

  bidirectional_stream_header_array* headers_copy =
      static_cast<bidirectional_stream_header_array*>(
          malloc(sizeof(bidirectional_stream_header_array)));
  headers_copy->count = headers->count;
  headers_copy->capacity = headers->capacity;
  headers_copy->headers =
      static_cast<bidirectional_stream_header*>(
          malloc(sizeof(bidirectional_stream_header) * headers_copy->count));
  bidirectional_stream_header* p_from = headers->headers;
  bidirectional_stream_header* p_to = headers_copy->headers;
  for (size_t i = 0; i < headers_copy->count; i++) {
    p_to->key = strdup(p_from->key);
    p_to->value = strdup(p_from->value);
    log("bicronet_grpc c++ Copied %s:%s\n", p_to->key, p_to->value);
    p_to++;
    p_from++;
  }

  DispatchCallback("on_response_headers_received",
                   get_port_from_stream(stream),
                   CallbackArgBuilder(3, stream, headers_copy, negotiated_protocol));
  // bidirectional_stream_read(stream, read_buffer, read_buffer_size);
  // log("bicronet_grpc c++ stream_read: %p\n", read_buffer);
}

static void on_read_completed(bidirectional_stream* stream,
                          char* data,
                          int bytes_read) {
  log("bicronet_grpc c++ on_read_completed %p data: %p bytes_read:%d\n", stream, data, bytes_read);
  DispatchCallback("on_read_completed",
                   get_port_from_stream(stream),
                   CallbackArgBuilder(3, stream, data, bytes_read));
}

static void on_write_completed(bidirectional_stream* stream, const char* data) {
  log("bicronet_grpc c++ on_write_completed %p data %p\n", stream, data);
  DispatchCallback("on_write_completed",
                   get_port_from_stream(stream),
                   CallbackArgBuilder(1, data));
}

static void on_response_trailers_received(
    bidirectional_stream* stream,
    const bidirectional_stream_header_array* trailers) {
  log("bicronet_grpc c++ on_response_trailers_received %p count:%d\n",
      stream, trailers->count);
  // for (size_t i = 0; i < trailers->count; ++i) {
  //   log("bicronet_grpc c++ trailer[%lu]: %s %s\n", i, trailers->headers[i].key,
  //           trailers->headers[i].value);
  // }

  bidirectional_stream_header_array* trailers_copy =
      static_cast<bidirectional_stream_header_array*>(
          malloc(sizeof(bidirectional_stream_header_array)));
  trailers_copy->count = trailers->count;
  trailers_copy->capacity = trailers->capacity;
  trailers_copy->headers =
      static_cast<bidirectional_stream_header*>(
          malloc(sizeof(bidirectional_stream_header) * trailers_copy->count));
  bidirectional_stream_header* p_from = trailers->headers;
  bidirectional_stream_header* p_to = trailers_copy->headers;
  for (int i = 0; i < trailers_copy->count; i++) {
    p_to->key = strdup(p_from->key);
    p_to->value = strdup(p_from->value);
    log("bicronet_grpc c++ trailer %d Copied %s:%s\n", i, p_to->key, p_to->value);
    p_to++;
    p_from++;
  }

  DispatchCallback("on_response_trailers_received",
                   get_port_from_stream(stream),
                   CallbackArgBuilder(1, trailers_copy));
}

static void on_succeded(bidirectional_stream* stream) {
  log("bicronet_grpc c++ on_succeded %p\n", stream);
  DispatchCallback("on_succeeded",
                   get_port_from_stream(stream),
                   CallbackArgBuilder(0));
  // don't expect any more callbacks
  reset_port(stream);
}

static void on_failed(bidirectional_stream* stream, int net_error) {
  log("bicronet_grpc c++ on_failed %p net_error:%d\n", stream, net_error);
  DispatchCallback("on_failed",
                   get_port_from_stream(stream),
                   CallbackArgBuilder(1, net_error));
  // don't expect any more callbacks
  reset_port(stream);
}

static void on_canceled(bidirectional_stream* stream) {
  log("bicronet_grpc c++ on_canceled %p\n", stream);
  DispatchCallback("on_canceled",
                   get_port_from_stream(stream),
                   CallbackArgBuilder(0));
  // don't expect any more callbacks
  reset_port(stream);
}

//  stream_engine* engine = bidirectional_stream_engine_create(user_agent);

bidirectional_stream* CreateStreamWithCallbackPort(stream_engine* engine,
                                                   Dart_Port send_port) {
  // TODO(): free when stream no longer need to communicate with dart
  Dart_Port* annotation = static_cast<Dart_Port*>(malloc(sizeof(Dart_Port)));
  *annotation = send_port;
  log("bicronet_grpc c++ CreateStreamWithCallbackPort engine %p, send_port: %llx\n",
      engine, send_port);
  static struct bidirectional_stream_callback callbacks = {
    on_stream_ready,
    on_response_headers_received,
    on_read_completed,
    on_write_completed,
    on_response_trailers_received,
    on_succeded,
    on_failed,
    on_canceled
  };

  return bidirectional_stream_create(engine, annotation, &callbacks);
}

