#import <Foundation/Foundation.h>
#import "ClassicChannels.h"
#import <sys/socket.h>
#import <unistd.h>

@interface FakeChannel : NSObject
@property uint16_t PSM;
@property NSInteger mode;
@property (copy) void (^reader)(NSArray *, NSError *);
@end
@implementation FakeChannel
- (void)readPacketsWithCompletionHandler:(void (^)(NSArray *, NSError *))callback { self.reader = callback; }
- (void)sendData:(NSData *)data withCompletion:(void (^)(NSError *, uint16_t, id))callback {
    if (self.mode == 2) return;
    callback(nil, self.mode == 1 ? 0 : data.length, nil);
    callback(nil, data.length, nil); // even a duplicate completion must not resume twice
}
@end
@interface FakeStreamChannel : FakeChannel
@property NSInputStream *inputStream;
@property NSOutputStream *outputStream;
@property int readFD;
@property int writeFD;
@end
@implementation FakeStreamChannel
- (instancetype)init {
    if ((self = [super init])) {
        int sockets[2];
        NSCAssert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0, @"test socket pair");
        _readFD = sockets[0]; _writeFD = sockets[1];
        CFReadStreamRef input;
        CFStreamCreatePairWithSocket(kCFAllocatorDefault, _readFD, &input, NULL);
        _inputStream = CFBridgingRelease(input);
        _outputStream = [NSOutputStream outputStreamToMemory];
    }
    return self;
}
- (void)dealloc { close(_readFD); close(_writeFD); }
- (BOOL)isPacketBased { return NO; }
- (void)readPacketsWithCompletionHandler:(void (^)(NSArray *, NSError *))callback { NSCAssert(NO, @"stream must not use packet reads"); }
- (void)sendData:(NSData *)data withCompletion:(void (^)(NSError *, uint16_t, id))callback { NSCAssert(NO, @"stream must not use packet writes"); }
@end
@interface FakePeer : NSObject
@property (copy) void (^connectL2CAPCallback)(id, NSInteger);
@property (copy) void (^disconnectL2CAPCallback)(id, NSInteger);
@property NSMutableArray *opened;
@end
@implementation FakePeer
- (instancetype)init { if ((self = [super init])) _opened = [NSMutableArray array]; return self; }
- (void)openL2CAPChannel:(uint16_t)psm { [self.opened addObject:@(psm)]; }
- (void)closeL2CAPChannel:(uint16_t)psm {}
@end
static void pump(NSTimeInterval seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (end.timeIntervalSinceNow > 0) [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:end];
}
int main(void) { @autoreleasepool {
    FakePeer *peer = [FakePeer new];
    TLClassicChannels *store = [[TLClassicChannels alloc] initWithPeer:peer];
    __block BOOL ready = NO;
    __block NSUInteger received = 0;
    store.changed = ^(BOOL value) { ready = value; };
    store.received = ^(uint16_t psm, NSData *data) { received++; };
    [store open];
    NSCAssert([peer.opened isEqual:@[@17]], @"control must open first");
    FakeChannel *control = [FakeChannel new]; control.PSM = 17;
    peer.connectL2CAPCallback(control, 0);
    NSCAssert((!ready && [peer.opened isEqual:@[@17,@19]]), @"requires both channels");
    __weak FakeChannel *weakInterrupt;
    @autoreleasepool {
        FakeChannel *interrupt = [FakeChannel new]; interrupt.PSM = 19;
        weakInterrupt = interrupt;
        peer.connectL2CAPCallback(interrupt, 0);
    }
    NSCAssert(ready && weakInterrupt, @"the transport must retain channels");
    control.reader(@[[NSData dataWithBytes:"a" length:1]], nil);
    pump(0.01);
    NSCAssert(received == 1, @"host packets delivered");
    __block NSInteger completed = 0;
    [store send:[NSData dataWithBytes:"ab" length:2] psm:19 completion:^(BOOL ok) { NSCAssert(ok, @"send succeeds"); completed++; }];
    pump(0.01);
    NSCAssert(completed == 1, @"completion exactly once");
    weakInterrupt.mode = 1;
    [store send:[NSData dataWithBytes:"ab" length:2] psm:19 completion:^(BOOL ok) { NSCAssert(!ok, @"partial send fails"); completed++; }];
    pump(0.01);
    NSCAssert(completed == 2, @"partial result once");
    NSCAssert(!ready, @"uncertain send clears readiness");
    [store open];
    peer.connectL2CAPCallback(control, 0);
    FakeChannel *hanging = [FakeChannel new]; hanging.PSM = 19; hanging.mode = 2;
    peer.connectL2CAPCallback(hanging, 0);
    [store send:[NSData dataWithBytes:"ab" length:2] psm:19 completion:^(BOOL ok) { NSCAssert(!ok, @"missing reply times out"); completed++; }];
    pump(3.2);
    NSCAssert(completed == 3, @"timeout once");
    peer.disconnectL2CAPCallback(hanging, 0);
    NSCAssert(!ready && ![store hasPSM:19], @"disconnect clears readiness");
    [store close];
    NSCAssert(![store hasPSM:17], @"close clears channels");
    [store open];
    FakeStreamChannel *streamControl = [FakeStreamChannel new]; streamControl.PSM = 17;
    FakeStreamChannel *streamInterrupt = [FakeStreamChannel new]; streamInterrupt.PSM = 19;
    peer.connectL2CAPCallback(streamControl, 0);
    peer.connectL2CAPCallback(streamInterrupt, 0);
    NSMutableArray<NSData *> *requests = [NSMutableArray array];
    store.received = ^(uint16_t psm, NSData *data) { [requests addObject:data]; };
    write(streamControl.writeFD, "\x52\x03", 2);
    pump(0.01);
    NSCAssert(requests.count == 0, @"partial LED request is buffered");
    write(streamControl.writeFD, "\x01\x60", 2);
    pump(0.01);
    NSCAssert(requests.count == 2 && requests[0].length == 3 && requests[1].length == 1, @"split and combined requests are framed");
    NSData *report = [NSData dataWithBytes:"\xA1\x01\x00\x08\x08\x00" length:6];
    [store send:report psm:19 completion:^(BOOL ok) { NSCAssert(ok, @"stream report succeeds"); completed++; }];
    NSCAssert(completed == 3, @"stream completion is paced before next report");
    pump(0.03);
    NSCAssert(completed == 4, @"stream completion arrives once");
    NSCAssert([[streamInterrupt.outputStream propertyForKey:NSStreamDataWrittenToMemoryStreamKey] isEqual:report], @"exact HID bytes reach output stream");
    [store close];
    NSCAssert(streamInterrupt.outputStream.streamStatus == NSStreamStatusClosed, @"disconnect closes streams");
    puts("PASS: channel ordering, retention, reads, send failures, timeout, disconnect");
} return 0; }
