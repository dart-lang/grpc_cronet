// Copyright 2022 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef COMPONENTS_CRONET_NATIVE_BIDIRECTIONAL_STREAM_ENGINE_H_
#define COMPONENTS_CRONET_NATIVE_BIDIRECTIONAL_STREAM_ENGINE_H_

#if defined(WIN32)
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

#include "bidirectional_stream_c.h"

EXPORT stream_engine* bidirectional_stream_engine_create(
    bool enable_quic,
    const char* quic_user_agent_id,
    bool enable_spdy,
    bool enable_brotli,
    const char* accept_language,
    const char* user_agent);
EXPORT void bidirectional_stream_engine_destroy(stream_engine* s_engine);

#ifdef __cplusplus
}
#endif

#endif  // COMPONENTS_CRONET_NATIVE_BIDIRECTIONAL_STREAM_ENGINE_H_