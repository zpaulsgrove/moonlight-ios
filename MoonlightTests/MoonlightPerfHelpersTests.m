//
//  MoonlightPerfHelpersTests.m
//  MoonlightTests
//
//  Focused helpers for M5 perf / HDR / ABR work.
//

#import <XCTest/XCTest.h>

#import "AbrBitrateHelpers.h"
#import "Utils.h"
#import "AnnexBHelpers.h"

#include <Limelight.h>

@interface MoonlightPerfHelpersTests : XCTestCase
@end

@implementation MoonlightPerfHelpersTests

- (void)testAbrClampBitrate {
    XCTAssertEqual(MLClampBitrate(80000, 57000, 22800), 57000);
    XCTAssertEqual(MLClampBitrate(1000, 57000, 22800), 22800);
    XCTAssertEqual(MLClampBitrate(30000, 57000, 22800), 30000);
}

- (void)testAbrNextBitrateDropsAndRecover {
    NSInteger ceiling = 57000;
    NSInteger floor = 22800;

    NSInteger afterHeavyDrops = MLNextAbrBitrate(57000, ceiling, floor, 6.0f, 10, 0.0f, 0.0f, NO);
    XCTAssertEqual(afterHeavyDrops, (NSInteger)(57000 * 0.70));
    XCTAssertGreaterThanOrEqual(afterHeavyDrops, floor);

    NSInteger afterModerate = MLNextAbrBitrate(50000, ceiling, floor, 3.0f, 10, 0.0f, 0.0f, NO);
    XCTAssertEqual(afterModerate, (NSInteger)(50000 * 0.90));

    NSInteger afterLight = MLNextAbrBitrate(50000, ceiling, floor, 1.0f, 10, 0.0f, 0.0f, NO);
    XCTAssertEqual(afterLight, (NSInteger)(50000 * 0.95));

    NSInteger afterStable = MLNextAbrBitrate(30000, ceiling, floor, 0.0f, 2, 0.0f, 0.0f, NO);
    XCTAssertEqual(afterStable, 30000 + MAX(30000 / 50, 500));
    XCTAssertLessThanOrEqual(afterStable, ceiling);
}

- (void)testAbrNextBitrateFecQueueAndPoor {
    NSInteger ceiling = 57000;
    NSInteger floor = 22800;

    NSInteger afterPoor = MLNextAbrBitrate(50000, ceiling, floor, 0.0f, 2, 0.0f, 0.0f, YES);
    XCTAssertEqual(afterPoor, (NSInteger)(50000 * 0.70));

    NSInteger afterHeavyFec = MLNextAbrBitrate(50000, ceiling, floor, 0.0f, 2, 16.0f, 0.0f, NO);
    XCTAssertEqual(afterHeavyFec, (NSInteger)(50000 * 0.70));

    NSInteger afterModQueue = MLNextAbrBitrate(50000, ceiling, floor, 0.0f, 2, 0.0f, 17.0f, NO);
    XCTAssertEqual(afterModQueue, (NSInteger)(50000 * 0.90));

    NSInteger afterLightFec = MLNextAbrBitrate(50000, ceiling, floor, 0.0f, 2, 4.0f, 0.0f, NO);
    XCTAssertEqual(afterLightFec, (NSInteger)(50000 * 0.95));

    // Hold steady in the dead band (not bad enough to cut, not clean enough to bump)
    NSInteger held = MLNextAbrBitrate(40000, ceiling, floor, 0.2f, 10, 1.5f, 7.0f, NO);
    XCTAssertEqual(held, 40000);

    NSInteger clampedFloor = MLNextAbrBitrate(floor, ceiling, floor, 10.0f, 50, 0.0f, 0.0f, NO);
    XCTAssertEqual(clampedFloor, floor);

    NSInteger nearCeiling = MLNextAbrBitrate(ceiling - 100, ceiling, floor, 0.0f, 1, 0.0f, 0.0f, NO);
    XCTAssertEqual(nearCeiling, ceiling);
}

- (void)testAbrPathHintDoesNotForceCuts {
    // Constrained path alone must not slash bitrate every tick.
    XCTAssertEqual(MLAbrApplyPathHint(50000, 50000, YES), 50000);
    XCTAssertEqual(MLAbrApplyPathHint(40000, 50000, YES), 40000); // cuts from real signals still apply
    XCTAssertEqual(MLAbrApplyPathHint(55000, 50000, YES), 50000); // suppress up-ramp only
    XCTAssertEqual(MLAbrApplyPathHint(55000, 50000, NO), 55000);
    
    XCTAssertFalse(MLAbrWantsNetworkPressure(NO, NO));
    XCTAssertTrue(MLAbrWantsNetworkPressure(YES, NO));
    XCTAssertTrue(MLAbrWantsNetworkPressure(NO, YES));
}

- (void)testAbrFecRepairAndQueueLatencyHelpers {
    XCTAssertEqualWithAccuracy(MLFecRepairRatePercent(0, 120), 0.0f, 0.001f);
    XCTAssertEqualWithAccuracy(MLFecRepairRatePercent(3, 100), 3.0f, 0.001f);
    XCTAssertEqualWithAccuracy(MLFecRepairRatePercent(5, 0), 0.0f, 0.001f);

    XCTAssertEqualWithAccuracy(MLAvgQueueLatencyMs(0, 0), 0.0f, 0.001f);
    XCTAssertEqualWithAccuracy(MLAvgQueueLatencyMs(250, 10), 25.0f, 0.001f);
    XCTAssertEqualWithAccuracy(MLAvgQueueLatencyMs(100, -1), 0.0f, 0.001f);
}

- (void)testAbrDropRatePercent {
    XCTAssertEqualWithAccuracy(MLDropRatePercent(0, 120), 0.0f, 0.001f);
    XCTAssertEqualWithAccuracy(MLDropRatePercent(6, 120), 5.0f, 0.001f);
    XCTAssertEqualWithAccuracy(MLDropRatePercent(1, 100), 1.0f, 0.001f);
    XCTAssertEqualWithAccuracy(MLDropRatePercent(5, 0), 0.0f, 0.001f);
}

- (void)testPrivateAddressAndSunshineLineage {
    XCTAssertTrue([Utils isPrivateAddress:@"192.168.1.20"]);
    XCTAssertTrue([Utils isPrivateAddress:@"10.0.0.5"]);
    XCTAssertTrue([Utils isPrivateAddress:@"172.16.4.1"]);
    XCTAssertTrue([Utils isPrivateAddress:@"host.local"]);
    XCTAssertFalse([Utils isPrivateAddress:@"8.8.8.8"]);
    
    XCTAssertTrue([Utils isSunshineLineageAppVersion:@"7.1.0.-1"]);
    XCTAssertFalse([Utils isSunshineLineageAppVersion:@"7.1.0.0"]);
}

- (void)testSlicesAndColorConstants {
    unsigned int caps = CAPABILITY_SLICES_PER_FRAME(4);
    XCTAssertEqual((caps >> 24) & 0xFF, 4);
    
    XCTAssertEqual(COLORSPACE_REC_709, 1);
    XCTAssertEqual(COLOR_RANGE_FULL, 1);
}

- (void)testAnnexBStartCodeScan {
    uint8_t buf[] = {
        0x00, 0x00, 0x01, 0xAA, 0x11, 0x22,
        0x00, 0x00, 0x01, 0xBB, 0x33
    };
    int offsets[8] = {0};
    int count = MLFindAnnexBStartOffsets(buf, (int)sizeof(buf), offsets, 8);
    XCTAssertEqual(count, 2);
    XCTAssertEqual(offsets[0], 0);
    XCTAssertEqual(offsets[1], 6);
}

- (void)testAnnexBFourByteStartOffsetsAndPrefixes {
    uint8_t buf[] = {
        0x00, 0x00, 0x00, 0x01, 0x67, 0x42,
        0x00, 0x00, 0x00, 0x01, 0x68, 0xCE
    };
    int offsets[8] = {0};
    int prefixes[8] = {0};
    int count = MLFindAnnexBNals(buf, (int)sizeof(buf), offsets, prefixes, 8);
    XCTAssertEqual(count, 2);
    XCTAssertEqual(offsets[0], 0);
    XCTAssertEqual(prefixes[0], 4);
    XCTAssertEqual(offsets[1], 6);
    XCTAssertEqual(prefixes[1], 4);
}

- (void)testAnnexBRewriteAllFourByteInPlace {
    uint8_t buf[16] = {
        0x00, 0x00, 0x00, 0x01, 0xAA, 0xBB,
        0x00, 0x00, 0x00, 0x01, 0xCC
    };
    int outLength = 0;
    XCTAssertEqual(MLRewriteAnnexBToLengthPrefixed(buf, 11, 16, &outLength), 0);
    XCTAssertEqual(outLength, 11);
    // First NAL payload length = 2
    XCTAssertEqual(buf[0], 0x00);
    XCTAssertEqual(buf[1], 0x00);
    XCTAssertEqual(buf[2], 0x00);
    XCTAssertEqual(buf[3], 0x02);
    XCTAssertEqual(buf[4], 0xAA);
    XCTAssertEqual(buf[5], 0xBB);
    // Second NAL payload length = 1
    XCTAssertEqual(buf[6], 0x00);
    XCTAssertEqual(buf[7], 0x00);
    XCTAssertEqual(buf[8], 0x00);
    XCTAssertEqual(buf[9], 0x01);
    XCTAssertEqual(buf[10], 0xCC);
}

- (void)testAnnexBRewriteThreeByteCompact {
    uint8_t buf[16] = {
        0x00, 0x00, 0x01, 0xAA, 0xBB,
        0x00, 0x00, 0x01, 0xCC
    };
    int outLength = 0;
    XCTAssertEqual(MLRewriteAnnexBToLengthPrefixed(buf, 9, 16, &outLength), 0);
    XCTAssertEqual(outLength, 11); // +1 byte per 3-byte start code (2 NALs)
    XCTAssertEqual(buf[0], 0x00);
    XCTAssertEqual(buf[1], 0x00);
    XCTAssertEqual(buf[2], 0x00);
    XCTAssertEqual(buf[3], 0x02);
    XCTAssertEqual(buf[4], 0xAA);
    XCTAssertEqual(buf[5], 0xBB);
    XCTAssertEqual(buf[6], 0x00);
    XCTAssertEqual(buf[7], 0x00);
    XCTAssertEqual(buf[8], 0x00);
    XCTAssertEqual(buf[9], 0x01);
    XCTAssertEqual(buf[10], 0xCC);
}

- (void)testAnnexBRewriteRejectsLeadingBytes {
    uint8_t buf[16] = {
        0xFF, 0x00, 0x00, 0x01, 0xAA, 0xBB
    };
    int outLength = 0;
    XCTAssertEqual(MLRewriteAnnexBToLengthPrefixed(buf, 6, 16, &outLength), -1);
}

- (void)testAnnexBRewriteMixedThreeAndFourByte {
    uint8_t buf[24] = {
        0x00, 0x00, 0x00, 0x01, 0xAA, 0xBB,
        0x00, 0x00, 0x01, 0xCC
    };
    int outLength = 0;
    XCTAssertEqual(MLRewriteAnnexBToLengthPrefixed(buf, 10, 24, &outLength), 0);
    XCTAssertEqual(outLength, 11); // one extra byte for the 3-byte start code
    XCTAssertEqual(buf[3], 0x02);
    XCTAssertEqual(buf[4], 0xAA);
    XCTAssertEqual(buf[5], 0xBB);
    XCTAssertEqual(buf[9], 0x01);
    XCTAssertEqual(buf[10], 0xCC);
}

- (void)testStreamPacketSizePathHelper {
    int remote = 0;
    int packet = 0;
    
    [Utils streamRemoteMode:&remote packetSize:&packet isVPN:YES isPrivateLAN:YES isWiFi:YES aggressiveWifiPackets:NO];
    XCTAssertEqual(remote, STREAM_CFG_REMOTE);
    XCTAssertEqual(packet, 1024);
    
    [Utils streamRemoteMode:&remote packetSize:&packet isVPN:NO isPrivateLAN:YES isWiFi:YES aggressiveWifiPackets:NO];
    XCTAssertEqual(remote, STREAM_CFG_LOCAL);
    XCTAssertEqual(packet, 1024);
    
    [Utils streamRemoteMode:&remote packetSize:&packet isVPN:NO isPrivateLAN:YES isWiFi:NO aggressiveWifiPackets:NO];
    XCTAssertEqual(remote, STREAM_CFG_LOCAL);
    XCTAssertEqual(packet, 1392);
    
    [Utils streamRemoteMode:&remote packetSize:&packet isVPN:NO isPrivateLAN:NO isWiFi:YES aggressiveWifiPackets:NO];
    XCTAssertEqual(remote, STREAM_CFG_AUTO);
    XCTAssertEqual(packet, 1024);
    
    [Utils streamRemoteMode:&remote packetSize:&packet isVPN:NO isPrivateLAN:YES isWiFi:YES aggressiveWifiPackets:YES];
    XCTAssertEqual(remote, STREAM_CFG_LOCAL);
    XCTAssertEqual(packet, 1392);
}

- (void)testAbrInitialKbpsWiFiRamp {
    XCTAssertEqual(MLAbrInitialKbps(50000, 20000, YES), 40000);
    XCTAssertEqual(MLAbrInitialKbps(50000, 20000, NO), 50000);
    XCTAssertEqual(MLAbrInitialKbps(20000, 18000, YES), 18000); // 80% below floor clamps up
}

- (void)testPresetResolutionFactors {
    XCTAssertEqual(2560 * 1440, 3686400);
    XCTAssertEqual(90, 90);
    XCTAssertEqual(120, 120);
}

@end
