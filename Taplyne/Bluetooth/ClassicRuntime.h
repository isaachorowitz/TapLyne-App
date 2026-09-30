#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

// Private selectors, declared so the compiler can type the sends. They match the
// method type encodings CoreBluetooth reports at runtime on macOS 27.
@protocol TLCBClassicManager <NSObject>
- (instancetype)initWithQueue:(dispatch_queue_t)queue options:(nullable NSDictionary *)options;
- (NSInteger)powerState;
- (BOOL)tccApproved;
- (BOOL)tccComplete;
- (BOOL)tccRequired;
- (void)checkForTCC;
- (BOOL)discoverable;
- (BOOL)connectable;
- (void)setBTDiscoverable:(BOOL)on;
- (void)setBTConnectable:(BOOL)on;
- (uint32_t)addServiceWithData:(id)data;
- (void)removeServiceHandle:(uint32_t)handle;
- (id)getLocalSDPDatabase;
- (id)retrievePairedPeersWithOptions:(nullable NSDictionary *)options;
- (id)retrievePeerWithAddress:(NSString *)address;
- (void)connectPeer:(id)peer options:(nullable NSDictionary *)options;
- (id)sharedPairingAgent;
- (void)setConnectCallback:(void (^)(id, NSInteger))callback;
- (void)setDisconnectCallback:(void (^)(id, NSInteger))callback;
- (NSMapTable *)peers;
- (id)sendSyncMsg:(uint16_t)message args:(NSDictionary *)args;
- (void)sendLocalDeviceStateRequest;
@end

@protocol TLCBClassicPeer <NSObject>
- (NSString *)name;
- (NSUUID *)identifier;
- (NSString *)addressString;
- (NSInteger)state;
- (BOOL)isiPhone;
- (BOOL)isAppleDevice;
- (id)services;
- (id)L2CAPChannels;
- (void)openL2CAPChannel:(uint16_t)psm;
- (id)channelWithPSM:(uint16_t)psm;
@end

@protocol TLCBL2CAPChannel <NSObject>
- (uint16_t)PSM;
- (int)socketFD;
- (BOOL)isIncoming;
- (void)sendData:(NSData *)data withCompletion:(void (^)(id))completion;
@end

@protocol TLCBPairingAgent <NSObject>
- (void)setDelegate:(nullable id)delegate;
- (id)parentManager;
- (BOOL)isPeerPaired:(id)peer;
- (BOOL)isPeerCloudPaired:(id)peer;
- (BOOL)isPeerMagicPaired:(id)peer;
- (void)pairPeer:(id)peer;
- (void)unpairPeer:(id)peer;
- (void)respondToPairingRequest:(id)peer type:(NSInteger)type accept:(BOOL)accept data:(nullable NSDictionary *)data;
@end

@protocol TLSDPSerializer <NSObject>
+ (id)sharedDeviceManager;
- (NSData *)_serviceToNSData:(NSDictionary *)record;
@end
NS_ASSUME_NONNULL_END
