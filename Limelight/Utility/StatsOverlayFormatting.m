//
//  StatsOverlayFormatting.m
//  Moonlight
//

#import "StatsOverlayFormatting.h"

#include <math.h>

#include <Limelight.h>

static NSString* const kStatsOverlaySeparator = @" · ";

NSString* MLStatsResolutionLabel(int width, int height) {
    if (width <= 0 || height <= 0) {
        return @"?";
    }
    return [NSString stringWithFormat:@"%dp", height];
}

NSString* MLStatsShortCodecName(int videoFormat, BOOL hdrActive) {
    NSString* name;
    
    switch (videoFormat) {
        case VIDEO_FORMAT_H264:
            name = @"H.264";
            break;
        case VIDEO_FORMAT_H265:
        case VIDEO_FORMAT_H265_MAIN10:
            name = @"HEVC";
            break;
        case VIDEO_FORMAT_AV1_MAIN8:
        case VIDEO_FORMAT_AV1_MAIN10:
            name = @"AV1";
            break;
        default:
            name = @"Unknown";
            break;
    }
    
    if (hdrActive) {
        return [name stringByAppendingString:@" HDR"];
    }
    return name;
}

int MLStatsVideoFormatFromCodecName(NSString* codecName) {
    if (codecName == nil) {
        return 0;
    }
    
    if ([codecName hasPrefix:@"H.264"]) {
        return VIDEO_FORMAT_H264;
    }
    if ([codecName hasPrefix:@"HEVC Main 10"]) {
        return VIDEO_FORMAT_H265_MAIN10;
    }
    if ([codecName hasPrefix:@"HEVC"]) {
        return VIDEO_FORMAT_H265;
    }
    if ([codecName hasPrefix:@"AV1 10-bit"]) {
        return VIDEO_FORMAT_AV1_MAIN10;
    }
    if ([codecName hasPrefix:@"AV1"]) {
        return VIDEO_FORMAT_AV1_MAIN8;
    }
    
    return 0;
}

float MLStatsFramesPerSecond(int totalFrames, float intervalSeconds) {
    if (totalFrames <= 0 || intervalSeconds <= 0.0f || !isfinite(intervalSeconds)) {
        return 0.0f;
    }
    return (float)totalFrames / intervalSeconds;
}

NSString* MLStatsOverlayLiteLine(MLStatsOverlaySample sample) {
    float framesPerSecond = isfinite(sample.framesPerSecond) && sample.framesPerSecond > 0.0f
        ? sample.framesPerSecond : 0.0f;
    float dropRatePercent = isfinite(sample.dropRatePercent) && sample.dropRatePercent > 0.0f
        ? sample.dropRatePercent : 0.0f;
    
    NSMutableArray<NSString*>* components = [[NSMutableArray alloc] init];
    
    [components addObject:[NSString stringWithFormat:@"%@ %@",
                           MLStatsResolutionLabel(sample.width, sample.height),
                           MLStatsShortCodecName(sample.videoFormat, sample.hdrActive)]];
    [components addObject:[NSString stringWithFormat:@"%.1f fps", framesPerSecond]];
    [components addObject:[NSString stringWithFormat:@"drop %.2f%%", dropRatePercent]];
    
    if (sample.hasRttEstimate) {
        [components addObject:[NSString stringWithFormat:@"net %u ms ±%u", sample.rttMs, sample.rttVarianceMs]];
    }
    else {
        [components addObject:@"net n/a"];
    }
    
    if (sample.hasHostProcessingLatency) {
        [components addObject:[NSString stringWithFormat:@"host %.1f ms", sample.averageHostProcessingLatencyMs]];
    }
    
    return [components componentsJoinedByString:kStatsOverlaySeparator];
}
