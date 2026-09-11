//
//  AbrBitrateHelpers.h
//  Moonlight
//

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

NS_ASSUME_NONNULL_BEGIN

// Default soft hold after a constrained/expensive path observation (seconds).
FOUNDATION_EXPORT const CFTimeInterval MLAbrPathHintHoldDuration;

FOUNDATION_EXPORT NSInteger MLClampBitrate(NSInteger candidate, NSInteger ceiling, NSInteger floor);
FOUNDATION_EXPORT NSInteger MLNextAbrBitrate(NSInteger current,
                                             NSInteger ceiling,
                                             NSInteger floor,
                                             float dropRatePercent,
                                             uint32_t rttVarianceMs,
                                             float fecRepairRatePercent,
                                             float queueLatencyMs,
                                             BOOL connectionPoor);

// Path constrained/expensive is a soft hint only: never forces a cut by itself.
// When YES, suppresses upward bitrate bumps from an otherwise healthy decision.
// Prefer MLAbrApplyPathHintEx so the suppress window expires after holdDuration.
FOUNDATION_EXPORT NSInteger MLAbrApplyPathHint(NSInteger nextKbps,
                                               NSInteger currentKbps,
                                               BOOL pathConstrained);

// Soft path hold: while constrained, refresh *holdUntil = now + holdDuration.
// After constrained clears, keep suppressing up-ramps until now >= *holdUntil.
// *holdActive (optional) mirrors whether up-ramps are currently suppressed.
FOUNDATION_EXPORT NSInteger MLAbrApplyPathHintEx(NSInteger nextKbps,
                                                 NSInteger currentKbps,
                                                 BOOL pathConstrained,
                                                 BOOL * _Nullable holdActive,
                                                 CFTimeInterval *holdUntil,
                                                 CFTimeInterval now,
                                                 CFTimeInterval holdDuration);

// Pressure follows accepted cuts / hard poor, not path hints alone.
FOUNDATION_EXPORT BOOL MLAbrWantsNetworkPressure(BOOL wantsCut, BOOL connectionPoor);

// networkDroppedFrames / totalFrames as a percent (0-100). totalFrames <= 0 -> 0.
FOUNDATION_EXPORT float MLDropRatePercent(int networkDroppedFrames, int totalFrames);

// recoveredFrames / totalFrames as a percent (0-100). totalFrames == 0 -> 0.
FOUNDATION_EXPORT float MLFecRepairRatePercent(uint32_t fecRecoveredFrames, uint32_t totalFrames);

// Average client queue wait in ms. framesWithClientQueueLatency <= 0 -> 0.
FOUNDATION_EXPORT float MLAvgQueueLatencyMs(uint64_t totalClientQueueLatencyMs, int framesWithClientQueueLatency);

// Wi-Fi starts at 80% of ceiling (clamped to floor); otherwise start at ceiling.
FOUNDATION_EXPORT NSInteger MLAbrInitialKbps(NSInteger ceiling, NSInteger floor, BOOL isWiFi);

NS_ASSUME_NONNULL_END
