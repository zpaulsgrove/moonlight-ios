//
//  StatsOverlayFormatting.h
//  Moonlight
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Persisted in Core Data as Settings.statsOverlayLevel, so the raw values are stable.
typedef NS_ENUM(NSInteger, MLStatsOverlayLevel) {
    MLStatsOverlayLevelOff = 0,
    MLStatsOverlayLevelLite = 1,
    MLStatsOverlayLevelFull = 2,
};

typedef struct {
    int width;
    int height;
    int videoFormat;
    BOOL hdrActive;
    float framesPerSecond;
    float dropRatePercent;
    BOOL hasRttEstimate;
    uint32_t rttMs;
    uint32_t rttVarianceMs;
    BOOL hasHostProcessingLatency;
    float averageHostProcessingLatencyMs;
    BOOL hasClientQueueLatency;
    float averageClientQueueLatencyMs;
} MLStatsOverlaySample;

// "1080p" for a known height, "?" when the dimensions are not usable yet.
FOUNDATION_EXPORT NSString* MLStatsResolutionLabel(int width, int height);

// Short enough for a single line: "HEVC", "AV1 HDR", "H.264".
// videoFormat is a VIDEO_FORMAT_* value from Limelight.h.
FOUNDATION_EXPORT NSString* MLStatsShortCodecName(int videoFormat, BOOL hdrActive);

// 0 when the stats window has no duration, so a partial window cannot produce inf.
FOUNDATION_EXPORT float MLStatsFramesPerSecond(int totalFrames, float intervalSeconds);

// Single top-pinned line, for example:
// 1080p HEVC HDR · 59.9 fps · drop 0.08% · net 8 ms ±2 · host 3.1 ms · queue 0.2 ms
FOUNDATION_EXPORT NSString* MLStatsOverlayLiteLine(MLStatsOverlaySample sample);

NS_ASSUME_NONNULL_END
