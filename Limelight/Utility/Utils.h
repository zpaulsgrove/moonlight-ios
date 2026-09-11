//
//  Utils.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

@interface Utils : NSObject

typedef NS_ENUM(int, PairState) {
    PairStateUnknown,
    PairStateUnpaired,
    PairStatePaired
};

typedef NS_ENUM(int, State) {
    StateUnknown,
    StateOffline,
    StateOnline
};

FOUNDATION_EXPORT NSString *const deviceName;

+ (NSData*) randomBytes:(NSInteger)length;
+ (NSString*) bytesToHex:(NSData*)data;
+ (NSData*) hexToBytes:(NSString*) hex;
+ (void) addHelpOptionToDialog:(UIAlertController*)dialog;
+ (BOOL)isActiveNetworkVPN;
+ (BOOL)isActiveNetworkWiFi;
// Drop any cached Wi-Fi probe so the next isActiveNetworkWiFi call re-probes once.
+ (void)invalidateActiveNetworkWiFiCache;
+ (BOOL)isPrivateAddress:(NSString*)address;

// Pure path helper for stream packet sizing (testable without live Network probes).
// VPN: REMOTE+1024; private LAN+Wi-Fi+aggressive: LOCAL+1392; private LAN+Wi-Fi: LOCAL+1024;
// private LAN wired: LOCAL+1392; else AUTO+1024.
+ (void)streamRemoteMode:(int*)streamingRemotely
              packetSize:(int*)packetSize
                   isVPN:(BOOL)isVPN
            isPrivateLAN:(BOOL)isPrivateLAN
                  isWiFi:(BOOL)isWiFi
   aggressiveWifiPackets:(BOOL)aggressiveWifiPackets;
+ (BOOL)isSunshineLineageAppVersion:(NSString*)appVersion;
+ (BOOL) parseAddressPortString:(NSString*)addressPort address:(NSRange*)address port:(NSRange*)port;
+ (NSString*) addressPortStringToAddress:(NSString*)addressPort;
+ (unsigned short) addressPortStringToPort:(NSString*)addressPort;
+ (NSString*) addressAndPortToAddressPortString:(NSString*)address port:(unsigned short)port;

#if !TARGET_OS_TV
+ (void) launchUrl:(NSString*)urlString;
#endif

@end

@interface NSString (NSStringWithTrim)

- (NSString*) trim;

@end
