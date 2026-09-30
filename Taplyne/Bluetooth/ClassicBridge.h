// Bridge to CoreBluetooth's private Classic Bluetooth API (CBClassicManager,
// CBClassicPeer, CBL2CAPChannel, CBPairingAgent). These interfaces are private;
// hardware compatibility must be verified on each supported macOS version.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TLClassicBridge : NSObject

@property (nonatomic, copy, nullable) void (^logHandler)(NSString *line);
@property (nonatomic, copy, nullable) void (^connectionHandler)(NSString *address, BOOL ready);
@property (nonatomic, copy, nullable) void (^dataHandler)(NSString *address, uint16_t psm, NSData *data);
@property (nonatomic, copy, nullable) void (^statusHandler)(NSString *message);

- (void)start;
- (void)stop;
- (BOOL)isPairedAddress:(NSString *)address;
- (void)openHIDAddress:(NSString *)address;
- (void)closeHIDAddress:(NSString *)address;
- (void)sendPacket:(NSData *)data psm:(uint16_t)psm address:(NSString *)address completion:(void (^)(BOOL))completion;
- (void)startWithOptions:(nullable NSDictionary *)options;
- (NSInteger)managerState;
- (NSDictionary<NSString *, id> *)authorizationState;
- (void)requestBluetoothAuthorization;
- (NSInteger)powerState;
- (BOOL)isDiscoverable;
- (BOOL)isConnectable;
- (NSString *)describeLocalSDP;
- (NSArray<NSDictionary<NSString *, id> *> *)pairedPeers;
- (NSArray<NSDictionary<NSString *, id> *> *)knownPeers;
- (void)setDiscoverable:(BOOL)discoverable connectable:(BOOL)connectable;
- (uint32_t)addServiceData:(id)data;
- (void)removeServiceHandle:(uint32_t)handle;
- (BOOL)connectAddress:(NSString *)address;
- (BOOL)openPSM:(uint16_t)psm address:(NSString *)address;
- (BOOL)hasChannelPSM:(uint16_t)psm address:(nullable NSString *)address;
- (BOOL)sendData:(NSData *)data psm:(uint16_t)psm address:(nullable NSString *)address;
- (void)pairAddress:(NSString *)address;
- (void)offerPairAddress:(NSString *)address;
- (void)prepareIncomingPairing:(NSString *)address;
- (void)unpairAddress:(NSString *)address;
- (NSString *)describePeer:(NSString *)address;

@end

NS_ASSUME_NONNULL_END
