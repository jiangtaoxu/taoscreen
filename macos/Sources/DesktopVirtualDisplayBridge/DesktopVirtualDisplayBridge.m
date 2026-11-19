#import "include/DesktopVirtualDisplayBridge.h"
#import <dispatch/dispatch.h>

// CoreGraphics 未在公开 SDK 中声明这些类。这里列出用于创建扩展屏的
// Objective-C 方法签名，并在调用前检查系统是否提供它们。
@interface TaoVirtualDisplayDescriptor : NSObject
@property (nonatomic, strong) NSString *name;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic) uint32_t vendorID;
@property (nonatomic) uint32_t productID;
@property (nonatomic) uint32_t serialNum;
@property (nonatomic) uint32_t serialNumber;
@property (nonatomic) uint32_t maxPixelsWide;
@property (nonatomic) uint32_t maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic) CGPoint whitePoint;
@end

@interface TaoVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height refreshRate:(double)refreshRate;
@end

@interface TaoVirtualDisplaySettings : NSObject
@property (nonatomic, strong) NSArray<TaoVirtualDisplayMode *> *modes;
@property (nonatomic) uint32_t hiDPI;
@end

@interface TaoVirtualDisplay : NSObject
@property (nonatomic, readonly) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(TaoVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(TaoVirtualDisplaySettings *)settings;
@end

static BOOL SupportsSelectors(Class cls, const SEL selectors[]) {
    if (!cls) { return NO; }
    for (const SEL *selector = selectors; *selector; ++selector) {
        if (![cls instancesRespondToSelector:*selector]) { return NO; }
    }
    return YES;
}

NSObject *TaoCreateVirtualDisplay(uint32_t width, uint32_t height, BOOL hiDPI, CGDirectDisplayID *displayID) {
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");

    if (!SupportsSelectors(descriptorClass, (const SEL[]){
        @selector(setName:), @selector(setQueue:), @selector(setVendorID:), @selector(setProductID:),
        @selector(setSerialNum:), @selector(setSerialNumber:), @selector(setMaxPixelsWide:), @selector(setMaxPixelsHigh:),
        @selector(setSizeInMillimeters:), @selector(setRedPrimary:), @selector(setGreenPrimary:),
        @selector(setBluePrimary:), @selector(setWhitePoint:), NULL
    }) || !SupportsSelectors(modeClass, (const SEL[]){ @selector(initWithWidth:height:refreshRate:), NULL })
       || !SupportsSelectors(settingsClass, (const SEL[]){ @selector(setModes:), @selector(setHiDPI:), NULL })
       || !SupportsSelectors(displayClass, (const SEL[]){ @selector(initWithDescriptor:), @selector(applySettings:),
                                                         @selector(displayID), NULL })) {
        return nil;
    }

    TaoVirtualDisplayDescriptor *descriptor = [[descriptorClass alloc] init];
    TaoVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    uint32_t scale = hiDPI ? 2 : 1;
    TaoVirtualDisplayMode *mode = [[modeClass alloc] initWithWidth:width / scale
                                                          height:height / scale
                                                     refreshRate:60.0];
    if (!descriptor || !settings || !mode) { return nil; }

    descriptor.name = @"TaoScreen 虚拟屏";
    descriptor.queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    descriptor.vendorID = 0x5441;
    descriptor.productID = 1;
    // 每次使用独立的显示器身份，避免复用前一次会话的系统镜像及布局设置。
    uint32_t serial = arc4random_uniform(INT32_MAX) + 1;
    descriptor.serialNum = serial;
    descriptor.serialNumber = serial;
    descriptor.maxPixelsWide = width;
    descriptor.maxPixelsHigh = height;
    descriptor.sizeInMillimeters = CGSizeMake(25.4 * width / (110 * scale), 25.4 * height / (110 * scale));
    descriptor.redPrimary = CGPointMake(0.64, 0.33);
    descriptor.greenPrimary = CGPointMake(0.30, 0.60);
    descriptor.bluePrimary = CGPointMake(0.15, 0.06);
    descriptor.whitePoint = CGPointMake(0.3127, 0.3290);
    settings.hiDPI = hiDPI;
    settings.modes = @[mode];

    TaoVirtualDisplay *display = [[displayClass alloc] initWithDescriptor:descriptor];
    if (!display || ![display applySettings:settings]) { return nil; }
    *displayID = display.displayID;
    return display;
}
