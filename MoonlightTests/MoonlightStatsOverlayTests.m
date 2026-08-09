//
//  MoonlightStatsOverlayTests.m
//  MoonlightTests
//
//  Covers the pure line builder behind the Off / Lite / Full stats overlay.
//

#import <XCTest/XCTest.h>

#import "AbrBitrateHelpers.h"
#import "StatsOverlayFormatting.h"

#include <Limelight.h>

@interface MoonlightStatsOverlayTests : XCTestCase
@end

@implementation MoonlightStatsOverlayTests

// 1080p HEVC Main 10 with HDR active, a healthy link, and host latency reported.
static MLStatsOverlaySample HdrSample(void) {
    MLStatsOverlaySample sample = {
        .width = 1920,
        .height = 1080,
        .videoFormat = VIDEO_FORMAT_H265_MAIN10,
        .hdrActive = YES,
        .framesPerSecond = 59.9f,
        .dropRatePercent = 0.08f,
        .hasRttEstimate = YES,
        .rttMs = 8,
        .rttVarianceMs = 2,
        .hasHostProcessingLatency = YES,
        .averageHostProcessingLatencyMs = 3.1f,
    };
    return sample;
}

- (void)testLiteLineHdrVariant {
    XCTAssertEqualObjects(MLStatsOverlayLiteLine(HdrSample()),
                          @"1080p HEVC HDR · 59.9 fps · drop 0.08% · net 8 ms ±2 · host 3.1 ms");
}

- (void)testLiteLineSdrVariant {
    MLStatsOverlaySample sample = {
        .width = 2560,
        .height = 1440,
        .videoFormat = VIDEO_FORMAT_AV1_MAIN8,
        .hdrActive = NO,
        .framesPerSecond = 119.8f,
        .dropRatePercent = 0.0f,
        .hasRttEstimate = YES,
        .rttMs = 4,
        .rttVarianceMs = 1,
        .hasHostProcessingLatency = YES,
        .averageHostProcessingLatencyMs = 2.5f,
    };
    
    XCTAssertEqualObjects(MLStatsOverlayLiteLine(sample),
                          @"1440p AV1 · 119.8 fps · drop 0.00% · net 4 ms ±1 · host 2.5 ms");
}

- (void)testLiteLineWithoutRttEstimate {
    MLStatsOverlaySample sample = HdrSample();
    sample.hasRttEstimate = NO;
    sample.rttMs = 0;
    sample.rttVarianceMs = 0;
    
    XCTAssertEqualObjects(MLStatsOverlayLiteLine(sample),
                          @"1080p HEVC HDR · 59.9 fps · drop 0.08% · net n/a · host 3.1 ms");
}

- (void)testLiteLineWithoutHostProcessingLatency {
    MLStatsOverlaySample sample = HdrSample();
    sample.hasHostProcessingLatency = NO;
    sample.averageHostProcessingLatencyMs = 0.0f;
    
    XCTAssertEqualObjects(MLStatsOverlayLiteLine(sample),
                          @"1080p HEVC HDR · 59.9 fps · drop 0.08% · net 8 ms ±2");
}

- (void)testLiteLineWithEmptyStatsWindow {
    MLStatsOverlaySample sample = HdrSample();
    sample.framesPerSecond = MLStatsFramesPerSecond(0, 0.5f);
    sample.dropRatePercent = MLDropRatePercent(0, 0);
    
    XCTAssertEqualObjects(MLStatsOverlayLiteLine(sample),
                          @"1080p HEVC HDR · 0.0 fps · drop 0.00% · net 8 ms ±2 · host 3.1 ms");
}

- (void)testLiteLineUsesDropPercentageNotPerSecondRate {
    MLStatsOverlaySample sample = HdrSample();
    // 1 dropped frame out of 1250 in a 0.5 s window is 0.08%, not 2 per second
    sample.dropRatePercent = MLDropRatePercent(1, 1250);
    
    XCTAssertTrue([MLStatsOverlayLiteLine(sample) containsString:@"drop 0.08%"]);
}

- (void)testFramesPerSecondGuardsAgainstEmptyWindow {
    XCTAssertEqualWithAccuracy(MLStatsFramesPerSecond(60, 0.5f), 120.0f, 0.001f);
    XCTAssertEqualWithAccuracy(MLStatsFramesPerSecond(60, 0.0f), 0.0f, 0.001f);
    XCTAssertEqualWithAccuracy(MLStatsFramesPerSecond(60, -1.0f), 0.0f, 0.001f);
    XCTAssertEqualWithAccuracy(MLStatsFramesPerSecond(0, 0.5f), 0.0f, 0.001f);
}

- (void)testResolutionLabel {
    XCTAssertEqualObjects(MLStatsResolutionLabel(1920, 1080), @"1080p");
    XCTAssertEqualObjects(MLStatsResolutionLabel(3840, 2160), @"2160p");
    XCTAssertEqualObjects(MLStatsResolutionLabel(0, 0), @"?");
}

- (void)testShortCodecNames {
    XCTAssertEqualObjects(MLStatsShortCodecName(VIDEO_FORMAT_H264, NO), @"H.264");
    XCTAssertEqualObjects(MLStatsShortCodecName(VIDEO_FORMAT_H265, NO), @"HEVC");
    XCTAssertEqualObjects(MLStatsShortCodecName(VIDEO_FORMAT_H265_MAIN10, YES), @"HEVC HDR");
    XCTAssertEqualObjects(MLStatsShortCodecName(VIDEO_FORMAT_AV1_MAIN8, NO), @"AV1");
    XCTAssertEqualObjects(MLStatsShortCodecName(VIDEO_FORMAT_AV1_MAIN10, YES), @"AV1 HDR");
    XCTAssertEqualObjects(MLStatsShortCodecName(0, NO), @"Unknown");
}

@end
