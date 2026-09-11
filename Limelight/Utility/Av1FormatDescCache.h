//
//  Av1FormatDescCache.h
//  Moonlight
//
//  Caches the last AV1 CMVideoFormatDescription keyed by av1C box bytes.
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

@interface Av1FormatDescCache : NSObject

/// Returns a +1 retained format description when av1C matches the cached key.
/// Caller must CFRelease. Returns NULL on miss or nil av1C.
- (nullable CMVideoFormatDescriptionRef)copyFormatDescriptionForAv1C:(nullable NSData *)av1c;

/// Retains desc and copies av1c as the cache key. Replaces any prior entry.
- (void)storeFormatDescription:(CMVideoFormatDescriptionRef)desc forAv1C:(NSData *)av1c;

/// Drops the cached key and releases the format description.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
