#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#include <stdbool.h>
#include <string.h>

typedef id (*ObjectGetter)(id, SEL);
typedef bool (*FlagGetter)(id, SEL);
typedef long long (*StateGetter)(id, SEL);
typedef void (*ViewUpdate)(id, SEL);

@interface CALayer (ClearChargeInk)
- (CGColorRef)contentsMultiplyColor;
- (void)setContentsMultiplyColor:(CGColorRef)color;
@end

static Class statusBatteryClass;
static Class statusBarClass;
static Class systemStatusBatteryClass;
static bool resolvingFill;
static char originalInkKey;

static bool hasGetter(Class cls, SEL selector, const char *types) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 2) return false;

    char result[8] = {0};
    method_getReturnType(method, result, sizeof(result));
    return result[0] && strchr(types, result[0]) != NULL;
}

static bool isSystemStatusBattery(UIView *view) {
    // SystemStatusUI may load after the tweak. Resolve it on the main thread
    // when a battery renderer actually runs.
    if (!systemStatusBatteryClass) systemStatusBatteryClass = objc_lookUpClass("STUIStatusBarBatteryView");
    return systemStatusBatteryClass && [view isKindOfClass:systemStatusBatteryClass];
}

static bool isStatusBarBattery(UIView *view) {
    if (statusBatteryClass && [view isKindOfClass:statusBatteryClass]) return true;
    if (isSystemStatusBattery(view)) return true;
    for (UIView *parent = view.superview; parent; parent = parent.superview) {
        if (statusBarClass && [parent isKindOfClass:statusBarClass]) return true;
    }
    return false;
}

static bool hasGreenStatusBarCharge(UIView *view, bool steadyOnly) {
    if (!NSThread.isMainThread || resolvingFill || !isStatusBarBattery(view)) return false;

    // The on-device SystemStatusUI trace also showed green in state 3.
    // Use it for text only and keep native bolt handling outside state 1.
    SEL state = sel_registerName("chargingState");
    long long chargingState = ((StateGetter)objc_msgSend)(view, state);
    if (chargingState != 1 &&
        (steadyOnly || chargingState != 3 || !isSystemStatusBattery(view))) return false;

    // Guard against a fill implementation that consults either text getter.
    resolvingFill = true;
    id fill = ((ObjectGetter)objc_msgSend)(view, sel_registerName("_batteryFillColor"));
    CGFloat red, green, blue, alpha;
    bool isGreen = [fill isKindOfClass:UIColor.class]
        && [[fill resolvedColorWithTraitCollection:view.traitCollection]
            getRed:&red green:&green blue:&blue alpha:&alpha]
        && alpha >= 0.5 && green >= 0.35 && green > red + 0.05 && green > blue + 0.05;
    resolvingFill = false;
    return isGreen;
}

static void suppressFlagOnGreenCharge(Class cls, SEL selector, bool steadyOnly) {
    if (!hasGetter(cls, selector, "Bc")) return;

    __block IMP original = NULL;
    IMP hook = imp_implementationWithBlock(^bool(UIView *view) {
        if (hasGreenStatusBarCharge(view, steadyOnly)) return false;
        return ((FlagGetter)original)(view, selector);
    });
    MSHookMessageEx(cls, selector, hook, &original);
}

static void stylePercentageInk(UIView *view) {
    if (!NSThread.isMainThread || !isStatusBarBattery(view)) return;
    id candidate = ((ObjectGetter)objc_msgSend)(view, sel_registerName("percentageLabel"));
    if (![candidate isKindOfClass:UILabel.class]) return;
    UILabel *label = candidate;
    CALayer *layer = label.layer;
    id savedInk = objc_getAssociatedObject(layer, &originalInkKey);
    bool green = hasGreenStatusBarCharge(view, false);
    if (!green && !savedInk) return;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (green) {
        UIColor *black = UIColor.blackColor;
        if (layer.compositingFilter) layer.compositingFilter = nil;
        if (![label.textColor isEqual:black]) label.textColor = black;

        // Tint the actual glyph contents while keeping their alpha and geometry.
        // This also covers attributed glyphs whose foreground ignores textColor.
        if ([layer respondsToSelector:@selector(contentsMultiplyColor)] &&
            [layer respondsToSelector:@selector(setContentsMultiplyColor:)]) {
            CGColorRef currentInk = layer.contentsMultiplyColor;
            if (!currentInk || !CGColorEqualToColor(currentInk, black.CGColor)) {
                objc_setAssociatedObject(layer, &originalInkKey,
                    currentInk ? (__bridge id)currentInk : NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                layer.contentsMultiplyColor = black.CGColor;
            }
        }
    } else {
        layer.contentsMultiplyColor = savedInk == NSNull.null ? NULL : (__bridge CGColorRef)savedInk;
        objc_setAssociatedObject(layer, &originalInkKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [CATransaction commit];
}

static void installInkHook(Class cls) {
    SEL selector = sel_registerName("_updateFillColor");
    if (!hasGetter(cls, selector, "v") ||
        !hasGetter(cls, sel_registerName("percentageLabel"), "@")) return;

    __block IMP original = NULL;
    IMP hook = imp_implementationWithBlock(^(UIView *view) {
        ((ViewUpdate)original)(view, selector);
        stylePercentageInk(view);
    });
    MSHookMessageEx(cls, selector, hook, &original);
}

static void installRendererHooks(Class cls) {
    SEL text = sel_registerName("_batteryTextColor");
    SEL cutout = sel_registerName("_batteryTextIsCutout");
    Method cutoutMethod = class_getInstanceMethod(cls, cutout);
    if (!hasGetter(cls, text, "@") ||
        !hasGetter(cls, sel_registerName("_batteryFillColor"), "@") ||
        !hasGetter(cls, sel_registerName("chargingState"), "q") ||
        (cutoutMethod && !hasGetter(cls, cutout, "Bc"))) return;

    __block IMP originalText = NULL;
    IMP textHook = imp_implementationWithBlock(^id(UIView *view) {
        if (hasGreenStatusBarCharge(view, false)) return UIColor.blackColor;
        return ((ObjectGetter)originalText)(view, text);
    });
    MSHookMessageEx(cls, text, textHook, &originalText);

    suppressFlagOnGreenCharge(cls, cutout, false);

    installInkHook(cls);

    // The split status bar animates a separate charging item on connection.
    // Leave that item and its animation alone and suppress only the inline bolt.
    Class batteryItem = objc_lookUpClass("_UIStatusBarBatteryItem");
    Class splitProvider = objc_lookUpClass("_UIStatusBarVisualProvider_Split");
    if (class_getClassMethod(batteryItem, sel_registerName("chargingDisplayIdentifier")) &&
        hasGetter(batteryItem, sel_registerName("chargingView"), "@") &&
        hasGetter(splitProvider, sel_registerName("_additionAnimationForBatteryCharging"), "@")) {
        suppressFlagOnGreenCharge(cls, sel_registerName("_shouldShowBolt"), true);
    }
}

__attribute__((constructor)) static void installClearCharge(void) {
    statusBatteryClass = objc_lookUpClass("_UIStatusBarBatteryView");
    statusBarClass = objc_lookUpClass("_UIStatusBar");
    Class legacyBatteryClass = objc_lookUpClass("_UIBatteryView");
    if (statusBatteryClass) installRendererHooks(statusBatteryClass);
    if (legacyBatteryClass) installRendererHooks(legacyBatteryClass);
}
