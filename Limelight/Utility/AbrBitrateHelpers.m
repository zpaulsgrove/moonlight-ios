//
//  AbrBitrateHelpers.m
//  Moonlight
//

#import "AbrBitrateHelpers.h"

NSInteger MLClampBitrate(NSInteger candidate, NSInteger ceiling, NSInteger floor) {
    if (candidate > ceiling) {
        return ceiling;
    }
    if (candidate < floor) {
        return floor;
    }
    return candidate;
}

float MLDropRatePercent(int networkDroppedFrames, int totalFrames) {
    if (totalFrames <= 0 || networkDroppedFrames <= 0) {
        return 0.0f;
    }
    return 100.0f * ((float)networkDroppedFrames / (float)totalFrames);
}

NSInteger MLNextAbrBitrate(NSInteger current,
                           NSInteger ceiling,
                           NSInteger floor,
                           float dropRatePercent,
                           uint32_t rttVarianceMs) {
    NSInteger next = current;
    
    // React primarily to Wi-Fi last-mile symptoms (drop percent + RTT variance)
    if (dropRatePercent > 5.0f || rttVarianceMs > 40) {
        next = (NSInteger)(current * 0.70);
    }
    else if (dropRatePercent > 2.0f || rttVarianceMs > 25) {
        next = (NSInteger)(current * 0.90);
    }
    else if (dropRatePercent > 0.5f || rttVarianceMs > 15) {
        next = (NSInteger)(current * 0.95);
    }
    else if (dropRatePercent < 0.1f && rttVarianceMs < 8) {
        next = current + MAX(current / 50, 500);
    }
    
    return MLClampBitrate(next, ceiling, floor);
}
