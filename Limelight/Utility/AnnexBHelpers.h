//
//  AnnexBHelpers.h
//  Moonlight
//
//  Shared Annex-B start-code scan helpers (testable).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Finds 00 00 01 start codes using an ffmpeg-style skip scan.
// Writes up to maxOffsets offsets into outOffsets; returns count found.
FOUNDATION_EXPORT int MLFindAnnexBStartOffsets(const uint8_t *data, int length,
                                               int *outOffsets, int maxOffsets);

NS_ASSUME_NONNULL_END
