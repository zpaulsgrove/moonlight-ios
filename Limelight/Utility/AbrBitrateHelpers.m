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

float MLFecRepairRatePercent(uint32_t fecRecoveredFrames, uint32_t totalFrames) {
    if (totalFrames == 0 || fecRecoveredFrames == 0) {
        return 0.0f;
    }
    return 100.0f * ((float)fecRecoveredFrames / (float)totalFrames);
}

float MLAvgQueueLatencyMs(uint64_t totalClientQueueLatencyMs, int framesWithClientQueueLatency) {
    if (framesWithClientQueueLatency <= 0) {
        return 0.0f;
    }
    return (float)totalClientQueueLatencyMs / (float)framesWithClientQueueLatency;
}

NSInteger MLAbrInitialKbps(NSInteger ceiling, NSInteger floor, BOOL isWiFi) {
    if (!isWiFi) {
        return ceiling;
    }
    return MLClampBitrate((ceiling * 80) / 100, ceiling, floor);
}

NSInteger MLNextAbrBitrate(NSInteger current,
                           NSInteger ceiling,
                           NSInteger floor,
                           float dropRatePercent,
                           uint32_t rttVarianceMs,
                           float fecRepairRatePercent,
                           float queueLatencyMs,
                           BOOL connectionPoor) {
    NSInteger next = current;

    // React to Wi-Fi last-mile symptoms (drops, RTT variance, FEC repair, queue wait)
    if (connectionPoor) {
        next = (NSInteger)(current * 0.70);
    }
    else if (dropRatePercent > 5.0f || rttVarianceMs > 40 ||
             fecRepairRatePercent > 15.0f || queueLatencyMs > 25.0f) {
        next = (NSInteger)(current * 0.70);
    }
    else if (dropRatePercent > 2.0f || rttVarianceMs > 25 ||
             fecRepairRatePercent > 8.0f || queueLatencyMs > 16.0f) {
        next = (NSInteger)(current * 0.90);
    }
    else if (dropRatePercent > 0.5f || rttVarianceMs > 15 ||
             fecRepairRatePercent > 3.0f || queueLatencyMs > 10.0f) {
        next = (NSInteger)(current * 0.95);
    }
    else if (dropRatePercent < 0.1f && rttVarianceMs < 8 &&
             fecRepairRatePercent < 1.0f && queueLatencyMs < 6.0f) {
        next = current + MAX(current / 50, 500);
    }

    return MLClampBitrate(next, ceiling, floor);
}

const CFTimeInterval MLAbrPathHintHoldDuration = 5.0;

NSInteger MLAbrApplyPathHint(NSInteger nextKbps, NSInteger currentKbps, BOOL pathConstrained) {
    if (!pathConstrained) {
        return nextKbps;
    }
    // Soft hint only: hold bitrate rather than ramping up on a constrained path.
    if (nextKbps > currentKbps) {
        return currentKbps;
    }
    return nextKbps;
}

NSInteger MLAbrApplyPathHintEx(NSInteger nextKbps,
                               NSInteger currentKbps,
                               BOOL pathConstrained,
                               BOOL *holdActive,
                               CFTimeInterval *holdUntil,
                               CFTimeInterval now,
                               CFTimeInterval holdDuration) {
    if (holdUntil == NULL) {
        NSInteger result = MLAbrApplyPathHint(nextKbps, currentKbps, pathConstrained);
        if (holdActive != NULL) {
            *holdActive = pathConstrained;
        }
        return result;
    }

    if (holdDuration < 0.0) {
        holdDuration = 0.0;
    }

    if (pathConstrained) {
        *holdUntil = now + holdDuration;
    }
    else if (*holdUntil > 0.0 && now >= *holdUntil) {
        *holdUntil = 0.0;
    }

    BOOL holding = pathConstrained || (*holdUntil > 0.0 && now < *holdUntil);
    if (holdActive != NULL) {
        *holdActive = holding;
    }

    if (!holding) {
        return nextKbps;
    }
    if (nextKbps > currentKbps) {
        return currentKbps;
    }
    return nextKbps;
}

BOOL MLAbrWantsNetworkPressure(BOOL wantsCut, BOOL connectionPoor) {
    return wantsCut || connectionPoor;
}
