//
//  AbrBitrateHelpers.h
//  Moonlight
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSInteger MLClampBitrate(NSInteger candidate, NSInteger ceiling, NSInteger floor);
FOUNDATION_EXPORT NSInteger MLNextAbrBitrate(NSInteger current,
                                             NSInteger ceiling,
                                             NSInteger floor,
                                             float dropRatePercent,
                                             uint32_t rttVarianceMs,
                                             float fecRepairRatePercent,
                                             float queueLatencyMs,
                                             BOOL connectionPoor);

// networkDroppedFrames / totalFrames as a percent (0-100). totalFrames <= 0 -> 0.
FOUNDATION_EXPORT float MLDropRatePercent(int networkDroppedFrames, int totalFrames);

// recoveredFrames / totalFrames as a percent (0-100). totalFrames == 0 -> 0.
FOUNDATION_EXPORT float MLFecRepairRatePercent(uint32_t fecRecoveredFrames, uint32_t totalFrames);

// Average client queue wait in ms. framesWithClientQueueLatency <= 0 -> 0.
FOUNDATION_EXPORT float MLAvgQueueLatencyMs(uint64_t totalClientQueueLatencyMs, int framesWithClientQueueLatency);

// Wi-Fi starts at 80% of ceiling (clamped to floor); otherwise start at ceiling.
FOUNDATION_EXPORT NSInteger MLAbrInitialKbps(NSInteger ceiling, NSInteger floor, BOOL isWiFi);

NS_ASSUME_NONNULL_END
