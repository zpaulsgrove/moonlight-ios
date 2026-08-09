//
//  MoonlightHdrMetadataTests.m
//  MoonlightTests
//
//  Covers the mastering display and content light level byte packing.
//

#import <XCTest/XCTest.h>

#import "HdrMetadataHelpers.h"

#include <string.h>

@interface MoonlightHdrMetadataTests : XCTestCase
@end

@implementation MoonlightHdrMetadataTests

- (void)testDefaultsFillEmptyMetadata {
    SS_HDR_METADATA metadata;
    memset(&metadata, 0, sizeof(metadata));
    
    MLApplyHdrMetadataDefaults(&metadata);
    
    XCTAssertEqual(metadata.displayPrimaries[0].x, 35400);
    XCTAssertEqual(metadata.displayPrimaries[0].y, 14600);
    XCTAssertEqual(metadata.displayPrimaries[1].x, 8500);
    XCTAssertEqual(metadata.displayPrimaries[1].y, 39850);
    XCTAssertEqual(metadata.displayPrimaries[2].x, 6550);
    XCTAssertEqual(metadata.displayPrimaries[2].y, 2300);
    XCTAssertEqual(metadata.whitePoint.x, 15635);
    XCTAssertEqual(metadata.whitePoint.y, 16450);
    XCTAssertEqual(metadata.maxDisplayLuminance, 1000);
    XCTAssertEqual(metadata.minDisplayLuminance, 1);
    XCTAssertEqual(metadata.maxContentLightLevel, 1600);
    XCTAssertEqual(metadata.maxFrameAverageLightLevel, 400);
}

- (void)testDefaultsPreserveHostSuppliedValues {
    SS_HDR_METADATA metadata;
    memset(&metadata, 0, sizeof(metadata));
    metadata.displayPrimaries[0].x = 34000;
    metadata.maxDisplayLuminance = 600;
    metadata.maxContentLightLevel = 700;
    metadata.maxFrameAverageLightLevel = 250;
    
    MLApplyHdrMetadataDefaults(&metadata);
    
    XCTAssertEqual(metadata.displayPrimaries[0].x, 34000);
    XCTAssertEqual(metadata.maxDisplayLuminance, 600);
    XCTAssertEqual(metadata.maxContentLightLevel, 700);
    XCTAssertEqual(metadata.maxFrameAverageLightLevel, 250);
}

- (void)testMasteringDisplayColorVolumeByteOrderAndGbrMapping {
    SS_HDR_METADATA metadata;
    memset(&metadata, 0, sizeof(metadata));
    metadata.displayPrimaries[0].x = 0x0102; // R
    metadata.displayPrimaries[0].y = 0x0304;
    metadata.displayPrimaries[1].x = 0x0506; // G
    metadata.displayPrimaries[1].y = 0x0708;
    metadata.displayPrimaries[2].x = 0x090A; // B
    metadata.displayPrimaries[2].y = 0x0B0C;
    metadata.whitePoint.x = 0x0D0E;
    metadata.whitePoint.y = 0x0F10;
    metadata.maxDisplayLuminance = 2;     // nits, packed as 10000ths
    metadata.minDisplayLuminance = 0x1234;
    
    const uint8_t expected[] = {
        0x05, 0x06, 0x07, 0x08, // G first
        0x09, 0x0A, 0x0B, 0x0C, // then B
        0x01, 0x02, 0x03, 0x04, // then R
        0x0D, 0x0E, 0x0F, 0x10, // white point
        0x00, 0x00, 0x4E, 0x20, // 2 nits -> 20000
        0x00, 0x00, 0x12, 0x34  // min luminance passes through
    };
    
    NSData* mdcv = MLMasteringDisplayColorVolumeData(&metadata);
    XCTAssertNotNil(mdcv);
    XCTAssertEqual(mdcv.length, sizeof(expected));
    XCTAssertEqualObjects(mdcv, [NSData dataWithBytes:expected length:sizeof(expected)]);
}

- (void)testMasteringDisplayColorVolumeRejectsUnusableMetadata {
    SS_HDR_METADATA metadata;
    memset(&metadata, 0, sizeof(metadata));
    XCTAssertNil(MLMasteringDisplayColorVolumeData(&metadata));
    
    // Primaries without display luminance are still unusable
    metadata.displayPrimaries[0].x = 35400;
    XCTAssertNil(MLMasteringDisplayColorVolumeData(&metadata));
}

- (void)testContentLightLevelFallbackValues {
    SS_HDR_METADATA metadata;
    memset(&metadata, 0, sizeof(metadata));
    MLApplyHdrMetadataDefaults(&metadata);
    
    const uint8_t expected[] = {
        0x06, 0x40, // 1600 maxCLL
        0x01, 0x90  // 400 maxFALL
    };
    
    NSData* cll = MLContentLightLevelInfoData(&metadata);
    XCTAssertNotNil(cll);
    XCTAssertEqual(cll.length, sizeof(expected));
    XCTAssertEqualObjects(cll, [NSData dataWithBytes:expected length:sizeof(expected)]);
}

- (void)testContentLightLevelRejectsUnsetLevels {
    SS_HDR_METADATA metadata;
    memset(&metadata, 0, sizeof(metadata));
    XCTAssertNil(MLContentLightLevelInfoData(&metadata));
    
    // maxCLL alone is not enough, maxFALL has to be present too
    metadata.maxContentLightLevel = 1000;
    XCTAssertNil(MLContentLightLevelInfoData(&metadata));
}

@end
