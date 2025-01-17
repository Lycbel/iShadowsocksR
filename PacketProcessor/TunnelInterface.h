//
//  TunnelInterface.h
//
//  Created by LEI on 12/23/15.
//  Copyright © 2015 TouchingApp. All rights reserved.
//

#import <Foundation/Foundation.h>

@import NetworkExtension;

#define TunnelMTU 1600
#define kTun2SocksStoppedNotification @"kTun2SocksStoppedNotification"

@interface TunnelInterface : NSObject
+ (TunnelInterface *) sharedInterface;
- (instancetype) init NS_UNAVAILABLE;
- (NSError *) setupWithPacketTunnelFlow:(NEPacketTunnelFlow *)packetFlow;
- (void) processPackets : (int)socksServerPort;
- (void) writePacket:(NSData *)packet;
- (void) startTun2Socks:(int)socksServerPort;
- (void) stop;
@end
