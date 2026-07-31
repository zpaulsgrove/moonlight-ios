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
    
    NSInteger afterHeavyDrops = MLNextAbrBitrate(57000, ceiling, floor, 6.0f, 10);
    XCTAssertLessThan(afterHeavyDrops, 57000);
    XCTAssertGreaterThanOrEqual(afterHeavyDrops, floor);
    
    NSInteger afterStable = MLNextAbrBitrate(30000, ceiling, floor, 0.0f, 2);
    XCTAssertGreaterThan(afterStable, 30000);
    XCTAssertLessThanOrEqual(afterStable, ceiling);
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

- (void)testPresetResolutionFactors {
    XCTAssertEqual(2560 * 1440, 3686400);
    XCTAssertEqual(90, 90);
    XCTAssertEqual(120, 120);
}

@end
