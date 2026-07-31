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

NS_ASSUME_NONNULL_END
