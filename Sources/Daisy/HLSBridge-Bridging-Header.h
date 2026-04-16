#ifndef HLSBridge_h
#define HLSBridge_h

#include <stdint.h>

// 1. Updated callback signature to include video duration in seconds
typedef void (*ProgressCallback)(int done, int total, int64_t bytes, double speed_bps, double downloaded_seconds, double total_seconds);

// 2. Define the main function exported by your dylib
int download_hls(const char* m3u8_url, const char* output_mp4, const char* ffmpeg_path, const char* temp_dir, ProgressCallback progress_cb, volatile int* cancel_flag);

#endif /* HLSBridge_h */
