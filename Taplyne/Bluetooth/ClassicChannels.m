#import "ClassicChannels.h"

@protocol TLChannelPeer <NSObject>
- (void)setConnectL2CAPCallback:(nullable void (^)(id _Nullable, NSInteger))callback;
- (void)setDisconnectL2CAPCallback:(nullable void (^)(id _Nullable, NSInteger))callback;
- (void)openL2CAPChannel:(uint16_t)psm;
- (void)closeL2CAPChannel:(uint16_t)psm;
@end
@protocol TLChannel <NSObject>
- (uint16_t)PSM;
- (BOOL)isPacketBased;
- (NSInputStream *)inputStream;
- (NSOutputStream *)outputStream;
- (void)readPacketsWithCompletionHandler:(void (^)(NSArray<NSData *> * _Nullable, NSError * _Nullable))completion;
- (void)sendData:(NSData *)data withCompletion:(void (^)(NSError * _Nullable, uint16_t, id _Nullable))completion;
@end

@interface TLClassicChannels () <NSStreamDelegate>
@property (nonatomic, strong) id<TLChannelPeer> peer;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, id<TLChannel>> *channels;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSUUID *> *opening;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSDate *> *nextWrite;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSMutableData *> *incoming;
@property (nonatomic) BOOL active;
@end

@implementation TLClassicChannels
- (instancetype)initWithPeer:(id)peer {
    if ((self = [super init])) {
        _peer = peer;
        _channels = [NSMutableDictionary dictionary];
        _opening = [NSMutableDictionary dictionary];
        _nextWrite = [NSMutableDictionary dictionary];
        _incoming = [NSMutableDictionary dictionary];
        _active = YES;
        __weak typeof(self) weakSelf = self;
        [peer setConnectL2CAPCallback:^(id<TLChannel> channel, NSInteger error) {
            typeof(self) self = weakSelf;
            if (!self || !self.active) return;
            if (error || !channel) {
                [self.opening removeAllObjects];
                if (self.failed) self.failed([NSString stringWithFormat:@"Bluetooth channel failed (%ld).", (long)error]);
                return;
            }
            uint16_t psm = [channel PSM];
            if (psm != 17 && psm != 19) return;
            [self.opening removeObjectForKey:@(psm)];
            [self.incoming removeObjectForKey:@(psm)];
            self.channels[@(psm)] = channel;
            if ([channel respondsToSelector:@selector(isPacketBased)] && ![channel isPacketBased]) {
                for (NSStream *stream in @[[channel inputStream], [channel outputStream]]) {
                    stream.delegate = self;
                    [stream scheduleInRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
                    [stream open];
                }
            } else {
                [self read:channel];
            }
            if (psm == 17) [self open];
            if (self.changed) self.changed([self hasPSM:17] && [self hasPSM:19]);
        }];
        [peer setDisconnectL2CAPCallback:^(id<TLChannel> channel, NSInteger error) {
            typeof(self) self = weakSelf;
            if (!self || !channel) return;
            NSNumber *key = @([channel PSM]);
            if (self.channels[key] != channel) return;
            [self closeStreams:channel];
            [self.channels removeObjectForKey:key];
            [self.opening removeObjectForKey:key];
            [self.incoming removeObjectForKey:key];
            if (self.changed) self.changed(NO);
        }];
    }
    return self;
}
- (void)open {
    self.active = YES;
    for (NSNumber *psm in @[@17, @19]) {
        if (psm.unsignedShortValue == 19 && !self.channels[@17]) continue;
        if (self.channels[psm] || self.opening[psm]) continue;
        NSUUID *attempt = NSUUID.UUID;
        self.opening[psm] = attempt;
        [self.peer openL2CAPChannel:psm.unsignedShortValue];
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self || self.opening[psm] != attempt) return;
            [self close];
            if (self.failed) self.failed(@"The Bluetooth input channel timed out. Reconnect the iPhone.");
        });
    }
}
- (void)close {
    self.active = NO;
    for (id<TLChannel> channel in self.channels.allValues) [self closeStreams:channel];
    [self.peer closeL2CAPChannel:17];
    [self.peer closeL2CAPChannel:19];
    [self.channels removeAllObjects];
    [self.opening removeAllObjects];
    [self.nextWrite removeAllObjects];
    [self.incoming removeAllObjects];
    if (self.changed) self.changed(NO);
}
- (BOOL)hasPSM:(uint16_t)psm { return self.channels[@(psm)] != nil; }
- (void)closeStreams:(id<TLChannel>)channel {
    if (![channel respondsToSelector:@selector(isPacketBased)] || [channel isPacketBased]) return;
    for (NSStream *stream in @[[channel inputStream], [channel outputStream]]) {
        stream.delegate = nil;
        [stream removeFromRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        [stream close];
    }
}
- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)event {
    if (!self.active) return;
    id<TLChannel> channel = nil;
    for (id<TLChannel> candidate in self.channels.allValues) {
        if ([candidate inputStream] == stream || [candidate outputStream] == stream) { channel = candidate; break; }
    }
    if (!channel) return;
    if (event == NSStreamEventErrorOccurred || event == NSStreamEventEndEncountered) {
        NSString *message = stream.streamError.localizedDescription ?: @"Bluetooth input disconnected.";
        [self close];
        if (self.failed) self.failed(message);
    } else if (event == NSStreamEventHasBytesAvailable) {
        uint8_t bytes[1024];
        NSInteger count = [(NSInputStream *)stream read:bytes maxLength:sizeof(bytes)];
        if (count > 0) [self receiveStream:[NSData dataWithBytes:bytes length:count] psm:[channel PSM]];
    }
}
- (void)receiveStream:(NSData *)data psm:(uint16_t)psm {
    // Socket reads may split or combine HID control requests. Lengths correspond
    // to the report-mode descriptor and the control transactions in HIDSession.
    NSMutableData *buffer = self.incoming[@(psm)];
    if (!buffer) { buffer = [NSMutableData data]; self.incoming[@(psm)] = buffer; }
    [buffer appendData:data];
    while (self.active && buffer.length) {
        uint8_t header = ((const uint8_t *)buffer.bytes)[0];
        NSUInteger length = 1;
        switch (header & 0xf0) {
            case 0x40: length = (header & 8) ? 4 : 2; break;
            case 0x50: case 0xa0: length = 3; break; // keyboard LED output
            case 0x90: length = 2; break;
            default: break;
        }
        if (buffer.length < length) break;
        NSData *packet = [buffer subdataWithRange:NSMakeRange(0, length)];
        [buffer replaceBytesInRange:NSMakeRange(0, length) withBytes:NULL length:0];
        if (self.received) self.received(psm, packet);
    }
}
- (void)read:(id<TLChannel>)channel {
    __weak typeof(self) weakSelf = self;
    __weak id<TLChannel> weakChannel = channel;
    [channel readPacketsWithCompletionHandler:^(NSArray<NSData *> *packets, NSError *error) {
        // A fresh request is scheduled after the previous callback returns.
        // CoreBluetooth clears its pending reader after invoking that callback.
        NSArray *ownedPackets = [packets copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            id<TLChannel> channel = weakChannel;
            if (!self || !channel || self.channels[@([channel PSM])] != channel) return;
            if (error) {
                [self close];
                if (self.failed) self.failed(error.localizedDescription);
                return;
            }
            for (NSData *data in ownedPackets) {
                if ([data isKindOfClass:NSData.class] && self.received) self.received([channel PSM], data);
            }
            [self read:channel];
        });
    }];
}
- (void)send:(NSData *)data psm:(uint16_t)psm completion:(void (^)(BOOL))completion {
    id<TLChannel> channel = self.channels[@(psm)];
    if (!channel) { completion(NO); return; }
    // Classic channels are socket streams. The packet-only XPC API returns
    // kInterruptedErr for them even though the Bluetooth channels are connected.
    if ([channel respondsToSelector:@selector(isPacketBased)] && ![channel isPacketBased]) {
        [self sendStream:data channel:channel deadline:[NSDate dateWithTimeIntervalSinceNow:3] completion:completion];
        return;
    }
    // A missing daemon reply must not strand a Swift continuation or phone queue.
    __block BOOL completed = NO;
    __weak typeof(self) weakSelf = self;
    void (^finish)(BOOL) = ^(BOOL ok) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completed) return;
            completed = YES;
            if (!ok) [weakSelf close];
            completion(ok);
        });
    };
    [channel sendData:data withCompletion:^(NSError *error, uint16_t written, id context) {
        finish(error == nil && written == data.length);
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ finish(NO); });
}
- (void)sendStream:(NSData *)data channel:(id<TLChannel>)channel deadline:(NSDate *)deadline completion:(void (^)(BOOL))completion {
    if (!self.active || self.channels[@([channel PSM])] != channel) { completion(NO); return; }
    NSOutputStream *stream = [channel outputStream];
    NSNumber *psm = @([channel PSM]);
    if (stream.hasSpaceAvailable && self.nextWrite[psm].timeIntervalSinceNow <= 0) {
        NSInteger written = [stream write:data.bytes maxLength:data.length];
        BOOL ok = written == (NSInteger)data.length;
        // A partial HID packet cannot be retried as a new packet safely.
        if (!ok) [self close];
        // Back-to-back stream writes are coalesced into one L2CAP packet by
        // bluetoothd. HID requires one report per packet. Pace every report,
        // including anchoring and key releases, before accepting the next one.
        self.nextWrite[psm] = [NSDate dateWithTimeIntervalSinceNow:0.01];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            completion(ok && self.active && self.channels[psm] == channel);
        });
    } else if (deadline.timeIntervalSinceNow <= 0 || stream.streamStatus == NSStreamStatusError || stream.streamStatus == NSStreamStatusClosed) {
        [self close];
        completion(NO);
    } else {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (self) [self sendStream:data channel:channel deadline:deadline completion:completion];
            else completion(NO);
        });
    }
}
@end
