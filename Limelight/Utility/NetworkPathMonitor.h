//
//  NetworkPathMonitor.h
//  Moonlight
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Long-lived nw_path_monitor wrapper. Call +sharedMonitor and -start once;
// observers receive updates on the monitor's private serial queue.
@interface NetworkPathMonitor : NSObject

+ (instancetype)sharedMonitor;

// Idempotent; starts nw_path_monitor on a dedicated serial queue.
- (void)start;
// Cancels the monitor, clears hasPath / constrained / expensive so the next
// session cannot reuse a stale path snapshot.
- (void)stop;

@property (atomic, readonly) BOOL isWiFi;
@property (atomic, readonly) BOOL isConstrained;
@property (atomic, readonly) BOOL isExpensive;
// YES after at least one path update has been received.
@property (atomic, readonly) BOOL hasPath;

// Register/unregister observers; handler invoked on the monitor queue when the path changes.
- (void)addObserver:(id)observer handler:(void (^)(NetworkPathMonitor *monitor))handler;
- (void)removeObserver:(id)observer;

@end

NS_ASSUME_NONNULL_END
