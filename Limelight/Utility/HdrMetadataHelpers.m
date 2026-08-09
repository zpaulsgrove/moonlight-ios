//
//  HdrMetadataHelpers.m
//  Moonlight
//

#import "HdrMetadataHelpers.h"

#include <simd/simd.h>

void MLApplyHdrMetadataDefaults(SS_HDR_METADATA *metadata) {
    if (metadata == NULL) {
        return;
    }
    
    // Fall back to Rec.2020 / D65 / XDR-class luminance when the host sends empty metadata
    if (metadata->displayPrimaries[0].x == 0 || metadata->maxDisplayLuminance == 0) {
        // Rec.2020 primaries in 0.00002 units, D65 white point
        metadata->displayPrimaries[0].x = 35400; // R
        metadata->displayPrimaries[0].y = 14600;
        metadata->displayPrimaries[1].x = 8500;  // G
        metadata->displayPrimaries[1].y = 39850;
        metadata->displayPrimaries[2].x = 6550;  // B
        metadata->displayPrimaries[2].y = 2300;
        metadata->whitePoint.x = 15635;
        metadata->whitePoint.y = 16450;
        metadata->maxDisplayLuminance = 1000;
        metadata->minDisplayLuminance = 1; // 0.0001 nits units, keep minimal non-zero
    }
    
    if (metadata->maxContentLightLevel == 0 || metadata->maxFrameAverageLightLevel == 0) {
        metadata->maxContentLightLevel = 1600;
        metadata->maxFrameAverageLightLevel = 400;
    }
}

NSData *MLMasteringDisplayColorVolumeData(const SS_HDR_METADATA *metadata) {
    if (metadata == NULL || metadata->displayPrimaries[0].x == 0 || metadata->maxDisplayLuminance == 0) {
        return nil;
    }
    
    // This data is all in big-endian
    struct {
      vector_ushort2 primaries[3];
      vector_ushort2 white_point;
      uint32_t luminance_max;
      uint32_t luminance_min;
    } __attribute__((packed, aligned(4))) mdcv;
    
    // mdcv is in GBR order while SS_HDR_METADATA is in RGB order
    mdcv.primaries[0].x = __builtin_bswap16(metadata->displayPrimaries[1].x);
    mdcv.primaries[0].y = __builtin_bswap16(metadata->displayPrimaries[1].y);
    mdcv.primaries[1].x = __builtin_bswap16(metadata->displayPrimaries[2].x);
    mdcv.primaries[1].y = __builtin_bswap16(metadata->displayPrimaries[2].y);
    mdcv.primaries[2].x = __builtin_bswap16(metadata->displayPrimaries[0].x);
    mdcv.primaries[2].y = __builtin_bswap16(metadata->displayPrimaries[0].y);
    
    mdcv.white_point.x = __builtin_bswap16(metadata->whitePoint.x);
    mdcv.white_point.y = __builtin_bswap16(metadata->whitePoint.y);
    
    // These luminance values are in 10000ths of a nit
    mdcv.luminance_max = __builtin_bswap32((uint32_t)metadata->maxDisplayLuminance * 10000);
    mdcv.luminance_min = __builtin_bswap32(metadata->minDisplayLuminance);
    
    return [NSData dataWithBytes:&mdcv length:sizeof(mdcv)];
}

NSData *MLContentLightLevelInfoData(const SS_HDR_METADATA *metadata) {
    if (metadata == NULL || metadata->maxContentLightLevel == 0 || metadata->maxFrameAverageLightLevel == 0) {
        return nil;
    }
    
    // This data is all in big-endian
    struct {
        uint16_t max_content_light_level;
        uint16_t max_frame_average_light_level;
    } __attribute__((packed, aligned(2))) cll;
    
    cll.max_content_light_level = __builtin_bswap16(metadata->maxContentLightLevel);
    cll.max_frame_average_light_level = __builtin_bswap16(metadata->maxFrameAverageLightLevel);
    
    return [NSData dataWithBytes:&cll length:sizeof(cll)];
}
