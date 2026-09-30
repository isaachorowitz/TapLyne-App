#import "ClassicBridge.h"
#import "ClassicChannels.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <AppKit/AppKit.h>

#import "ClassicRuntime.h"

@interface TLClassicBridge ()
@property (nonatomic, strong, nullable) id<TLCBClassicManager> manager;
@property (nonatomic, strong, nullable) id<TLCBPairingAgent> agent;
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *retainedPeers;
@property (nonatomic, strong) NSMutableDictionary<NSString *, TLClassicChannels *> *channelStores;
@property (nonatomic, strong, nullable) id pairingPeer;
@property (nonatomic, strong, nullable) id intendedPairingPeer;
@property (nonatomic, strong, nullable) NSAlert *pairingAlert;
@property (nonatomic, strong, nullable) NSAlert *retryAlert;
@property (nonatomic, strong, nullable) NSTimer *pairingTimer;
@end

@implementation TLClassicBridge

- (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2) {
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (self.logHandler) self.logHandler(line);
}

- (void)start {
    [self startWithOptions:nil];
}

- (NSDictionary *)authorizationState {
    return @{ @"authorization": @([CBManager authorization]),
              @"agent_parent_matches": @([self.agent parentManager] == self.manager),
              @"agent_parent_present": @([self.agent parentManager] != nil),
              @"approved": @([self.manager tccApproved]),
              @"complete": @([self.manager tccComplete]),
              @"required": @([self.manager tccRequired]) };
}

- (void)requestBluetoothAuthorization {
    // Ask the OS to evaluate this manager through its normal consent flow.
    // Never set the approval flags ourselves. A denial remains a denial.
    if ([self.manager respondsToSelector:@selector(checkForTCC)]) {
        [self.manager checkForTCC];
    }
}

- (NSInteger)managerState {
    return self.manager ? [[(NSObject *)self.manager valueForKey:@"state"] integerValue] : -1;
}

- (void)startWithOptions:(nullable NSDictionary *)options {
    if (self.manager) return;
    Class cls = NSClassFromString(@"CBClassicManager");
    if (!cls || ![cls instancesRespondToSelector:@selector(addServiceWithData:)] ||
        ![cls instancesRespondToSelector:@selector(setConnectCallback:)] ||
        ![cls instancesRespondToSelector:@selector(setBTConnectable:)]) {
        [self log:@"CBClassicManager is not available on this macOS"];
        if (self.statusHandler) self.statusHandler(@"This macOS version does not provide the required Bluetooth interface.");
        return;
    }
    self.retainedPeers = [NSMutableDictionary dictionary];
    self.channelStores = [NSMutableDictionary dictionary];
    self.manager = [(id<TLCBClassicManager>)[cls alloc] initWithQueue:dispatch_get_main_queue() options:options];
    __weak typeof(self) weakSelf = self;
    [self.manager setConnectCallback:^(id<TLCBClassicPeer> peer, NSInteger error) {
        typeof(self) self = weakSelf;
        if (error) {
            if (self.statusHandler) self.statusHandler([NSString stringWithFormat:@"Bluetooth connection failed (%ld). Pair from the iPhone's Bluetooth settings.", (long)error]);
        } else if (self.retainedPeers[[[peer addressString] uppercaseString]] && [self.agent isPeerPaired:peer]) {
            [self openHIDAddress:[peer addressString]];
        }
    }];
    [self.manager setDisconnectCallback:^(id<TLCBClassicPeer> peer, NSInteger error) {
        [weakSelf closeHIDAddress:[peer addressString]];
    }];
    [self requestBluetoothAuthorization];
    self.agent = [self.manager sharedPairingAgent];
    [self.agent setDelegate:self];
    [self log:@"classic manager %@ agent %@", self.manager ? @"created" : @"nil", self.agent ? @"ready" : @"nil"];
}

- (NSInteger)powerState { return self.manager ? [self.manager powerState] : -1; }
- (BOOL)isDiscoverable { return [self.manager discoverable]; }
- (BOOL)isConnectable { return [self.manager connectable]; }

- (NSString *)describeLocalSDP {
    id db = [self.manager getLocalSDPDatabase];
    return [NSString stringWithFormat:@"%@: %@", NSStringFromClass([db class]), [[db description] substringToIndex:MIN((NSUInteger)6000, [[db description] length])]];
}

- (NSDictionary *)infoForPeer:(id<TLCBClassicPeer>)peer {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"name"] = [peer name] ?: @"";
    info[@"address"] = [peer addressString] ?: @"";
    info[@"state"] = @([peer state]);
    info[@"iphone"] = @([peer isiPhone]);
    if (self.agent) {
        info[@"paired"] = @([self.agent isPeerPaired:peer]);
        info[@"cloud_paired"] = @([self.agent isPeerCloudPaired:peer]);
        info[@"magic_paired"] = @([self.agent isPeerMagicPaired:peer]);
    }
    info[@"channels"] = [[peer L2CAPChannels] description] ?: @"";
    return info;
}

- (NSArray *)pairedPeers {
    id peers = [self.manager retrievePairedPeersWithOptions:nil];
    NSMutableArray *out = [NSMutableArray array];
    if ([peers respondsToSelector:@selector(countByEnumeratingWithState:objects:count:)]) {
        for (id peer in peers) [out addObject:[self infoForPeer:peer]];
    }
    return out;
}

- (NSArray *)knownPeers {
    NSMutableArray *out = [NSMutableArray array];
    for (id key in [self.manager peers]) {
        id peer = [[self.manager peers] objectForKey:key];
        if (peer) [out addObject:[self infoForPeer:peer]];
    }
    return out;
}

- (void)setDiscoverable:(BOOL)discoverable connectable:(BOOL)connectable {
    // These are asynchronous requests; asking synchronously produces a bogus
    // XPC "Connection interrupted" reply. Refresh the authoritative local state.
    [self.manager setBTConnectable:connectable];
    [self.manager setBTDiscoverable:discoverable];
    [self.manager sendLocalDeviceStateRequest];
}

- (uint32_t)addServiceData:(id)data {
    if ([data isKindOfClass:[NSDictionary class]]) {
        // CBClassicManager takes Apple's serialized SDP record, not Bluetooth
        // wire-format elements. Use the serializer used by IOBluetooth itself.
        Class serializerClass = NSClassFromString(@"BluetoothDeviceManager");
        if (![serializerClass respondsToSelector:@selector(sharedDeviceManager)]) return 0;
        id<TLSDPSerializer> serializer = [(id<TLSDPSerializer>)serializerClass sharedDeviceManager];
        if (![serializer respondsToSelector:@selector(_serviceToNSData:)]) return 0;
        data = [serializer _serviceToNSData:data];
    }
    if (![data isKindOfClass:[NSData class]]) return 0;
    uint32_t handle = [self.manager addServiceWithData:data];
    [self log:@"addServiceWithData -> handle %u", handle];
    return handle;
}

- (void)removeServiceHandle:(uint32_t)handle {
    [self.manager removeServiceHandle:handle];
}

- (nullable id<TLCBClassicPeer>)peerForAddress:(nullable NSString *)address {
    if (address) {
        NSString *key = [[address stringByReplacingOccurrencesOfString:@"-" withString:@":"] uppercaseString];
        id peer = self.retainedPeers[key];
        if (!peer) {
            peer = [self.manager retrievePeerWithAddress:key];
            if (peer) {
                self.retainedPeers[key] = peer;
                TLClassicChannels *channels = [[TLClassicChannels alloc] initWithPeer:peer];
                __weak typeof(self) weakSelf = self;
                channels.changed = ^(BOOL ready) { if (weakSelf.connectionHandler) weakSelf.connectionHandler(key, ready); };
                channels.received = ^(uint16_t psm, NSData *data) { if (weakSelf.dataHandler) weakSelf.dataHandler(key, psm, data); };
                channels.failed = ^(NSString *message) { if (weakSelf.statusHandler) weakSelf.statusHandler(message); };
                self.channelStores[key] = channels;
            }
        }
        return peer;
    }
    for (id key in [self.manager peers]) {
        id peer = [[self.manager peers] objectForKey:key];
        if (peer) return peer;
    }
    return nil;
}

- (BOOL)connectAddress:(NSString *)address {
    id<TLCBClassicPeer> peer = [self peerForAddress:address];
    if (!peer) return NO;
    if ([peer state] == 2) { [self openHIDAddress:address]; return YES; }
    [self.manager connectPeer:peer options:@{}];
    return YES;
}

- (BOOL)openPSM:(uint16_t)psm address:(NSString *)address {
    id<TLCBClassicPeer> peer = [self peerForAddress:address];
    if (!peer) return NO;
    [peer openL2CAPChannel:psm];
    return YES;
}

- (BOOL)hasChannelPSM:(uint16_t)psm address:(nullable NSString *)address {
    id<TLCBClassicPeer> peer = [self peerForAddress:address];
    if (!peer) return NO;
    return [self.channelStores[[[peer addressString] uppercaseString]] hasPSM:psm];
}

- (BOOL)isPairedAddress:(NSString *)address {
    id peer = [self peerForAddress:address];
    return peer && [self.agent isPeerPaired:peer];
}
- (void)openHIDAddress:(NSString *)address {
    id<TLCBClassicPeer> peer = [self peerForAddress:address];
    if (!peer) return;
    [self.channelStores[[[peer addressString] uppercaseString]] open];
}
- (void)closeHIDAddress:(NSString *)address { [self.channelStores[address.uppercaseString] close]; }
- (void)sendPacket:(NSData *)data psm:(uint16_t)psm address:(NSString *)address completion:(void (^)(BOOL))completion {
    TLClassicChannels *channels = self.channelStores[address.uppercaseString];
    if (!channels) { completion(NO); return; }
    [channels send:data psm:psm completion:completion];
}
- (void)stop {
    [self dismissPairingAlert];
    self.intendedPairingPeer = nil;
    self.pairingPeer = nil;
    [self.manager setBTDiscoverable:NO];
    for (TLClassicChannels *channels in self.channelStores.allValues) [channels close];
    [self.channelStores removeAllObjects];
    [self.retainedPeers removeAllObjects];
    [self.agent setDelegate:nil];
    self.agent = nil;
    self.manager = nil;
}

- (BOOL)sendData:(NSData *)data psm:(uint16_t)psm address:(nullable NSString *)address {
    id<TLCBClassicPeer> peer = [self peerForAddress:address];
    id<TLCBL2CAPChannel> channel = peer ? [peer channelWithPSM:psm] : nil;
    if (!channel) return NO;
    [channel sendData:data withCompletion:^(id result) {}];
    return YES;
}

- (void)pairAddress:(NSString *)address {
    if (self.pairingPeer) {
        [self log:@"A pairing request is already in progress"];
        return;
    }
    id peer = [self peerForAddress:address];
    if (peer) {
        [self log:@"pair request: peer retained, manager state %ld", (long)[self managerState]];
        self.pairingPeer = peer;
        self.intendedPairingPeer = peer;
        [self.manager connectPeer:peer options:@{@"kCBMsgIdSessionPairingRequest": @YES}];
    }
}

- (void)prepareIncomingPairing:(NSString *)address {
    self.intendedPairingPeer = [self peerForAddress:address];
    [self setDiscoverable:YES connectable:YES];
}

- (void)offerPairAddress:(NSString *)address {
    if (self.pairingPeer || self.retryAlert) return;
    NSWindow *window = NSApp.mainWindow;
    if (!window) {
        for (NSWindow *candidate in NSApp.windows) {
            if (candidate.isVisible && candidate.canBecomeMainWindow) { window = candidate; break; }
        }
    }
    if (!window) return;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Ready to pair your iPhone?";
    alert.informativeText = @"Open Settings > Bluetooth on your iPhone. Choose Retry when you are ready, then compare and approve the new code on both devices. The confirmation expires if left unanswered.";
    [alert addButtonWithTitle:@"Retry"];
    [alert addButtonWithTitle:@"Cancel"];
    self.retryAlert = alert;
    __weak typeof(self) weakSelf = self;
    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
        typeof(self) self = weakSelf;
        if (!self || self.retryAlert != alert) return;
        self.retryAlert = nil;
        if (response == NSAlertFirstButtonReturn) [self pairAddress:address];
    }];
}

- (void)unpairAddress:(NSString *)address {
    id peer = [self peerForAddress:address];
    if (peer) [self.agent unpairPeer:peer];
}

- (NSString *)describePeer:(NSString *)address {
    id peer = [self peerForAddress:address];
    return peer ? [[self infoForPeer:peer] description] : @"no peer";
}

// MARK: CBPairingAgentDelegate

- (void)dismissPairingAlert {
    [self.pairingTimer invalidate];
    self.pairingTimer = nil;
    NSAlert *alert = self.pairingAlert;
    self.pairingAlert = nil;
    if (alert.window.sheetParent) {
        [alert.window.sheetParent endSheet:alert.window returnCode:NSAlertSecondButtonReturn];
    }
}

- (void)pairingAgent:(id)agent peerDidRequestPairing:(id)peer type:(NSInteger)type passkey:(id)passkey {
    BOOL expected = self.intendedPairingPeer && [[peer identifier] isEqual:[self.intendedPairingPeer identifier]];
    [self log:@"pairing confirmation received for expected peer: %@", expected ? @"yes" : @"no"];
    if (!expected) {
        [self.agent respondToPairingRequest:peer type:type accept:NO data:nil];
        return;
    }
    self.pairingPeer = peer;
    if (self.statusHandler) self.statusHandler(@"Compare and approve the pairing code on both devices.");
    NSWindow *window = NSApp.mainWindow;
    if (!window) {
        for (NSWindow *candidate in NSApp.windows) {
            if (candidate.isVisible && candidate.canBecomeMainWindow) { window = candidate; break; }
        }
    }
    if (!window || self.pairingAlert) {
        [self.agent respondToPairingRequest:peer type:type accept:NO data:nil];
        self.pairingPeer = nil;
        [self log:@"Cannot show pairing confirmation; open the Taplyne window and retry"];
        return;
    }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Pair this iPhone with Taplyne?";
    alert.informativeText = passkey
        ? [NSString stringWithFormat:@"Confirm the code %@ matches the code on your iPhone, then choose Pair on both devices.", passkey]
        : @"Confirm the pairing request on your iPhone, then choose Pair.";
    [alert addButtonWithTitle:@"Pair"];
    [alert addButtonWithTitle:@"Cancel"];
    self.pairingAlert = alert;
    __weak typeof(self) weakSelf = self;
    // A modal run loop prevents the Bluetooth main-queue callbacks from closing
    // an expired request. A sheet leaves those callbacks free to run.
    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
        typeof(self) self = weakSelf;
        if (!self || self.pairingAlert != alert) return;
        [self.pairingTimer invalidate];
        self.pairingTimer = nil;
        self.pairingAlert = nil;
        BOOL accepted = response == NSAlertFirstButtonReturn;
        [self log:@"Pairing confirmation %@", accepted ? @"accepted" : @"cancelled"];
        NSDictionary *responseData = accepted && passkey ? @{@"kCBMsgArgPairingPasskey": passkey} : @{};
        [self.agent respondToPairingRequest:peer type:type accept:accepted data:responseData];
        if (!accepted) self.pairingPeer = nil;
    }];
    self.pairingTimer = [NSTimer scheduledTimerWithTimeInterval:25 repeats:NO block:^(NSTimer *timer) {
        typeof(self) self = weakSelf;
        if (!self || self.pairingAlert != alert) return;
        [self dismissPairingAlert];
        [self.agent respondToPairingRequest:peer type:type accept:NO data:nil];
        [self log:@"Pairing confirmation expired. Retry and confirm promptly on both devices."];
    }];
}

- (void)pairingAgent:(id)agent peerDidCompletePairing:(id)peer {
    if (![[peer identifier] isEqual:[self.intendedPairingPeer identifier]]) return;
    if ([[peer identifier] isEqual:[self.pairingPeer identifier]]) {
        [self dismissPairingAlert];
        self.pairingPeer = nil;
    }
    [self log:@"pairing completed with %@", [peer respondsToSelector:@selector(name)] ? [peer name] : @"?"];
    [self openHIDAddress:[peer addressString]];
    [self.manager setBTDiscoverable:NO];
    if (self.statusHandler) self.statusHandler(@"Paired. Opening the keyboard and mouse connection.");
}

- (void)pairingAgent:(id)agent peerDidFailToCompletePairing:(id)peer error:(id)error {
    if ([[peer identifier] isEqual:[self.pairingPeer identifier]]) {
        [self dismissPairingAlert];
        self.pairingPeer = nil;
    }
    [self log:@"pairing failed with %@: %@", [peer respondsToSelector:@selector(name)] ? [peer name] : @"?", error];
    if (self.statusHandler) self.statusHandler(@"Pairing failed. Open Bluetooth settings on the iPhone and select this Mac again.");
}

- (void)pairingAgent:(id)agent peerDidUnpair:(id)peer {
    [self log:@"unpaired %@", [peer respondsToSelector:@selector(name)] ? [peer name] : @"?"];
}

@end
