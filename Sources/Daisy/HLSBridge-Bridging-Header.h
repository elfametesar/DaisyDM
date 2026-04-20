#ifndef HLSBridge_h
#define HLSBridge_h

#include <stdint.h>

// 1. Progress Callback signature must match C++ exactly
typedef void (*ProgressCallback)(int done, int total, int64_t bytes, double speed_bps, double downloaded_seconds, double total_seconds);

// 2. Updated function signature (9 parameters total)
int download_hls(
    const char* m3u8_url,
    const char* output_mp4,
    const char* ffmpeg_path,
    const char* temp_dir,
    const char* user_agent,  // Missing before
    const char* referer,     // Missing before
    const char* cookies,     // Missing before
    ProgressCallback progress_cb,
    volatile int* cancel_flag
);

#endif
