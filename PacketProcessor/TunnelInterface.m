//
//  TunnelInterface.m
//
//  Created by LEI on 12/23/15.
//  Copyright © 2015 TouchingApp. All rights reserved.
//

#import "TunnelInterface.h"
#include <netinet/ip.h>
#include <netinet/in.h>
#import "ipv4/lwip/ip4.h"
#import "lwip/udp.h"
#import "lwip/ip.h"
#import <arpa/inet.h>
#import "inet_chksum.h"
#import "tun2socks/tun2socks.h"
#include "system/BAddr.h"
#include "misc/socks_proto.h"
@import CocoaAsyncSocket;
#define kTunnelInterfaceErrorDomain [NSString stringWithFormat:@"%@.TunnelInterface", [[NSBundle mainBundle] bundleIdentifier]]
#define DNS_QR 0x80
#define DNS_TC 0x02
#define DNS_RCODE 0x0F

@interface TunnelInterface () <GCDAsyncUdpSocketDelegate>
@property (nonatomic) NEPacketTunnelFlow *tunnelPacketFlow;
@property (nonatomic) NSMutableDictionary *localAddrByDnsReqId;
@property (nonatomic) GCDAsyncUdpSocket *udpSocket;
@property (nonatomic) int readFd;
@property (nonatomic) int writeFd;
@property (nonatomic) uint16_t socksServerPort;
@property(nonatomic) BOOL isUdpForwardingEnabled;
@property (nonatomic) dispatch_queue_t dispatchQueue;
@end

@implementation TunnelInterface {
    NEPacketTunnelFlow *_tunnelPacketFlow;
    NSMutableDictionary<NSString*, NSString*> *_udpSession;
    GCDAsyncUdpSocket *_udpSocket;
    int _readFd;
    int _writeFd;
}

+ (TunnelInterface *) sharedInterface {
    static dispatch_once_t onceToken;
    static TunnelInterface *interface;
    dispatch_once(&onceToken, ^{
        interface = [TunnelInterface new];
    });
    return interface;
}

- (instancetype) init {
    self = [super init];
    if (self) {
        _udpSession = [NSMutableDictionary dictionaryWithCapacity:5];
        _udpSocket = [[GCDAsyncUdpSocket alloc] initWithDelegate:self delegateQueue:dispatch_queue_create("udp", NULL)];
        
        int fds[2] = { 0 };
        pipe(fds);
        _readFd = fds[0];
        _writeFd = fds[1];
    }
    return self;
}

- (void) dealloc {
    if (_readFd) { close(_readFd); }
    if (_writeFd) { close(_writeFd); }
}

- (NSError *) setupWithPacketTunnelFlow:(NEPacketTunnelFlow *)packetFlow {
    if (packetFlow == nil) {
        return [NSError errorWithDomain:kTunnelInterfaceErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: @"PacketTunnelFlow can't be nil."}];
    }
    _tunnelPacketFlow = packetFlow;
    
    NSError *error;
    [_udpSocket bindToPort:0 error:&error];
    if (error) {
        return [NSError errorWithDomain:kTunnelInterfaceErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"UDP bind fail(%@).", [error localizedDescription]]}];
    }
    [_udpSocket beginReceiving:&error];
    if (error) {
        return [NSError errorWithDomain:kTunnelInterfaceErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"UDP bind fail(%@).", [error localizedDescription]]}];
    }
    return nil;
}

- (void) startTun2Socks:(int)socksServerPort {
    dispatch_async(dispatch_queue_create(NULL, DISPATCH_QUEUE_CONCURRENT), ^{
        [self _startTun2Socks:socksServerPort];
    });
}

- (void) stop {
    stop_tun2socks();
}

- (void) writePacket:(NSData *)packet {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_tunnelPacketFlow writePackets:@[packet] withProtocols:@[@(AF_INET)]];
    });
}

- (void) processPackets: (int)socksServerPort  {
    __weak typeof(self) weakSelf = self;
    [_tunnelPacketFlow readPacketsWithCompletionHandler:^(NSArray<NSData *> *packets, NSArray<NSNumber *> *protocols) {
        __strong typeof(self) strongSelf = weakSelf;
        for (NSData *packet in packets) {
            uint8_t *data = (uint8_t *)packet.bytes;
            struct ip_hdr *iphdr = (struct ip_hdr *)data;
            uint8_t proto = IPH_PROTO(iphdr);
            if (proto == IP_PROTO_UDP) {
                [strongSelf handleUdpPacket:packet needPort: socksServerPort];
            }else if (proto == IP_PROTO_TCP) {
                [strongSelf handleTcpPacket:packet];
            }
        }
        [strongSelf processPackets : socksServerPort];
    }];
}

- (void) _startTun2Socks:(int)socksServerPort {
    char socks_server[50];
    sprintf(socks_server, "127.0.0.1:%d", (int)socksServerPort);
    char ssocks_server[50];
    sprintf(ssocks_server, "127.0.0.1:%d", (int)socksServerPort -1 );
#if TCP_DATA_LOG_ENABLE
    char *log_lvel = "debug";
#else
    char *log_lvel = "none";
#endif
    char *argv[] = {
        "tun2socks",
        "--netif-ipaddr",
        "192.0.2.4",
        "--netif-netmask",
        "255.255.255.0",
        "--loglevel",
        log_lvel,
        "--socks-server-addr",
        socks_server,
        "--ssocks-server-addr",
        ssocks_server
    };
    tun2socks_main(sizeof(argv)/sizeof(argv[0]), argv, _readFd, TunnelMTU);
    [[NSNotificationCenter defaultCenter] postNotificationName:kTun2SocksStoppedNotification object:nil];
}

- (void) handleTcpPacket:(NSData *)packet  {
    uint8_t message[TunnelMTU+2];
    memcpy(message + 2, packet.bytes, packet.length);
    message[0] = packet.length / 256;
    message[1] = packet.length % 256;
    write(_writeFd , message , packet.length + 2);
}
- (void) handleUdpPacket:(NSData *)packet needPort: (int)socksServerPort  {
     //[self handleTcpPacket:packet];
//   uint8_t *data = (uint8_t *)packet.bytes;
//   size_t data_len = (size_t)packet.length;
//
//   struct ip_hdr *iphdr = (struct ip_hdr *)data;
//   uint8_t version = IPH_V(iphdr);
//   size_t iphdr_hlen = IPH_HL(iphdr) * 4;
//   data = data + iphdr_hlen;
//   data_len -= iphdr_hlen;
//     struct in_addr ddest = { iphdr->dest.addr };
//     struct in_addr sdest = { iphdr->src.addr };
//     NSString *destHost = [NSString stringWithUTF8String:inet_ntoa(ddest)];
//     NSString *srcHost = [NSString stringWithUTF8String:inet_ntoa(sdest)];
//    NSLog(@"source ip%@", srcHost);
//    NSLog(@"dest ip%@", destHost);
//
//   struct udp_hdr *udphdr = (struct udp_hdr *)data;
//      NSLog(@"dest ip%u-from->%u", (unsigned int)udphdr->dest, (unsigned int)udphdr->src);
//   data = data + sizeof(struct udp_hdr *);
//   data_len -= sizeof(struct udp_hdr *);
//    uint16_t rlen = 0;
//    if(version==4) {
//        rlen = 8;
//    } else if(version ==6) {
//        rlen = 32;
//    }
//    rlen += 2;
//    rlen += 4;
//    rlen += data_len;
//    uint8_t message [rlen];
//    uint8_t *mem = message;
//    mem+=1;
//    *((uint16_t *)  mem) = rlen;
//    if(version == 4) {
//        mem+=2;
//        *((uint32_t *)  mem) = iphdr->src.addr;
//        mem+=4;
//        *((uint16_t *)  mem) = udphdr->src;
//        mem+=2;
//        *((uint32_t *)  mem) = iphdr->dest.addr;
//        mem+=4;
//        *((uint16_t *)  mem) = udphdr->dest;
//        mem+=2;
//    }else if(version ==6) {
//        rlen = 32;
//    }
//
//    memcpy(mem, data, (size_t)data_len);
//    message[0] = version;
//    NSData *outData = [[NSData alloc] initWithBytes:message length:rlen];
//    [_udpSocket sendData:outData toHost:@"127.0.0.1" port:socksServerPort withTimeout:10 tag:0];
    
//    NSLog(@"get udp");
//    uint8_t *data = (uint8_t *)packet.bytes;
//    int data_len = (int)packet.length;
//    struct ip_hdr *iphdr = (struct ip_hdr *)data;
//    uint8_t version = IPH_V(iphdr);
//
//    switch (version) {
//        case 4: {
//            uint16_t iphdr_hlen = IPH_HL(iphdr) * 4;
//            data = data + iphdr_hlen;
//            data_len -= iphdr_hlen;
//            struct udp_hdr *udphdr = (struct udp_hdr *)data;
//
//            data = data + sizeof(struct udp_hdr *);
//            data_len -= sizeof(struct udp_hdr *);
//
//            NSData *outData = [[NSData alloc] initWithBytes:data length:data_len];
//            struct in_addr dest = { iphdr->dest.addr };
//            NSString *destHost = [NSString stringWithUTF8String:inet_ntoa(dest)];
//            NSString *key = [self strForHost:iphdr->dest.addr port:udphdr->dest];
//            NSString *value = [self strForHost:iphdr->src.addr port:udphdr->src];;
//            _udpSession[key] = value;
//            [_udpSocket sendData:outData toHost:destHost port:ntohs(udphdr->dest) withTimeout:10 tag:0];
//        } break;
//        case 6: {
//
//        } break;
//    }
    

        NSLog(@"get udp");
        uint8_t *data = (uint8_t *)packet.bytes;
        int data_len = (int)packet.length;
        struct ip_hdr *iphdr = (struct ip_hdr *)data;
        uint8_t version = IPH_V(iphdr);

    switch (version) {
                    case 4: {
                        uint16_t iphdr_hlen = IPH_HL(iphdr) * 4;
                        data = data + iphdr_hlen;
                        data_len -= iphdr_hlen;
                        struct udp_hdr *udphdr = (struct udp_hdr *)data;
                        data = data + sizeof(struct udp_hdr *);
                        data_len -= sizeof(struct udp_hdr *);
                        NSLog(@"get udp end0");
                        uint8_t message [data_len + 1];
                        NSLog(@"get udp end0.1");
                        *message = (uint8_t) 1;
                        memcpy(message+1, data, data_len);
                        NSString *key = [self strForHost:iphdr->dest.addr port:udphdr->dest];
                        NSString *value = [self strForHost:iphdr->src.addr port:udphdr->src];
                        _udpSession[key] = value;
                        NSData *outData = [[NSData alloc] initWithBytes:message length:data_len + 1];
                        [_udpSocket sendData:outData toHost:@"127.0.0.1" port:socksServerPort withTimeout:10 tag:0];
                         NSLog(@"get udp end3");
                    } break;
                    case 6: {

                    } break;
                }
}

- (void) udpSocket:(GCDAsyncUdpSocket *)sock didReceiveData:(NSData *)data fromAddress:(NSData *)address withFilterContext:(id)filterContext {
    NSLog(@"did receive data");
    const struct sockaddr_in *addr = (const struct sockaddr_in *)[address bytes];
    ip_addr_p_t dest ={ addr->sin_addr.s_addr };
    in_port_t dest_port = addr->sin_port;
    NSString *strHostPort = _udpSession[[self strForHost:dest.addr port:dest_port]];
    NSArray *hostPortArray = [strHostPort componentsSeparatedByString:@":"];
    int src_ip = [hostPortArray[0] intValue];
    int src_port = [hostPortArray[1] intValue];
    uint8_t *bytes = (uint8_t *)[data bytes];
    int bytes_len = (int)data.length;
    int udp_length = sizeof(struct udp_hdr) + bytes_len;
    int total_len = IP_HLEN + udp_length;
    
    ip_addr_p_t src = {src_ip};
    struct ip_hdr *iphdr = generateNewIpHeader(IP_PROTO_UDP, dest, src, total_len);
    
    struct udp_hdr udphdr;
    udphdr.src = dest_port;
    udphdr.dest = src_port;
    udphdr.len = hton16(udp_length);
    udphdr.chksum = hton16(0);
    
    uint8_t *udpdata = malloc(sizeof(uint8_t) * udp_length);
    memcpy(udpdata, &udphdr, sizeof(struct udp_hdr));
    memcpy(udpdata + sizeof(struct udp_hdr), bytes, bytes_len);
    
    ip_addr_t odest = { dest.addr };
    ip_addr_t osrc = { src_ip };
    
    struct pbuf *p_udp = pbuf_alloc(PBUF_TRANSPORT, udp_length, PBUF_RAM);
    pbuf_take(p_udp, udpdata, udp_length);
    
    struct udp_hdr *new_udphdr = (struct udp_hdr *) p_udp->payload;
    new_udphdr->chksum = inet_chksum_pseudo(p_udp, IP_PROTO_UDP, p_udp->len, &odest, &osrc);
    
    uint8_t *ipdata = malloc(sizeof(uint8_t) * total_len);
    memcpy(ipdata, iphdr, IP_HLEN);
    memcpy(ipdata + sizeof(struct ip_hdr), p_udp->payload, udp_length);
    
    NSData *outData = [[NSData alloc] initWithBytes:ipdata length:total_len];
    free(ipdata);
    free(iphdr);
    free(udpdata);
    pbuf_free(p_udp);
    [self writePacket:outData];
}

//- (void) udpSocket:(GCDAsyncUdpSocket *)sock didReceiveData:(NSData *)data fromAddress:(NSData *)address withFilterContext:(id)filterContext {
//    NSLog(@"did receive data");
//    const struct sockaddr_in *addr = (const struct sockaddr_in *)[address bytes];
//    ip_addr_p_t dest ={ addr->sin_addr.s_addr };
//    in_port_t dest_port = addr->sin_port;
//    NSString *strHostPort = _udpSession[[self strForHost:dest.addr port:dest_port]];
//    NSArray *hostPortArray = [strHostPort componentsSeparatedByString:@":"];
//    int src_ip = [hostPortArray[0] intValue];
//    int src_port = [hostPortArray[1] intValue];
//    uint8_t *bytes = (uint8_t *)[data bytes];
//    int bytes_len = (int)data.length;
//    int udp_length = sizeof(struct udp_hdr) + bytes_len;
//    int total_len = IP_HLEN + udp_length;
//
//    ip_addr_p_t src = {src_ip};
//    struct ip_hdr *iphdr = generateNewIpHeader(IP_PROTO_UDP, dest, src, total_len);
//
//    struct udp_hdr udphdr;
//    udphdr.src = dest_port;
//    udphdr.dest = src_port;
//    udphdr.len = hton16(udp_length);
//    udphdr.chksum = hton16(0);
//
//    uint8_t *udpdata = malloc(sizeof(uint8_t) * udp_length);
//    memcpy(udpdata, &udphdr, sizeof(struct udp_hdr));
//    memcpy(udpdata + sizeof(struct udp_hdr), bytes, bytes_len);
//
//    ip_addr_t odest = { dest.addr };
//    ip_addr_t osrc = { src_ip };
//
//    struct pbuf *p_udp = pbuf_alloc(PBUF_TRANSPORT, udp_length, PBUF_RAM);
//    pbuf_take(p_udp, udpdata, udp_length);
//
//    struct udp_hdr *new_udphdr = (struct udp_hdr *) p_udp->payload;
//    new_udphdr->chksum = inet_chksum_pseudo(p_udp, IP_PROTO_UDP, p_udp->len, &odest, &osrc);
//
//    uint8_t *ipdata = malloc(sizeof(uint8_t) * total_len);
//    memcpy(ipdata, iphdr, IP_HLEN);
//    memcpy(ipdata + sizeof(struct ip_hdr), p_udp->payload, udp_length);
//
//    NSData *outData = [[NSData alloc] initWithBytes:ipdata length:total_len];
//    free(ipdata);
//    free(iphdr);
//    free(udpdata);
//    pbuf_free(p_udp);
//    [self writePacket:outData];
//}
struct ip_hdr * generateNewIpHeader(u8_t proto, ip_addr_p_t src, ip_addr_p_t dest, uint16_t total_len) {
    struct ip_hdr *iphdr = malloc(sizeof(struct ip_hdr));
    IPH_VHL_SET(iphdr, 4, IP_HLEN / 4);
    IPH_TOS_SET(iphdr, 0);
    IPH_LEN_SET(iphdr, htons(total_len));
    IPH_ID_SET(iphdr, 0);
    IPH_OFFSET_SET(iphdr, 0);
    IPH_TTL_SET(iphdr, 64);
    IPH_PROTO_SET(iphdr, IP_PROTO_UDP);
    iphdr->src = src;
    iphdr->dest = dest;
    IPH_CHKSUM_SET(iphdr, 0);
    IPH_CHKSUM_SET(iphdr, inet_chksum(iphdr, IP_HLEN));
    return iphdr;
}

- (NSString *) strForHost:(int)host port:(int)port {
    return [NSString stringWithFormat:@"%d:%d",host, port];
}

@end
