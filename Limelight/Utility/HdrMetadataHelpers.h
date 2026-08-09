//
//  HdrMetadataHelpers.h
//  Moonlight
//
//  Shared HDR metadata packing helpers (testable).
//

#import <Foundation/Foundation.h>

#include "Limelight.h"

NS_ASSUME_NONNULL_BEGIN

// Fills in Rec.2020 / D65 / XDR-class values for anything the host left empty, so a host that
// advertises HDR without usable metadata still produces a sane mastering display description.
FOUNDATION_EXPORT void MLApplyHdrMetadataDefaults(SS_HDR_METADATA *metadata);

// Packs the big-endian Mastering Display Colour Volume payload that
// kCMFormatDescriptionExtension_MasteringDisplayColorVolume expects.
// Returns nil when the metadata carries no usable primaries or display luminance.
FOUNDATION_EXPORT NSData * _Nullable MLMasteringDisplayColorVolumeData(const SS_HDR_METADATA *metadata);

// Packs the big-endian Content Light Level payload that
// kCMFormatDescriptionExtension_ContentLightLevelInfo expects.
// Returns nil when either light level is unset.
FOUNDATION_EXPORT NSData * _Nullable MLContentLightLevelInfoData(const SS_HDR_METADATA *metadata);

NS_ASSUME_NONNULL_END
