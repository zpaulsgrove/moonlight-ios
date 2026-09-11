//
//  NetworkPathMonitor.m
//  Moonlight
//

#import "NetworkPathMonitor.h"

#import <Network/Network.h>

@interface NetworkPathMonitor ()
@property (atomic, readwrite) BOOL isWiFi;
@property (atomic, readwrite) BOOL isConstrained;
@property (atomic, readwrite) BOOL isExpensive;
@property (atomic, readwrite) BOOL hasPath;
@end

@implementation NetworkPathMonitor {
    dispatch_queue_t _queue;
    nw_path_monitor_t _monitor;
    BOOL _running;
    // Weak observer keys -> copied handler blocks
    NSMapTable *_observers;
}

+ (instancetype)sharedMonitor {
    static NetworkPathMonitor *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[NetworkPathMonitor alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // Default YES before first update: iPad clients are almost always Wi-Fi.
        _isWiFi = YES;
        _isConstrained = NO;
        _isExpensive = NO;
        _hasPath = NO;
        _running = NO;
        _queue = dispatch_queue_create("com.moonlight.NetworkPathMonitor", DISPATCH_QUEUE_SERIAL);
        _observers = [NSMapTable mapTableWithKeyOptions:(NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPersonality)
                                           valueOptions:(NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPersonality)];
    }
    return self;
}

- (void)start {
    @synchronized (self) {
        if (_running) {
            return;
        }
        // Unknown until the first callback for this session.
        self.hasPath = NO;
        self.isConstrained = NO;
        self.isExpensive = NO;
        self.isWiFi = YES;
        _running = YES;
        
        nw_path_monitor_t monitor = nw_path_monitor_create();
        nw_path_monitor_set_queue(monitor, _queue);
        
        __weak typeof(self) weakSelf = self;
        nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            [strongSelf applyPath:path];
        });
        
        _monitor = monitor;
        nw_path_monitor_start(monitor);
    }
}

- (void)stop {
    @synchronized (self) {
        if (!_running) {
            return;
        }
        _running = NO;
        if (_monitor != nil) {
            nw_path_monitor_cancel(_monitor);
            _monitor = nil;
        }
        // Force the next consumer to re-probe / wait for a fresh update.
        self.hasPath = NO;
        self.isConstrained = NO;
        self.isExpensive = NO;
        self.isWiFi = YES;
    }
}

- (void)applyPath:(nw_path_t)path {
    @synchronized (self) {
        if (!_running) {
            return;
        }
    }
    
    self.isWiFi = nw_path_uses_interface_type(path, nw_interface_type_wifi);
    self.isConstrained = nw_path_is_constrained(path);
    self.isExpensive = nw_path_is_expensive(path);
    self.hasPath = YES;
    
    NSArray *handlers;
    @synchronized (self) {
        if (!_running) {
            return;
        }
        handlers = [[_observers objectEnumerator] allObjects];
    }
    for (void (^handler)(NetworkPathMonitor *) in handlers) {
        handler(self);
    }
}

- (void)addObserver:(id)observer handler:(void (^)(NetworkPathMonitor *monitor))handler {
    if (observer == nil || handler == nil) {
        return;
    }
    @synchronized (self) {
        [_observers setObject:[handler copy] forKey:observer];
    }
}

- (void)removeObserver:(id)observer {
    if (observer == nil) {
        return;
    }
    @synchronized (self) {
        [_observers removeObjectForKey:observer];
    }
}

@end
