//
//  NetworkPathMonitor.h
//  Moonlight
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// YES when a new path update matches the last published state and observers
// can be skipped. hasPath must already be YES (never skip the first update).
FOUNDATION_EXPORT BOOL MLNetworkPathShouldSkipNotify(BOOL hasPath,
                                                     BOOL currentWiFi,
                                                     BOOL currentConstrained,
                                                     BOOL currentExpensive,
                                                     BOOL nextWiFi,
                                                     BOOL nextConstrained,
                                                     BOOL nextExpensive);

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
// If hasPath is already YES, the handler is also invoked once immediately with the
// current snapshot so late subscribers cannot miss a constrained path.
- (void)addObserver:(id)observer handler:(void (^)(NetworkPathMonitor *monitor))handler;
- (void)removeObserver:(id)observer;

@end

NS_ASSUME_NONNULL_END
