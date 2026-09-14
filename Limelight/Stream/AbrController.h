//
//  AbrController.h
//  Moonlight
//
//  Local adaptive bitrate controller for Vibepollo /bitrate.
//

#import <Foundation/Foundation.h>
#import "Connection.h"
#import "StreamConfiguration.h"

@class VideoDecoderRenderer;

NS_ASSUME_NONNULL_BEGIN

@interface AbrController : NSObject

// Ceiling is the user-selected bitrate (kbps). Floor is ~40% of ceiling.
// Host ABR (Vibepollo /bitrate) is used when available; otherwise local pressure fallback.
- (instancetype)initWithConfig:(StreamConfiguration*)config
                    connection:(Connection*)connection;

- (void)attachRenderer:(VideoDecoderRenderer*)renderer;

- (void)start;
- (void)stop;

// Forwarded from CONN_STATUS_* callbacks.
- (void)noteConnectionStatus:(int)status;

// YES when Vibepollo host ABR apply path is active.
- (BOOL)isActive;
// Last applied (or shadow) target bitrate in kbps.
- (NSInteger)currentBitrateKbps;

@end

NS_ASSUME_NONNULL_END
