#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Owns the two HID channels for one peer. CoreBluetooth retains them weakly.
@interface TLClassicChannels : NSObject
@property (nonatomic, copy, nullable) void (^changed)(BOOL ready);
@property (nonatomic, copy, nullable) void (^received)(uint16_t psm, NSData *data);
@property (nonatomic, copy, nullable) void (^failed)(NSString *message);
- (instancetype)initWithPeer:(id)peer;
- (void)open;
- (void)close;
- (BOOL)hasPSM:(uint16_t)psm;
- (void)send:(NSData *)data psm:(uint16_t)psm completion:(void (^)(BOOL))completion;
@end
NS_ASSUME_NONNULL_END
