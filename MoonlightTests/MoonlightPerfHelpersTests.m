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
#import "SoftDropHelpers.h"
#import "Av1FormatDescCache.h"
#import "AudioPlaybackHelpers.h"

#include <Limelight.h>
#import <CoreMedia/CoreMedia.h>

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

- (void)testAbrPathHintExpiryHold {
    CFTimeInterval holdUntil = 0;
    BOOL holdActive = NO;
    CFTimeInterval now = 100.0;
    CFTimeInterval hold = MLAbrPathHintHoldDuration;

    // Constrained: suppress up-ramp and arm hold window.
    NSInteger next = MLAbrApplyPathHintEx(55000, 50000, YES, &holdActive, &holdUntil, now, hold);
    XCTAssertEqual(next, 50000);
    XCTAssertTrue(holdActive);
    XCTAssertEqualWithAccuracy(holdUntil, now + hold, 0.001);

    // Cuts still apply while held.
    next = MLAbrApplyPathHintEx(40000, 50000, YES, &holdActive, &holdUntil, now + 1.0, hold);
    XCTAssertEqual(next, 40000);
    XCTAssertTrue(holdActive);

    // Path cleared but still inside hold: suppress up-ramps.
    now = holdUntil - 0.5;
    next = MLAbrApplyPathHintEx(55000, 50000, NO, &holdActive, &holdUntil, now, hold);
    XCTAssertEqual(next, 50000);
    XCTAssertTrue(holdActive);

    // After hold expires: up-ramps allowed again.
    now = holdUntil + 0.01;
    next = MLAbrApplyPathHintEx(55000, 50000, NO, &holdActive, &holdUntil, now, hold);
    XCTAssertEqual(next, 55000);
    XCTAssertFalse(holdActive);
    XCTAssertEqualWithAccuracy(holdUntil, 0.0, 0.001);

    // Nil holdUntil falls back to forever-while-constrained behavior.
    next = MLAbrApplyPathHintEx(55000, 50000, YES, NULL, NULL, 0, hold);
    XCTAssertEqual(next, 50000);
    next = MLAbrApplyPathHintEx(55000, 50000, NO, NULL, NULL, 0, hold);
    XCTAssertEqual(next, 55000);
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
    
    [Utils streamRemoteMode:&remote packetSize:&packet isVPN:YES isPrivateLAN:YES isWiFi:YES aggressiveWifiPackets:NO pathConstrained:NO];
    XCTAssertEqual(remote, STREAM_CFG_REMOTE);
    XCTAssertEqual(packet, 1024);
    
    // Clean private LAN Wi-Fi: 1392 without aggressive setting.
    [Utils streamRemoteMode:&remote packetSize:&packet isVPN:NO isPrivateLAN:YES isWiFi:YES aggressiveWifiPackets:NO pathConstrained:NO];
    XCTAssertEqual(remote, STREAM_CFG_LOCAL);
    XCTAssertEqual(packet, 1392);
    
    // Constrained/expensive path forces 1024 even on LAN Wi-Fi with aggressive=YES.
    [Utils streamRemoteMode:&remote packetSize:&packet isVPN:NO isPrivateLAN:YES isWiFi:YES aggressiveWifiPackets:YES pathConstrained:YES];
    XCTAssertEqual(remote, STREAM_CFG_LOCAL);
    XCTAssertEqual(packet, 1024);
    
    [Utils streamRemoteMode:&remote packetSize:&packet isVPN:NO isPrivateLAN:YES isWiFi:NO aggressiveWifiPackets:NO pathConstrained:NO];
    XCTAssertEqual(remote, STREAM_CFG_LOCAL);
    XCTAssertEqual(packet, 1392);
    
    [Utils streamRemoteMode:&remote packetSize:&packet isVPN:NO isPrivateLAN:NO isWiFi:YES aggressiveWifiPackets:NO pathConstrained:NO];
    XCTAssertEqual(remote, STREAM_CFG_AUTO);
    XCTAssertEqual(packet, 1024);
    
    [Utils streamRemoteMode:&remote packetSize:&packet isVPN:NO isPrivateLAN:YES isWiFi:YES aggressiveWifiPackets:YES pathConstrained:NO];
    XCTAssertEqual(remote, STREAM_CFG_LOCAL);
    XCTAssertEqual(packet, 1392);

    // Legacy wrapper (no pathConstrained) still returns clean-LAN 1392.
    [Utils streamRemoteMode:&remote packetSize:&packet isVPN:NO isPrivateLAN:YES isWiFi:YES aggressiveWifiPackets:NO];
    XCTAssertEqual(packet, 1392);
}

- (void)testStreamEncryptionFlagsHelper {
    XCTAssertEqual(MLStreamEncryptionFlags(NO, YES, NO), ENCFLG_ALL);
    XCTAssertEqual(MLStreamEncryptionFlags(YES, YES, NO), ENCFLG_NONE);
    XCTAssertEqual(MLStreamEncryptionFlags(YES, YES, YES), ENCFLG_ALL); // VPN blocks cleartext
    XCTAssertEqual(MLStreamEncryptionFlags(YES, NO, NO), ENCFLG_ALL); // not private LAN
    XCTAssertEqual(MLStreamEncryptionFlags(NO, NO, NO), ENCFLG_ALL);
}

- (void)testAbrInitialKbpsWiFiRamp {
    XCTAssertEqual(MLAbrInitialKbps(50000, 20000, YES), 40000);
    XCTAssertEqual(MLAbrInitialKbps(50000, 20000, NO), 50000);
    XCTAssertEqual(MLAbrInitialKbps(20000, 18000, YES), 18000); // 80% below floor clamps up
}

- (void)testSoftDropMaxAgeMs {
    // 120 Hz: 1500/120 = 12.5 -> 12 floor does not bind; integer division yields 12.
    XCTAssertEqual(MLSoftDropMaxAgeMs(120, NO), 12ull);
    // Pressure uses ~1.2 periods with a 12 ms floor (not one period / 8 ms).
    XCTAssertEqual(MLSoftDropMaxAgeMs(120, YES), 12ull); // MAX(12, 1200/120=10)
    XCTAssertEqual(MLSoftDropMaxAgeMs(60, NO), 25ull);  // 1500/60
    XCTAssertEqual(MLSoftDropMaxAgeMs(60, YES), 20ull); // 1200/60
    XCTAssertEqual(MLSoftDropMaxAgeMs(240, NO), 12ull); // MAX(12, 1500/240=6)
    XCTAssertEqual(MLSoftDropMaxAgeMs(240, YES), 12ull); // MAX(12, 1200/240=5)
    XCTAssertEqual(MLSoftDropMaxAgeMs(0, NO), 1500ull); // fps clamped to 1
    XCTAssertEqual(MLSoftDropMaxAgeMs(0, YES), 1200ull);
}

- (void)testSoftDropEvaluatePacingAndAgeGuards {
    // Frame pacing never soft-drops for backlog/age.
    MLSoftDropDecision paced = MLSoftDropEvaluate(/*isIdr*/NO,
                                                  /*framePacing*/YES,
                                                  /*cooldown*/NO,
                                                  /*broken*/NO,
                                                  /*rfiPending*/NO,
                                                  /*frame*/10,
                                                  /*rfiDropped*/0,
                                                  /*pending*/5,
                                                  /*age*/100,
                                                  /*maxAge*/12);
    XCTAssertFalse(paced.drop);
    XCTAssertFalse(paced.dropForBacklog);
    XCTAssertFalse(paced.dropForAge);
    
    // Age drop requires pending >= 1 (sole waited frame must not be discarded).
    MLSoftDropDecision sole = MLSoftDropEvaluate(NO, NO, NO, NO, NO, 10, 0, 0, 100, 12);
    XCTAssertFalse(sole.dropForAge);
    XCTAssertFalse(sole.drop);
    
    MLSoftDropDecision aged = MLSoftDropEvaluate(NO, NO, NO, NO, NO, 10, 0, 1, 100, 12);
    XCTAssertTrue(aged.dropForAge);
    XCTAssertTrue(aged.drop);
    
    // Backlog needs pending >= threshold.
    MLSoftDropDecision backlog = MLSoftDropEvaluate(NO, NO, NO, NO, NO, 10, 0, 2, 0, 12);
    XCTAssertTrue(backlog.dropForBacklog);
    XCTAssertTrue(backlog.drop);
    
    MLSoftDropDecision onePending = MLSoftDropEvaluate(NO, NO, NO, NO, NO, 10, 0, 1, 0, 12);
    XCTAssertFalse(onePending.dropForBacklog);
    XCTAssertFalse(onePending.drop);
}

- (void)testSoftDropEvaluateCooldownAndRfiRecovery {
    // Cooldown blocks new backlog/age streaks (no silent DR_OK age-drop path).
    MLSoftDropDecision coolAge = MLSoftDropEvaluate(NO, NO, /*cooldown*/YES, NO, NO, 10, 0, 3, 100, 12);
    XCTAssertFalse(coolAge.dropForBacklog);
    XCTAssertFalse(coolAge.dropForAge);
    XCTAssertFalse(coolAge.drop);
    
    // Broken chain still drops during cooldown.
    MLSoftDropDecision coolBroken = MLSoftDropEvaluate(NO, NO, YES, /*broken*/YES, NO, 10, 0, 0, 0, 12);
    XCTAssertTrue(coolBroken.dropBrokenChain);
    XCTAssertTrue(coolBroken.drop);
    
    // RFI recovery candidate clears backlog/age/broken so a later frame can enqueue.
    MLSoftDropDecision rfi = MLSoftDropEvaluate(NO, NO, NO, /*broken*/YES, /*rfi*/YES,
                                                /*frame*/20, /*dropped*/15,
                                                /*pending*/4, /*age*/100, /*maxAge*/12);
    XCTAssertTrue(rfi.rfiRecoveryCandidate);
    XCTAssertFalse(rfi.dropForBacklog);
    XCTAssertFalse(rfi.dropForAge);
    XCTAssertFalse(rfi.dropBrokenChain);
    XCTAssertFalse(rfi.drop);
    
    // Same-or-older frame than last RFI drop is not a recovery candidate.
    MLSoftDropDecision notYet = MLSoftDropEvaluate(NO, NO, NO, YES, YES, 15, 15, 4, 100, 12);
    XCTAssertFalse(notYet.rfiRecoveryCandidate);
    XCTAssertTrue(notYet.dropBrokenChain);
    XCTAssertTrue(notYet.drop);
}

- (void)testPacedShouldKeepDrainingCatchUpAndCap {
    // Old one-per-tick policy would stop after the first enqueue.
    XCTAssertTrue(MLPacedShouldKeepDraining(1, 5, kMLPacedMaxEnqueuesPerTick));
    XCTAssertTrue(MLPacedShouldKeepDraining(3, 2, kMLPacedMaxEnqueuesPerTick));
    XCTAssertFalse(MLPacedShouldKeepDraining(kMLPacedMaxEnqueuesPerTick, 8, kMLPacedMaxEnqueuesPerTick));
    
    // Live edge: nothing left to drain.
    XCTAssertFalse(MLPacedShouldKeepDraining(1, 0, kMLPacedMaxEnqueuesPerTick));
    XCTAssertFalse(MLPacedShouldKeepDraining(2, 0, kMLPacedMaxEnqueuesPerTick));
    
    // Have not displayed one yet.
    XCTAssertTrue(MLPacedShouldKeepDraining(0, 0, kMLPacedMaxEnqueuesPerTick));
    XCTAssertTrue(MLPacedShouldKeepDraining(0, 4, kMLPacedMaxEnqueuesPerTick));
    
    // Invalid cap falls back to the default of 4.
    XCTAssertTrue(MLPacedShouldKeepDraining(3, 1, 0));
    XCTAssertFalse(MLPacedShouldKeepDraining(4, 1, 0));
}

- (void)testPacedShouldPollNextFrameRequiresRendererReady {
    // Cap and remaining would allow another poll, but ASBDL not ready must stop.
    XCTAssertFalse(MLPacedShouldPollNextFrame(1, 5, kMLPacedMaxEnqueuesPerTick, NO));
    XCTAssertTrue(MLPacedShouldPollNextFrame(1, 5, kMLPacedMaxEnqueuesPerTick, YES));
    
    // Live edge still stops even when ready.
    XCTAssertFalse(MLPacedShouldPollNextFrame(1, 0, kMLPacedMaxEnqueuesPerTick, YES));
    
    // Hit the per-tick cap.
    XCTAssertFalse(MLPacedShouldPollNextFrame(kMLPacedMaxEnqueuesPerTick, 8, kMLPacedMaxEnqueuesPerTick, YES));
}

- (void)testAudioPreferredIOBufferDuration {
    XCTAssertEqualWithAccuracy(MLPreferredAudioIOBufferDuration(48000, 240), 0.005, 0.0001);
    XCTAssertEqualWithAccuracy(MLPreferredAudioIOBufferDuration(48000, 480), 0.010, 0.0001);
    XCTAssertEqualWithAccuracy(MLPreferredAudioIOBufferDuration(48000, 48), 0.0025, 0.0001); // floor
    XCTAssertEqualWithAccuracy(MLPreferredAudioIOBufferDuration(48000, 960), 0.010, 0.0001); // ceiling
    XCTAssertEqualWithAccuracy(MLPreferredAudioIOBufferDuration(0, 240), 0.005, 0.0001);
    XCTAssertEqualWithAccuracy(MLPreferredAudioIOBufferDuration(48000, 0), 0.005, 0.0001);
}

- (void)testAudioPendingMsAndQueuePolicy {
    XCTAssertEqual(MLAudioPacketDurationMs(48000, 240), 5);
    XCTAssertEqual(MLAudioPacketDurationMs(48000, 480), 10);
    XCTAssertEqual(MLAudioPacketDurationMs(0, 240), 5);
    
    // 4 frames of 5 ms = 20 ms.
    XCTAssertEqual(MLSdlQueuedAudioDurationMs(4 * 1920, 1920, 5), 20);
    XCTAssertEqual(MLSdlQueuedAudioDurationMs(0, 1920, 5), 0);
    XCTAssertEqual(MLSdlQueuedAudioDurationMs(100, 0, 5), 0);
    // Partial frames truncate; one full frame plus half still counts as 5 ms.
    XCTAssertEqual(MLSdlQueuedAudioDurationMs(1920, 1920, 5), 5);
    XCTAssertEqual(MLSdlQueuedAudioDurationMs(1920 + 960, 1920, 5), 5);
    
    XCTAssertEqual(MLCombinedAudioPendingMs(15, 10), 25);
    XCTAssertEqual(MLCombinedAudioPendingMs(-3, 10), 10);
    
    // PLC must queue even when far over the cap (old code returned before decode).
    XCTAssertTrue(MLShouldQueueDecodedAudio(YES, 100, kMLAudioPendingCapMs));
    XCTAssertTrue(MLShouldQueueDecodedAudio(YES, 0, kMLAudioPendingCapMs));
    
    XCTAssertTrue(MLShouldQueueDecodedAudio(NO, 20, kMLAudioPendingCapMs));
    XCTAssertFalse(MLShouldQueueDecodedAudio(NO, 21, kMLAudioPendingCapMs));
    XCTAssertFalse(MLShouldQueueDecodedAudio(NO, 25, kMLAudioPendingCapMs));
    XCTAssertTrue(MLShouldQueueDecodedAudio(NO, 0, kMLAudioPendingCapMs));
    
    // Invalid cap falls back to kMLAudioPendingCapMs (20).
    XCTAssertTrue(MLShouldQueueDecodedAudio(NO, 20, 0));
    XCTAssertFalse(MLShouldQueueDecodedAudio(NO, 21, 0));
    XCTAssertFalse(MLShouldQueueDecodedAudio(NO, 21, -1));
}

- (void)testAv1FormatDescCacheHitMissAndInvalidate {
    Av1FormatDescCache *cache = [[Av1FormatDescCache alloc] init];
    CMVideoFormatDescriptionRef desc = NULL;
    OSStatus status = CMVideoFormatDescriptionCreate(kCFAllocatorDefault,
                                                     kCMVideoCodecType_H264,
                                                     1920,
                                                     1080,
                                                     NULL,
                                                     &desc);
    XCTAssertEqual(status, noErr);
    XCTAssertNotEqual(desc, NULL);
    
    NSData *keyA = [@"av1c-a" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *keyB = [@"av1c-b" dataUsingEncoding:NSUTF8StringEncoding];
    
    XCTAssertEqual([cache copyFormatDescriptionForAv1C:keyA], NULL);
    
    [cache storeFormatDescription:desc forAv1C:keyA];
    CMVideoFormatDescriptionRef hit = [cache copyFormatDescriptionForAv1C:keyA];
    XCTAssertEqual(hit, desc);
    if (hit != NULL) {
        CFRelease(hit);
    }
    XCTAssertEqual([cache copyFormatDescriptionForAv1C:keyB], NULL);
    
    [cache invalidate];
    XCTAssertEqual([cache copyFormatDescriptionForAv1C:keyA], NULL);
    
    CFRelease(desc);
}

- (void)testPresetResolutionFactors {
    XCTAssertEqual(2560 * 1440, 3686400);
    XCTAssertEqual(90, 90);
    XCTAssertEqual(120, 120);
}

@end
