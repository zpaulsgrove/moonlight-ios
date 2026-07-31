//
//  AnnexBHelpers.h
//  Moonlight
//
//  Shared Annex-B start-code scan helpers (testable).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Finds 00 00 01 / 00 00 00 01 start codes using an ffmpeg-style skip scan.
// Writes up to maxOffsets start offsets into outOffsets; returns count found.
FOUNDATION_EXPORT int MLFindAnnexBStartOffsets(const uint8_t *data, int length,
                                               int *outOffsets, int maxOffsets);

// Same scan, also reports each start-code prefix length (3 or 4).
// outPrefixLengths may be NULL when only offsets are needed.
FOUNDATION_EXPORT int MLFindAnnexBNals(const uint8_t *data, int length,
                                       int *outOffsets, int * _Nullable outPrefixLengths,
                                       int maxNals);

// Rewrites Annex-B to AVCC/HVCC length-prefixed NALs in place.
// All-4-byte start codes: replace each start code with BE32 payload length.
// Any 3-byte start code: compact once into length-prefixed layout (needs capacity >= length + 3-byte count).
// Returns 0 on success and writes the final byte length to outLength; -1 on failure.
FOUNDATION_EXPORT int MLRewriteAnnexBToLengthPrefixed(uint8_t *data, int length,
                                                      int capacity, int *outLength);

NS_ASSUME_NONNULL_END
