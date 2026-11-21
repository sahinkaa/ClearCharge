#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <substrate.h>
#include <string.h>

static CGContextRef artworkBitmap(CGSize size, CGFloat scale, void (^draw)(void)) {
    size_t width = (size_t)ceil(size.width * scale);
    size_t height = (size_t)ceil(size.height * scale);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space,
        (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!bitmap) return NULL;

    CGContextTranslateCTM(bitmap, 0, height);
    CGContextScaleCTM(bitmap, scale, -scale);
    UIGraphicsPushContext(bitmap);
    draw();
    UIGraphicsPopContext();
    return bitmap;
}

static CGRect paintedPixelBounds(CGContextRef bitmap) {
    size_t width = CGBitmapContextGetWidth(bitmap), height = CGBitmapContextGetHeight(bitmap);
    size_t stride = CGBitmapContextGetBytesPerRow(bitmap);
    const unsigned char *pixels = CGBitmapContextGetData(bitmap);
    size_t left = width, top = height, right = 0, bottom = 0;
    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            if (pixels[y * stride + x * 4 + 3] <= 16) continue;
            left = MIN(left, x);
            top = MIN(top, y);
            right = MAX(right, x + 1);
            bottom = MAX(bottom, y + 1);
        }
    }
    return right > left && bottom > top ? CGRectMake(left, top, right - left, bottom - top) : CGRectZero;
}

static UIImage *chargingBoltImage(void) {
    static UIImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIImage *symbol = [UIImage systemImageNamed:@"bolt.fill"
                                  withConfiguration:[UIImageSymbolConfiguration configurationWithWeight:UIImageSymbolWeightSemibold]];
        image = [symbol imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        if (!symbol) return;

        // Trim the transparent margins so the frame tracks the visible bolt.
        const CGFloat scale = 4;
        CGContextRef bitmap = artworkBitmap(symbol.size, scale, ^{
            [symbol drawInRect:(CGRect){CGPointZero, symbol.size}];
        });
        if (!bitmap) return;
        CGRect ink = paintedPixelBounds(bitmap);
        CGImageRef rendered = CGRectIsEmpty(ink) ? NULL : CGBitmapContextCreateImage(bitmap);
        CGContextRelease(bitmap);
        if (!rendered) return;
        CGImageRef cropped = CGImageCreateWithImageInRect(rendered, ink);
        CGImageRelease(rendered);
        if (!cropped) return;
        UIImage *bolt = [UIImage imageWithCGImage:cropped scale:scale orientation:UIImageOrientationUp];
        CGImageRelease(cropped);
        image = [bolt imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    });
    return image;
}

@interface ClearChargeDisplay : NSObject
@property (nonatomic, readonly) CALayer *layer;
@property (nonatomic, readonly) UILabel *number;
@property (nonatomic, readonly) UIImageView *bolt;
@property (nonatomic, readonly) CALayer *stockMask;
@property (nonatomic, strong) CALayer *nativeMask;
@property (nonatomic) CGRect digitInkBounds;
@property (nonatomic) CGFloat digitMeasurementScale;
@end

@implementation ClearChargeDisplay
- (instancetype)init {
    self = [super init];
    if (self) {
        _layer = [CALayer layer];
        _number = [UILabel new];
        _number.textAlignment = NSTextAlignmentRight;
        [_layer addSublayer:_number.layer];

        _bolt = [[UIImageView alloc] initWithImage:chargingBoltImage()];
        _bolt.contentMode = UIViewContentModeScaleAspectFit;
        [_layer addSublayer:_bolt.layer];
        _stockMask = [CALayer layer];
    }
    return self;
}
@end

static Class legacyBarClass;
static Class modernBarClass;
static Class legacyBatteryClass;
static Class modernBatteryClass;
static Class legacyStaticBatteryClass;
static Class modernStaticBatteryClass;
static BOOL isSpringBoard;
static const CGFloat numberTrailingSpace = 9.5;
static const CGFloat boltGap = 1.5;
static char displayKey, foregroundKey, chargingHookKey, largeChargingHookKey, chargingViewKey, chargingMaskKey;
static NSMapTable<id, UIView *> *providerBatteries;

static BOOL hasMethod(Class cls, SEL selector, unsigned int arguments, const char *types) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != arguments) return NO;
    char result[8] = {0};
    method_getReturnType(method, result, sizeof(result));
    return result[0] && strchr(types, result[0]) != NULL;
}

static id objectValue(id object, SEL selector) {
    return hasMethod(object_getClass(object), selector, 2, "@")
        ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static BOOL flagValue(id object, SEL selector) {
    return hasMethod(object_getClass(object), selector, 2, "Bc")
        && ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL isStatusBarBattery(UIView *view) {
    if ((modernBatteryClass && [view isKindOfClass:modernBatteryClass]) ||
        (legacyBatteryClass && [view isKindOfClass:legacyBatteryClass]) ||
        (modernStaticBatteryClass && [view isKindOfClass:modernStaticBatteryClass]) ||
        (legacyStaticBatteryClass && [view isKindOfClass:legacyStaticBatteryClass])) return YES;
    for (UIView *parent = view.superview; parent; parent = parent.superview) {
        if (legacyBarClass && [parent isKindOfClass:legacyBarClass]) return YES;
    }
    return NO;
}

static BOOL usesPercentage(id provider) {
    return NSThread.isMainThread && flagValue([providerBatteries objectForKey:provider], @selector(showsPercentage));
}

static void disableLargeChargingPresentation(Class cls) {
    Class meta = object_getClass(cls);
    SEL selector = @selector(showsLargeBatteryChargingAnimation);
    if (!hasMethod(meta, selector, 2, "Bc") || objc_getAssociatedObject(meta, &largeChargingHookKey)) return;
    objc_setAssociatedObject(meta, &largeChargingHookKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __block IMP original = NULL;
    IMP hook = imp_implementationWithBlock(^BOOL(Class providerClass) {
        if (NSThread.isMainThread) {
            for (id provider in providerBatteries) {
                if ([provider isKindOfClass:providerClass] && usesPercentage(provider)) return NO;
            }
        }
        return ((BOOL (*)(id, SEL))original)(providerClass, selector);
    });
    MSHookMessageEx(meta, selector, hook, &original);
}

static BOOL hasObjectArgument(Class cls, SEL selector, const char *result) {
    if (!hasMethod(cls, selector, 3, result)) return NO;
    char argument[8] = {0};
    method_getArgumentType(class_getInstanceMethod(cls, selector), 2, argument, sizeof(argument));
    return argument[0] == '@';
}

static void preventChargingExpansion(UIView *battery) {
    UIView *bar = battery.superview;
    while (bar && !((legacyBarClass && [bar isKindOfClass:legacyBarClass]) ||
                    (modernBarClass && [bar isKindOfClass:modernBarClass]))) {
        bar = bar.superview;
    }
    id provider = objectValue(bar, @selector(visualProvider));
    if (!provider) return;
    if (!providerBatteries) providerBatteries = [NSMapTable weakToWeakObjectsMapTable];
    [providerBatteries setObject:battery forKey:provider];

    Class cls = object_getClass(provider);
    if (objc_getAssociatedObject(cls, &chargingHookKey)) return;
    objc_setAssociatedObject(cls, &chargingHookKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    for (Class candidate = cls; candidate; candidate = class_getSuperclass(candidate)) {
        SEL large = @selector(showsLargeBatteryChargingAnimation);
        Class parent = class_getSuperclass(candidate);
        if (class_getClassMethod(candidate, large) != class_getClassMethod(parent, large)) {
            disableLargeChargingPresentation(candidate);
        }
    }

    // Decline the charging system update before iOS rearranges the status bar.
    Class item = modernBarClass && [bar isKindOfClass:modernBarClass]
        ? objc_lookUpClass("STUIStatusBarBatteryItem") : objc_lookUpClass("_UIStatusBarBatteryItem");
    id chargingIdentifier = objectValue(item, @selector(chargingDisplayIdentifier));
    SEL shown = @selector(_shouldShowSystemUpdateForDisplayItemWithIdentifier:);
    if (chargingIdentifier && hasObjectArgument(cls, shown, "Bc")) {
        __block IMP originalShown = NULL;
        IMP hook = imp_implementationWithBlock(^BOOL(id host, id identifier) {
            if ([chargingIdentifier isEqual:identifier] && usesPercentage(host)) return NO;
            return ((BOOL (*)(id, SEL, id))originalShown)(host, shown, identifier);
        });
        MSHookMessageEx(cls, shown, hook, &originalShown);
    }

    SEL selector = @selector(_updateDataForBatteryCharging:);
    if (hasObjectArgument(cls, selector, "v")) {
        __block IMP original = NULL;
        IMP hook = imp_implementationWithBlock(^(id host, id data) {
            if (!usesPercentage(host)) ((void (*)(id, SEL, id))original)(host, selector, data);
        });
        MSHookMessageEx(cls, selector, hook, &original);
    }
}

static void setChargingViewSuppressed(UIView *chargingView, BOOL suppressed) {
    if (!chargingView) return;
    CALayer *mask = objc_getAssociatedObject(chargingView, &chargingMaskKey);
    if (!suppressed) {
        if (mask && chargingView.layer.mask == mask) chargingView.layer.mask = nil;
        return;
    }
    if (chargingView.layer.mask) return;
    if (!mask) {
        mask = [CALayer layer];
        objc_setAssociatedObject(chargingView, &chargingMaskKey, mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    chargingView.layer.mask = mask;
}

static void suppressTemporaryChargingView(id item, id candidate) {
    if (!NSThread.isMainThread || ![candidate isKindOfClass:UIView.class]) return;
    UIView *battery = objectValue(item, @selector(batteryView));
    if (!isStatusBarBattery(battery)) battery = objectValue(item, @selector(staticBatteryView));
    if (!isStatusBarBattery(battery)) return;
    UIView *previous = objc_getAssociatedObject(battery, &chargingViewKey);
    if (previous != candidate) {
        setChargingViewSuppressed(previous, NO);
        objc_setAssociatedObject(battery, &chargingViewKey, candidate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    setChargingViewSuppressed(candidate, flagValue(battery, @selector(showsPercentage)));
}

static void hookTemporaryChargingItem(Class cls) {
    SEL selector = @selector(chargingView);
    if (hasMethod(cls, selector, 2, "@")) {
        __block IMP original = NULL;
        IMP hook = imp_implementationWithBlock(^id(id item) {
            id view = ((id (*)(id, SEL))original)(item, selector);
            suppressTemporaryChargingView(item, view);
            return view;
        });
        MSHookMessageEx(cls, selector, hook, &original);
    }

    SEL viewSelector = @selector(viewForIdentifier:);
    id chargingIdentifier = objectValue(cls, @selector(chargingDisplayIdentifier));
    if (!chargingIdentifier || !hasObjectArgument(cls, viewSelector, "@")) return;
    __block IMP originalView = NULL;
    IMP hook = imp_implementationWithBlock(^id(id item, id identifier) {
        id view = ((id (*)(id, SEL, id))originalView)(item, viewSelector, identifier);
        if ([chargingIdentifier isEqual:identifier]) suppressTemporaryChargingView(item, view);
        return view;
    });
    MSHookMessageEx(cls, viewSelector, hook, &originalView);
}

static UIFont *regularWidthFont(UIFont *font) {
    UIFontDescriptor *descriptor = font.fontDescriptor;
    UIFontDescriptorSymbolicTraits traits = descriptor.symbolicTraits;
    UIFontDescriptorSymbolicTraits regular = traits & ~(UIFontDescriptorTraitCondensed | UIFontDescriptorTraitExpanded);
    if (traits == regular) return font;
    UIFontDescriptor *normal = [descriptor fontDescriptorWithSymbolicTraits:regular];
    return normal ? [UIFont fontWithDescriptor:normal size:font.pointSize] : font;
}

static UIFont *appBatteryFont(UIView *view) {
    // Static app battery renderers can draw their text into an image with no label.
    Class cls = object_getClass(view);
    SEL iconSize = @selector(iconSize);
    SEL fontSize = @selector(_percentageFontSizeForIconSize:);
    CGFloat size = 9;
    if (hasMethod(cls, iconSize, 2, "q") && hasMethod(cls, fontSize, 3, "d")) {
        char argument[8] = {0};
        method_getArgumentType(class_getInstanceMethod(cls, fontSize), 2, argument, sizeof(argument));
        if (argument[0] == 'q') {
            long long icon = ((long long (*)(id, SEL))objc_msgSend)(view, iconSize);
            CGFloat nativeSize = ((CGFloat (*)(id, SEL, long long))objc_msgSend)(view, fontSize, icon);
            if (nativeSize > 0 && isfinite(nativeSize)) size = nativeSize;
        }
    }
    return [UIFont boldSystemFontOfSize:size];
}

static CGFloat reservedWidth(UIFont *font) {
    return ceil([@"100" sizeWithAttributes:@{NSFontAttributeName: font}].width) + numberTrailingSpace;
}

static CGRect digitInkBounds(UILabel *number, CGFloat scale) {
    CGContextRef bitmap = artworkBitmap(number.bounds.size, scale, ^{
        [number drawTextInRect:number.bounds];
    });
    if (bitmap) {
        CGRect pixels = paintedPixelBounds(bitmap);
        CGContextRelease(bitmap);
        if (!CGRectIsEmpty(pixels)) {
            return CGRectApplyAffineTransform(pixels, CGAffineTransformMakeScale(1 / scale, 1 / scale));
        }
    }
    UIFont *font = number.font;
    CGFloat baseline = (CGRectGetHeight(number.bounds) - font.lineHeight) / 2 + font.ascender;
    return CGRectMake(0, baseline - font.capHeight, 0, font.capHeight);
}

static CGRect boltFrame(UIImage *image, CGRect digitInk, CGFloat numberEdge) {
    CGRect imageBounds = (CGRect){CGPointZero, image.size};
    CGRect symbolInk = UIEdgeInsetsInsetRect(imageBounds, image.alignmentRectInsets);
    if (CGRectIsEmpty(symbolInk)) return CGRectZero;
    CGFloat scale = CGRectGetHeight(digitInk) / CGRectGetHeight(symbolInk);
    return CGRectMake(numberEdge + boltGap - CGRectGetMinX(symbolInk) * scale,
                      CGRectGetMinY(digitInk) - CGRectGetMinY(symbolInk) * scale,
                      CGRectGetWidth(imageBounds) * scale,
                      CGRectGetHeight(imageBounds) * scale);
}

static BOOL isControlCenterTransitionBattery(UIView *view) {
    if (!isSpringBoard || !modernStaticBatteryClass ||
        ![view isKindOfClass:modernStaticBatteryClass]) return NO;
    Class windowClass = objc_lookUpClass("SBControlCenterWindow");
    return windowClass && [view.window isKindOfClass:windowClass];
}

static CGFloat batteryRightLimit(UIView *view, CGRect frame, ClearChargeDisplay *display) {
    UIView *parent = view.superview;
    UIWindow *window = view.window;
    CGRect safeBounds = UIEdgeInsetsInsetRect(window.bounds, window.safeAreaInsets);
    CGRect safeArea = [window convertRect:safeBounds toView:parent];
    CGFloat limit = CGRectGetMaxX(safeArea);
    if (CGRectIsEmpty(safeArea) && display.layer.superlayer &&
        display.layer.superlayer == view.layer.superlayer && isControlCenterTransitionBattery(view)) {
        // The first pull-down can collapse the window conversion while the battery is still visible.
        // Reuse its fitted width at the new origin. Any clipping ancestors still constrain it below.
        limit = CGRectGetMinX(frame) + MAX(CGRectGetWidth(frame), CGRectGetWidth(display.layer.frame));
    }
    for (UIView *ancestor = parent; ancestor && ancestor != window; ancestor = ancestor.superview) {
        if (ancestor.clipsToBounds) {
            CGRect clippingFrame = [ancestor convertRect:ancestor.bounds toView:parent];
            limit = MIN(limit, CGRectGetMaxX(clippingFrame));
        }
    }
    return limit;
}

static void showNativeBattery(UIView *view, ClearChargeDisplay *display) {
    if (display && view.layer.mask == display.stockMask) view.layer.mask = display.nativeMask;
    display.nativeMask = nil;
    [display.layer removeFromSuperlayer];
}

static UIColor *foregroundColor(UIView *view) {
    UIColor *ink = objc_getAssociatedObject(view, &foregroundKey);
    if (!ink) {
        // The fill and percentage can have charging or cutout colors.
        // The body color carries the status bar ink, usually with reduced alpha.
        id body = objectValue(view, NSSelectorFromString(@"bodyColor"));
        ink = [body isKindOfClass:UIColor.class] ? body : UIColor.labelColor;
    }
    return [[ink resolvedColorWithTraitCollection:view.traitCollection] colorWithAlphaComponent:1];
}

static UIColor *lowPowerColor(UIColor *ink) {
    CGFloat red, green, blue, luminance;
    if ([ink getRed:&red green:&green blue:&blue alpha:NULL]) {
        luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue;
    } else if (![ink getWhite:&luminance alpha:NULL]) {
        return ink;
    }
    return luminance < 0.5
        ? [UIColor colorWithRed:178.0 / 255.0 green:98.0 / 255.0 blue:0.0 alpha:1]
        : [UIColor colorWithRed:1 green:0.84 blue:0.04 alpha:1];
}

static void updateDisplay(UIView *view) {
    if (!NSThread.isMainThread) return;
    ClearChargeDisplay *display = objc_getAssociatedObject(view, &displayKey);
    BOOL showsPercentage = flagValue(view, @selector(showsPercentage));
    UIView *temporaryBolt = objc_getAssociatedObject(view, &chargingViewKey);
    setChargingViewSuppressed(temporaryBolt, showsPercentage);
    UIView *parent = view.superview;
    if (parent && view.window && isStatusBarBattery(view)) preventChargingExpansion(view);
    CGRect bounds = view.bounds;
    if (!parent || !view.window || CGRectIsEmpty(bounds) || view.hidden || view.alpha <= 0.01 ||
        !isStatusBarBattery(view) ||
        !showsPercentage) {
        showNativeBattery(view, display);
        return;
    }

    UILabel *native = objectValue(view, NSSelectorFromString(@"percentageLabel"));
    SEL charging = NSSelectorFromString(@"chargingState");
    if (!hasMethod(object_getClass(view), charging, 2, "q")) {
        showNativeBattery(view, display);
        return;
    }
    if (![native isKindOfClass:UILabel.class]) native = nil;
    NSAttributedString *attributed = native.attributedText;
    NSString *text = attributed.length ? attributed.string : native.text;
    NSCharacterSet *nonDigits = NSCharacterSet.decimalDigitCharacterSet.invertedSet;
    NSString *digits = [[text componentsSeparatedByCharactersInSet:nonDigits] componentsJoinedByString:@""];
    NSRange firstDigit = [text rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet];
    UIFont *font = native.font;
    if (attributed.length && firstDigit.location != NSNotFound) {
        id value = [attributed attribute:NSFontAttributeName atIndex:firstDigit.location effectiveRange:NULL];
        if ([value isKindOfClass:UIFont.class]) font = value;
    }
    SEL chargePercent = @selector(chargePercent);
    if (!digits.length && !isSpringBoard && hasMethod(object_getClass(view), chargePercent, 2, "d")) {
        CGFloat level = ((CGFloat (*)(id, SEL))objc_msgSend)(view, chargePercent);
        if (level >= 0 && level <= 1) {
            digits = [NSString localizedStringWithFormat:@"%ld", (long)lround(level * 100)];
        }
    }
    if (!font && !isSpringBoard) font = appBatteryFont(view);
    if (!digits.length || !font) {
        showNativeBattery(view, display);
        return;
    }

    font = regularWidthFont(font);
    CGRect frame = [view convertRect:bounds toView:parent];
    CGFloat height = CGRectGetHeight(frame);
    NSDictionary *attributes = @{NSFontAttributeName: font};
    CGFloat digitsWidth = ceil([digits sizeWithAttributes:attributes].width);
    // Reserve the space for three digits and the full-size bolt even when unplugged.
    CGFloat fullWidth = reservedWidth(font);
    CGFloat extension = MAX(0, fullWidth - CGRectGetWidth(frame));
    CGFloat rightLimit = batteryRightLimit(view, frame, display);
    CGFloat rightRoom = MAX(0, rightLimit - CGRectGetMaxX(frame));
    CGFloat usedRoom = MIN(extension, rightRoom);
    frame.size.width += usedRoom;
    CGFloat width = CGRectGetWidth(frame);
    CGFloat numberEdge = width - numberTrailingSpace;
    BOOL compact = digitsWidth > numberEdge;
    if (compact && !isControlCenterTransitionBattery(view)) {
        // The number must fit inside the stock slot at its native font size.
        showNativeBattery(view, display);
        return;
    }
    if (compact) numberEdge = digitsWidth;

    if (!display) {
        display = [ClearChargeDisplay new];
        objc_setAssociatedObject(view, &displayKey, display, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    long long charge = ((long long (*)(id, SEL))objc_msgSend)(view, charging);
    SEL inactive = NSSelectorFromString(@"_boltIsInactive");
    // Older renderers expose the charging state but lack the inactive-bolt selector.
    BOOL paused = hasMethod(object_getClass(view), inactive, 2, "Bc") ? flagValue(view, inactive) : charge >= 3;
    UIColor *ink = foregroundColor(view);
    BOOL saving = flagValue(view, NSSelectorFromString(@"saverModeActive"));

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    UILabel *number = display.number;
    CGRect numberFrame = CGRectMake(0, 0, numberEdge, height);
    CGFloat measurementScale = MAX(1, view.traitCollection.displayScale);
    BOOL fontChanged = ![number.font isEqual:font];
    BOOL digitsChanged = ![number.text isEqualToString:digits];
    BOOL geometryChanged = !CGRectEqualToRect(number.frame, numberFrame);
    if (fontChanged) number.font = font;
    if (digitsChanged) number.text = digits;
    UIColor *numberInk = saving ? lowPowerColor(ink) : ink;
    if (![number.textColor isEqual:numberInk]) number.textColor = numberInk;
    if (geometryChanged) number.frame = numberFrame;
    if (fontChanged || digitsChanged || geometryChanged || display.digitMeasurementScale != measurementScale) {
        // Sample at the display scale without changing how UIKit renders the onscreen label.
        display.digitInkBounds = digitInkBounds(number, measurementScale);
        display.digitMeasurementScale = measurementScale;
    }

    CGRect bolt = boltFrame(display.bolt.image, display.digitInkBounds, numberEdge);
    BOOL showBolt = charge > 0;
    frame.origin.x -= 3 / measurementScale;
    if (compact) {
        // The Control Center status bar can narrow its clip during the pull-down.
        // Fit the visible marks instead of reserving the usual trailing space.
        CGFloat availableWidth = rightLimit - CGRectGetMinX(frame);
        CGRect inkBounds = display.digitInkBounds;
        CGFloat inkRight = CGRectIsEmpty(inkBounds) ? numberEdge : CGRectGetMaxX(inkBounds);
        if (inkRight > availableWidth) {
            showNativeBattery(view, display);
            [CATransaction commit];
            return;
        }
        CGFloat minimumBoltX = inkRight + 1 / measurementScale;
        CGFloat maximumBoltX = availableWidth - CGRectGetWidth(bolt);
        if (maximumBoltX < minimumBoltX) {
            showBolt = NO;
        } else {
            bolt.origin.x = MAX(minimumBoltX, MIN(CGRectGetMinX(bolt), maximumBoltX));
        }
        frame.size.width = MAX(width, showBolt ? CGRectGetMaxX(bolt) : numberEdge);
    } else if (CGRectGetMaxX(bolt) > width + (rightRoom - usedRoom)) {
        showNativeBattery(view, display);
        [CATransaction commit];
        return;
    } else {
        frame.size.width = MAX(width, CGRectGetMaxX(bolt));
    }
    if (!CGRectEqualToRect(display.layer.frame, frame)) display.layer.frame = frame;
    display.layer.opacity = view.layer.opacity;
    if (![display.bolt.tintColor isEqual:ink]) display.bolt.tintColor = ink;
    display.bolt.frame = bolt;
    display.bolt.hidden = !showBolt;
    display.bolt.alpha = paused ? 0.55 : 1;
    // Stay out of the native status bar's arranged view list.
    if (display.layer.superlayer != view.layer.superlayer) {
        [view.layer.superlayer insertSublayer:display.layer above:view.layer];
    }
    if (view.layer.mask != display.stockMask) {
        display.nativeMask = view.layer.mask;
        view.layer.mask = display.stockMask;
    }
    [CATransaction commit];
}

static BOOL shouldHook(Class cls, Class parent, SEL selector) {
    return !parent || class_getInstanceMethod(cls, selector) != class_getInstanceMethod(parent, selector);
}

static void hookUpdate(Class cls, Class parent, SEL selector) {
    if (!hasMethod(cls, selector, 2, "v") || !shouldHook(cls, parent, selector)) return;
    __block IMP original = NULL;
    IMP replacement = imp_implementationWithBlock(^(UIView *view) {
        ((void (*)(id, SEL))original)(view, selector);
        updateDisplay(view);
    });
    MSHookMessageEx(cls, selector, replacement, &original);
}

static void hookVisibility(Class cls, Class parent) {
    SEL hidden = @selector(setHidden:);
    __block IMP originalHidden = NULL;
    IMP hiddenHook = imp_implementationWithBlock(^(UIView *view, BOOL value) {
        ((void (*)(id, SEL, BOOL))originalHidden)(view, hidden, value);
        updateDisplay(view);
    });
    if (shouldHook(cls, parent, hidden)) MSHookMessageEx(cls, hidden, hiddenHook, &originalHidden);

    SEL alpha = @selector(setAlpha:);
    __block IMP originalAlpha = NULL;
    IMP alphaHook = imp_implementationWithBlock(^(UIView *view, CGFloat value) {
        ((void (*)(id, SEL, CGFloat))originalAlpha)(view, alpha, value);
        updateDisplay(view);
    });
    if (shouldHook(cls, parent, alpha)) MSHookMessageEx(cls, alpha, alphaHook, &originalAlpha);
}

static void hookStyle(Class cls) {
    SEL selector = NSSelectorFromString(@"applyStyleAttributes:");
    if (!hasMethod(cls, selector, 3, "v")) return;
    Method method = class_getInstanceMethod(cls, selector);
    char argument[8] = {0};
    method_getArgumentType(method, 2, argument, sizeof(argument));
    if (argument[0] != '@') return;

    __block IMP original = NULL;
    IMP replacement = imp_implementationWithBlock(^(UIView *view, id attributes) {
        ((void (*)(id, SEL, id))original)(view, selector, attributes);
        if (!NSThread.isMainThread) return;
        UIColor *ink = nil;
        for (NSString *name in @[@"imageTintColor", @"foregroundColor", @"textColor"]) {
            id value = objectValue(attributes, NSSelectorFromString(name));
            if ([value isKindOfClass:UIColor.class]) {
                ink = value;
                break;
            }
        }
        objc_setAssociatedObject(view, &foregroundKey, ink, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        updateDisplay(view);
    });
    MSHookMessageEx(cls, selector, replacement, &original);
}

static CGSize appStatusBatterySize(UIView *view, CGSize size) {
    if (isSpringBoard || !NSThread.isMainThread || !isStatusBarBattery(view) ||
        !flagValue(view, @selector(showsPercentage))) return size;
    UILabel *label = objectValue(view, @selector(percentageLabel));
    UIFont *font = [label isKindOfClass:UILabel.class] ? label.font : nil;
    size.width = MAX(size.width, reservedWidth(regularWidthFont(font ?: appBatteryFont(view))));
    return size;
}

static void hookAppSizing(Class cls, Class parent) {
    if (isSpringBoard) return;
    SEL intrinsic = @selector(intrinsicContentSize);
    if (shouldHook(cls, parent, intrinsic)) {
        __block IMP original = NULL;
        IMP hook = imp_implementationWithBlock(^CGSize(UIView *view) {
            return appStatusBatterySize(view, ((CGSize (*)(id, SEL))original)(view, intrinsic));
        });
        MSHookMessageEx(cls, intrinsic, hook, &original);
    }

    SEL fitting = @selector(sizeThatFits:);
    if (shouldHook(cls, parent, fitting)) {
        __block IMP original = NULL;
        IMP hook = imp_implementationWithBlock(^CGSize(UIView *view, CGSize target) {
            return appStatusBatterySize(view, ((CGSize (*)(id, SEL, CGSize))original)(view, fitting, target));
        });
        MSHookMessageEx(cls, fitting, hook, &original);
    }
}

static void hookRenderer(Class cls, Class parent) {
    if (!cls) return;
    hookUpdate(cls, parent, @selector(layoutSubviews));
    hookUpdate(cls, parent, @selector(didMoveToSuperview));
    hookUpdate(cls, parent, @selector(didMoveToWindow));
    hookUpdate(cls, parent, @selector(_updatePercentage));
    hookUpdate(cls, parent, @selector(_updateFillColor));
    hookUpdate(cls, parent, @selector(_updatePercentageFont));
    hookVisibility(cls, parent);
    hookAppSizing(cls, parent);

    SEL selector = @selector(setFrame:);
    if (!shouldHook(cls, parent, selector)) return;
    __block IMP original = NULL;
    IMP replacement = imp_implementationWithBlock(^(UIView *view, CGRect frame) {
        ((void (*)(id, SEL, CGRect))original)(view, selector, frame);
        if (objc_getAssociatedObject(view, &displayKey)) updateDisplay(view);
    });
    MSHookMessageEx(cls, selector, replacement, &original);
}

__attribute__((constructor)) static void installClearCharge(void) {
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 16) return;
    isSpringBoard = [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"];
    legacyBarClass = objc_lookUpClass("_UIStatusBar");
    legacyStaticBatteryClass = objc_lookUpClass("_UIStatusBarStaticBatteryView");
    legacyBatteryClass = objc_lookUpClass("_UIStatusBarBatteryView");
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26) {
        modernBatteryClass = objc_lookUpClass("STUIStatusBarBatteryView");
        if (!modernBatteryClass) {
            dlopen("/System/Library/PrivateFrameworks/SystemStatusUI.framework/SystemStatusUI", RTLD_LAZY | RTLD_LOCAL);
            modernBatteryClass = objc_lookUpClass("STUIStatusBarBatteryView");
        }
        modernBarClass = objc_lookUpClass("STUIStatusBar");
        modernStaticBatteryClass = objc_lookUpClass("STUIStatusBarStaticBatteryView");
    }

    Class renderers[] = {objc_lookUpClass("_UIBatteryView"), legacyBatteryClass, modernBatteryClass,
                         legacyStaticBatteryClass, modernStaticBatteryClass};
    for (NSUInteger index = 0; index < sizeof(renderers) / sizeof(renderers[0]); index++) {
        Class renderer = renderers[index];
        if (!renderer) continue;
        Class parent = Nil;
        for (NSUInteger earlier = index; earlier > 0 && !parent; earlier--) {
            Class installed = renderers[earlier - 1];
            if (installed && [renderer isSubclassOfClass:installed]) parent = installed;
        }
        if (renderer != parent) hookRenderer(renderer, parent);
    }
    if (legacyBatteryClass) hookStyle(legacyBatteryClass);
    if (modernBatteryClass) hookStyle(modernBatteryClass);
    hookTemporaryChargingItem(objc_lookUpClass("_UIStatusBarBatteryItem"));
    hookTemporaryChargingItem(objc_lookUpClass("STUIStatusBarBatteryItem"));
}
