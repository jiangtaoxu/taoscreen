#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

// 持有返回对象即可保留显示器。释放最后一个引用时，系统移除显示器。
NSObject * _Nullable TaoCreateVirtualDisplay(uint32_t width, uint32_t height, BOOL hiDPI,
    CGDirectDisplayID * _Nonnull displayID) NS_RETURNS_RETAINED;
