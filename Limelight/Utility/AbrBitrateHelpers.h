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
                                             uint32_t rttVarianceMs);

// networkDroppedFrames / totalFrames as a percent (0-100). totalFrames <= 0 -> 0.
FOUNDATION_EXPORT float MLDropRatePercent(int networkDroppedFrames, int totalFrames);

// Wi-Fi starts at 80% of ceiling (clamped to floor); otherwise start at ceiling.
FOUNDATION_EXPORT NSInteger MLAbrInitialKbps(NSInteger ceiling, NSInteger floor, BOOL isWiFi);

NS_ASSUME_NONNULL_END
