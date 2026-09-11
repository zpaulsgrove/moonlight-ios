//
//  Utils.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

// Pure encryption flag helper. Opt-in cleartext only on private LAN outside VPN.
FOUNDATION_EXPORT int MLStreamEncryptionFlags(BOOL disableOnLan, BOOL isPrivateLAN, BOOL isVPN);

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
// VPN or pathConstrained: force 1024. Private LAN+Wi-Fi on a clean path: LOCAL+1392
// (aggressiveWifiPackets still honored as YES; clean LAN Wi-Fi no longer requires it).
// Private LAN wired: LOCAL+1392. Else AUTO+1024.
+ (void)streamRemoteMode:(int*)streamingRemotely
              packetSize:(int*)packetSize
                   isVPN:(BOOL)isVPN
            isPrivateLAN:(BOOL)isPrivateLAN
                  isWiFi:(BOOL)isWiFi
   aggressiveWifiPackets:(BOOL)aggressiveWifiPackets
         pathConstrained:(BOOL)pathConstrained;

// Backward-compatible wrapper: pathConstrained=NO.
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
