#import <Cocoa/Cocoa.h>
#import <IOKit/IOKitLib.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>
#import <pthread.h>
#import <math.h>

typedef struct { float x, y; } ContactPoint;
typedef struct { ContactPoint position, velocity; } Vector;
typedef struct {
    int frame;
    double timestamp;
    int identifier, state, fingerID, handID;
    Vector normalized;
    float size;
    int reserved;
    float angle, majorAxis, minorAxis;
    Vector millimeters;
    int reserved2[2];
    float density;
} Contact;

_Static_assert(sizeof(Contact) == 96, "Unexpected contact layout");

typedef int (*ContactCallback)(void *, Contact *, int, double, int);
static CFArrayRef (*createDevices)(void);
static bool (*isBuiltIn)(void *);
static void (*registerCallback)(void *, ContactCallback);
static void (*startDevice)(void *, int);

typedef struct {
    void *device;
    double time;
    int count;
    ContactPoint points[16];
    int ids[16], states[16], frame;
} Sample;
static Sample samples[16];
static int deviceCount;
#define TRACE_CAPACITY 8192
static Sample trace[TRACE_CAPACITY];
static unsigned long long framesReceived;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

static NSString *startCapture(void);
static void (*stopDevice)(void *);
static void (*unregisterCallback)(void *, ContactCallback);
static CFArrayRef capturedDevices;

static int receiveContacts(void *device, Contact *contacts, int count, double timestamp, int frame) {
    double now = NSProcessInfo.processInfo.systemUptime;
    pthread_mutex_lock(&lock);
    for (int i = 0; i < deviceCount; i++) {
        if (samples[i].device != device) continue;
        Sample *sample = &samples[i];
        sample->time = now;
        sample->count = 0;
        sample->frame = frame;
        for (int j = 0; contacts && j < count && j < 16; j++) {
            ContactPoint point = contacts[j].normalized.position;
            if (!isfinite(point.x) || !isfinite(point.y)) continue;
            int index = sample->count++;
            sample->points[index] = point;
            sample->ids[index] = contacts[j].identifier;
            sample->states[index] = contacts[j].state;
        }
        trace[framesReceived++ % TRACE_CAPACITY] = *sample;
        break;
    }
    pthread_mutex_unlock(&lock);
    return 0;
}

static NSString *startCapture(void) {
    static void *framework;
    if (!framework) framework = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
    if (!framework) return @"Unable to load Apple's multitouch framework.";
    createDevices = dlsym(framework, "MTDeviceCreateList");
    isBuiltIn = dlsym(framework, "MTDeviceIsBuiltIn");
    registerCallback = dlsym(framework, "MTRegisterContactFrameCallback");
    startDevice = dlsym(framework, "MTDeviceStart");
    stopDevice = dlsym(framework, "MTDeviceStop");
    unregisterCallback = dlsym(framework, "MTUnregisterContactFrameCallback");
    if (!createDevices || !isBuiltIn || !registerCallback || !startDevice ||
        !stopDevice || !unregisterCallback)
        return @"This macOS version does not expose the required multitouch functions.";

    CFArrayRef devices = createDevices();
    void *candidate = NULL;
    int count = 0;
    if (devices) {
        for (CFIndex i = 0; i < CFArrayGetCount(devices); i++) {
            void *device = (void *)CFArrayGetValueAtIndex(devices, i);
            if (!isBuiltIn(device)) {
                candidate = device;
                count++;
            }
        }
    }
    if (count != 1) candidate = NULL;
    void *previous = samples[0].device;
    if (previous != candidate) {
        pthread_mutex_lock(&lock);
        samples[0] = (Sample){0};
        deviceCount = 0;
        pthread_mutex_unlock(&lock);
        if (previous) {
            unregisterCallback(previous, receiveContacts);
            stopDevice(previous);
        }
        if (capturedDevices) CFRelease(capturedDevices);
        capturedDevices = NULL;
        if (candidate) {
            capturedDevices = CFRetain(devices);
            pthread_mutex_lock(&lock);
            samples[0].device = candidate;
            deviceCount = 1;
            pthread_mutex_unlock(&lock);
            registerCallback(candidate, receiveContacts);
            startDevice(candidate, 0);
        }
    }
    if (devices) CFRelease(devices);
    if (count == 1) return @"External multitouch device connected";
    if (count > 1) return @"Disconnect other external multitouch devices";
    return @"Waiting for Magic Mouse to connect";
}

typedef struct {
    int anchorID, anchorSide, touchID, side, pendingSide;
    double anchorSince, began, deadline, lastFrame;
    ContactPoint origin, anchorOrigin;
    BOOL tracking, blocked, sawDown, moved;
    int swipeDirection;
    pid_t target, pendingTarget;
} Gesture;

static int sideOf(ContactPoint p) {
    return p.x <= 0.35 ? -1 : p.x >= 0.65 ? 1 : 0;
}

static BOOL browser(NSRunningApplication *app) {
    return [@[@"com.apple.Safari", @"com.apple.SafariTechnologyPreview", @"com.google.Chrome",
        @"org.mozilla.firefox", @"com.microsoft.edgemac", @"com.brave.Browser", @"company.thebrowser.Browser",
        @"com.vivaldi.Vivaldi", @"com.operasoftware.Opera"] containsObject:app.bundleIdentifier ?: @""];
}

typedef NS_ENUM(NSInteger, Action) {
    ActionDisabled, ActionPreviousTab, ActionNextTab, ActionCopy, ActionPaste,
    ActionBackspace, ActionEnter, ActionBack, ActionForward, ActionUndo, ActionRedo, ActionSelectAll, ActionEscape, ActionSpace, ActionUp, ActionDown, ActionLeft, ActionRight, ActionLaunchpad, ActionNotificationCenter, ActionCloseTab, ActionRefresh, ActionMacro, ActionCloseWindow, ActionAppExpose
};

static NSArray<NSString *> *actionNames(void) {
    return @[@"Disabled", @"Previous Tab", @"Next Tab", @"Copy", @"Paste",
             @"Backspace", @"Enter", @"Back", @"Forward", @"Undo", @"Redo", @"Select All", @"Escape", @"Space", @"Up Arrow", @"Down Arrow", @"Left Arrow", @"Right Arrow", @"Launchpad", @"Notification Center", @"Close Tab", @"Refresh", @"Custom Macro…", @"Close Window", @"App Exposé"];
}

static NSArray<NSString *> *gestureNames(void) {
    return @[@"Left Tap", @"Right Tap", @"Left Hold", @"Right Hold", @"Swipe Left", @"Swipe Right", @"Three-Finger Tap", @"Four-Finger Tap", @"Three-Finger Hold", @"Four-Finger Hold", @"Two-Finger Tap", @"Three-Finger Double Tap", @"Two-Finger Swipe Down"];
}

static NSString *mappingKey(NSInteger gesture) {
    return [@"gesture." stringByAppendingString:gestureNames()[gesture]];
}

static Action selectedAction(NSInteger gesture) {
    static const Action defaults[] = {ActionPreviousTab, ActionNextTab, ActionPaste, ActionCopy,
        ActionBackspace, ActionEnter, ActionNotificationCenter, ActionDisabled,
        ActionLaunchpad, ActionDisabled, ActionAppExpose, ActionCloseWindow, ActionRefresh};
    NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:mappingKey(gesture)];
    NSInteger value = saved ? saved.integerValue : defaults[gesture];
    return value >= 0 && value < (NSInteger)actionNames().count ? value : ActionDisabled;
}

static void postKey(pid_t target, CGKeyCode key, CGEventFlags flags) {
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, key, true);
    CGEventRef up = CGEventCreateKeyboardEvent(NULL, key, false);
    if (down && up) {
        CGEventSetFlags(down, flags);
        CGEventSetFlags(up, flags);
        if (target > 0) {
            CGEventPostToPid(target, down);
            CGEventPostToPid(target, up);
        } else {
            CGEventPost(kCGHIDEventTap, down);
            CGEventPost(kCGHIDEventTap, up);
        }
    }
    if (down) CFRelease(down);
    if (up) CFRelease(up);
}

static NSString *macroKey(NSInteger gesture) {
    return [@"macro." stringByAppendingString:gestureNames()[gesture]];
}

static void playMacro(NSArray<NSArray<NSNumber *> *> *steps, NSUInteger index, pid_t target) {
    if (index >= steps.count || !AXIsProcessTrusted() ||
        NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != target) return;
    NSArray<NSNumber *> *step = steps[index];
    postKey(target, step[0].unsignedShortValue, step[1].unsignedLongLongValue);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        playMacro(steps, index + 1, target);
    });
}

static void performAction(NSInteger gesture, pid_t target) {
    Action action = selectedAction(gesture);
    NSRunningApplication *app = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (!action || target <= 0 || app.processIdentifier != target || !AXIsProcessTrusted()) return;
    if (target == NSProcessInfo.processInfo.processIdentifier) return;
    if (action >= ActionPreviousTab && action <= ActionNextTab && !browser(app)) return;
    if ((action == ActionBack || action == ActionForward) && !browser(app)) return;
    if (action == ActionLaunchpad) {
        NSURL *url = [NSURL fileURLWithPath:@"/System/Applications/Launchpad.app"];
        if (![NSWorkspace.sharedWorkspace openURL:url])
            NSBeep();
        return;
    }
    if (action == ActionAppExpose) {
        void (*sendDockNotification)(CFStringRef, CFTypeRef) =
            dlsym(RTLD_DEFAULT, "CoreDockSendNotification");
        if (sendDockNotification)
            sendDockNotification(CFSTR("com.apple.expose.front.awake"), NULL);
        else
            NSBeep();
        return;
    }
    if (action == ActionNotificationCenter) {
        postKey(0, 45, kCGEventFlagMaskSecondaryFn);
        return;
    }
    if (action == ActionMacro) {
        playMacro([NSUserDefaults.standardUserDefaults arrayForKey:macroKey(gesture)], 0, target);
        return;
    }
    CGKeyCode key;
    CGEventFlags flags = kCGEventFlagMaskCommand;
    switch (action) {
        case ActionPreviousTab: key = 48; flags = kCGEventFlagMaskControl | kCGEventFlagMaskShift; break;
        case ActionNextTab: key = 48; flags = kCGEventFlagMaskControl; break;
        case ActionCopy: key = 8; break;
        case ActionPaste: key = 9; break;
        case ActionBackspace: key = 51; flags = 0; break;
        case ActionEnter: key = 36; flags = 0; break;
        case ActionBack: key = 33; break;
        case ActionForward: key = 30; break;
        case ActionUndo: key = 6; break;
        case ActionRedo: key = 6; flags |= kCGEventFlagMaskShift; break;
        case ActionSelectAll: key = 0; break;
        case ActionEscape: key = 53; flags = 0; break;
        case ActionSpace: key = 49; flags = 0; break;
        case ActionUp: key = 126; flags = 0; break;
        case ActionDown: key = 125; flags = 0; break;
        case ActionLeft: key = 123; flags = 0; break;
        case ActionRight: key = 124; flags = 0; break;
        case ActionCloseWindow: key = 13; break;
        case ActionCloseTab: if (!browser(app)) return; key = 13; break;
        case ActionRefresh: if (!browser(app)) return; key = 15; break;
        default: return;
    }
    postKey(target, key, flags);
}

static void flushTap(Gesture *g, double time) {
    if (g->pendingSide && time >= g->deadline) {
        performAction(g->pendingSide < 0 ? 0 : 1, g->pendingTarget);
        g->pendingSide = 0;
    }
}

static void processSample(Gesture *g, Sample *s) {
    double now = s->time;
    int active[16], count = 0;
    for (int i = 0; i < s->count; i++)
        if (s->states[i] == 3 || s->states[i] == 4) active[count++] = i;
    if (g->lastFrame && now - g->lastFrame > 0.35) {
        // A stationary resting finger can remain down while the mouse stops sending frames.
        // Resume only when that same anchor is still present and no gesture was in progress.
        BOOL restingAnchor = NO;
        if (!g->tracking && !g->blocked && g->anchorSide && count <= 2) {
            for (int i = 0; i < count; i++) {
                int index = active[i];
                restingAnchor |= s->ids[index] == g->anchorID &&
                    sideOf(s->points[index]) == g->anchorSide;
            }
        }
        if (!restingAnchor) {
            g->tracking = NO;
            g->anchorSide = 0;
            g->blocked = YES;
        }
    }
    g->lastFrame = now;
    flushTap(g, now);
    if (count <= 1) {
        if (g->tracking && g->sawDown && count == 1 && s->ids[active[0]] == g->anchorID) {
            double elapsed = now - g->began;
            if (g->swipeDirection && elapsed <= 1.5) {
                performAction(g->swipeDirection < 0 ? 4 : 5, g->target);
            } else if (!g->moved && elapsed >= 0.05 && elapsed <= 0.45) {
                NSInteger gesture = g->side < 0 ? 0 : 1;
                Action action = selectedAction(gesture);
                if (action == ActionPreviousTab || action == ActionNextTab) {
                    performAction(gesture, g->target);
                } else {
                    g->pendingSide = g->side;
                    g->pendingTarget = g->target;
                    g->deadline = now + 0.32;
                }
            }
        }
        g->tracking = NO;
        g->blocked = NO;
        int index = count ? active[0] : 0;
        int side = count ? sideOf(s->points[index]) : 0;
        if (!side || side != g->anchorSide || s->ids[index] != g->anchorID)
            g->anchorSince = now;
        g->anchorSide = side;
        g->anchorID = count ? s->ids[index] : 0;
        return;
    }

    if (g->blocked) return;
    int anchor = -1, added = -1;
    for (int i = 0; i < count; i++) {
        int index = active[i];
        if (s->ids[index] == g->anchorID) anchor = index;
        else added = index;
    }
    if (count != 2 || anchor < 0 || added < 0 || !g->anchorSide ||
        sideOf(s->points[anchor]) != g->anchorSide ||
        (!g->tracking && sideOf(s->points[added]) != -g->anchorSide)) {
        g->tracking = NO;
        g->blocked = YES;
        g->pendingSide = 0;
        return;
    }
    if (!g->tracking) {
        if (g->pendingSide) {
            g->pendingSide = 0;
            g->blocked = YES;
            return;
        }
        if (now - g->anchorSince < 0.04) {
            g->blocked = YES;
            return;
        }
        g->tracking = YES;
        g->began = now;
        g->touchID = s->ids[added];
        g->side = -g->anchorSide;
        g->origin = s->points[added];
        g->anchorOrigin = s->points[anchor];
        g->target = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
        g->sawDown = NO;
        g->moved = NO;
        g->swipeDirection = 0;
    }
    ContactPoint p = s->points[added], a = s->points[anchor];
    if (s->ids[added] != g->touchID ||
        hypot(a.x - g->anchorOrigin.x, a.y - g->anchorOrigin.y) > 0.06) {
        g->tracking = NO;
        g->blocked = YES;
        return;
    }
    g->sawDown |= s->states[added] == 4;
    double dx = p.x - g->origin.x, dy = p.y - g->origin.y;
    g->moved |= hypot(dx, dy) > 0.06;
    g->swipeDirection = fabs(dx) >= 0.18 && fabs(dx) >= 2 * fabs(dy) ? (dx < 0 ? -1 : 1) : 0;
    if (g->sawDown && !g->moved && now - g->began >= 0.75) {
        performAction(g->side < 0 ? 2 : 3, g->target);
        g->tracking = NO;
        g->blocked = YES;
    }
}

typedef struct {
    BOOL blocked;
    int count;
    int ids[4], peak;
    ContactPoint origins[4];
    double began, lastFrame, twoTapDeadline;
    pid_t target, twoTapTarget, threeTapTarget;
    double threeTapDeadline;
    BOOL secondThreeTap;
} MultiFingerTap;

static void flushTwoFingerTap(MultiFingerTap *tap, double now) {
    if (tap->twoTapDeadline && now >= tap->twoTapDeadline) {
        tap->twoTapDeadline = 0;
        performAction(10, tap->twoTapTarget);
    }
}

static void flushThreeFingerTap(MultiFingerTap *tap, double now) {
    if (tap->threeTapDeadline && now >= tap->threeTapDeadline) {
        tap->threeTapDeadline = 0;
        performAction(6, tap->threeTapTarget);
    }
}

static void processMultiFingerTap(MultiFingerTap *tap, Sample *sample) {
    double now = sample->time;
    if (tap->count && (now - tap->lastFrame > 0.2 || now - tap->began > 1.1))
        tap->blocked = YES;
    tap->lastFrame = now;
    int active = 0;
    for (int i = 0; i < sample->count; i++) {
        if (sample->states[i] != 3 && sample->states[i] != 4) continue;
        active++;
        if (tap->blocked) continue;
        if (!tap->count) {
            tap->secondThreeTap = tap->threeTapDeadline > now;
            if (tap->secondThreeTap) tap->threeTapDeadline = 0;
            tap->began = now;
            tap->target = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
        }
        int j = 0;
        while (j < tap->count && tap->ids[j] != sample->ids[i]) j++;
        ContactPoint point = sample->points[i];
        if (j == tap->count) {
            if (j == 4 || now - tap->began > 0.12) {
                tap->blocked = YES;
                continue;
            }
            tap->ids[j] = sample->ids[i];
            tap->origins[j] = point;
            tap->count++;
        } else if (hypot(point.x - tap->origins[j].x, point.y - tap->origins[j].y) > 0.06) {
            tap->blocked = YES;
        }
    }
    if (active && tap->twoTapDeadline) {
        tap->twoTapDeadline = 0;
        tap->blocked = YES;
    }
    tap->peak = MAX(tap->peak, active);
    if (!tap->blocked && active >= 3 && active == tap->count && now - tap->began >= 0.75) {
        performAction(active == 3 ? 8 : 9, tap->target);
        tap->blocked = YES;
    }
    if (active == 0) {
        double deadline = tap->twoTapDeadline;
        pid_t target = tap->twoTapTarget;
        double duration = now - tap->began;
        if (!tap->blocked && tap->peak == tap->count && duration >= 0.04 && duration <= 0.45) {
            if (tap->count == 4) performAction(7, tap->target);
            else if (tap->count == 3) {
                if (selectedAction(11) == ActionDisabled) performAction(6, tap->target);
                else if (tap->secondThreeTap && tap->target == tap->threeTapTarget)
                    performAction(11, tap->target);
                else {
                    tap->threeTapDeadline = now + 0.45;
                    tap->threeTapTarget = tap->target;
                }
            }
            else if (tap->count == 2 && selectedAction(10) != ActionDisabled) {
                deadline = now + 0.45;
                target = tap->target;
            }
        }
        *tap = (MultiFingerTap){.twoTapDeadline = deadline, .twoTapTarget = target,
            .threeTapDeadline = tap->threeTapDeadline, .threeTapTarget = tap->threeTapTarget};
    }
}

typedef struct {
    int count, ids[2];
    ContactPoint origins[2], positions[2];
    double began, last;
    BOOL rejected, paired;
    pid_t target;
} DownSwipe;

static void trackDownSwipe(DownSwipe *swipe, Sample *sample) {
    double now = sample->time;
    int active = 0;
    if (swipe->count && (now - swipe->last > 0.2 || now - swipe->began > 0.5))
        swipe->rejected = YES;
    swipe->last = now;
    for (int i = 0; i < sample->count; i++) {
        int state = sample->states[i];
        if (state < 3 || state > 7) continue;
        BOOL down = state <= 4;
        active += down;
        if (swipe->rejected) continue;
        int j = 0;
        while (j < swipe->count && swipe->ids[j] != sample->ids[i]) j++;
        if (j == swipe->count) {
            if (!down) continue;
            if (!swipe->count) {
                swipe->began = now;
                swipe->target = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
            }
            if (j == 2 || now - swipe->began > 0.065 || swipe->paired) {
                swipe->rejected = YES;
                continue;
            }
            swipe->ids[j] = sample->ids[i];
            swipe->origins[j] = sample->points[i];
            swipe->count++;
        }
        swipe->positions[j] = sample->points[i];
    }
    swipe->paired |= active == 2;
    if (active) return;
    if (swipe->paired && !swipe->rejected) {
        BOOL downward = YES;
        for (int j = 0; j < 2; j++) {
            double dy = swipe->origins[j].y - swipe->positions[j].y;
            double dx = fabs(swipe->positions[j].x - swipe->origins[j].x);
            downward &= dy >= 0.17 && dy > 1.8 * dx;
        }
        if (downward) performAction(12, swipe->target);
    }
    *swipe = (DownSwipe){0};
}

@interface MacroRecorder : NSView
@property NSMutableArray<NSArray<NSNumber *> *> *steps;
@property NSTextField *label;
@end

@implementation MacroRecorder
- (BOOL)acceptsFirstResponder { return YES; }
- (void)mouseDown:(NSEvent *)event { [self.window makeFirstResponder:self]; }
- (void)keyDown:(NSEvent *)event {
    if (event.isARepeat || self.steps.count >= 20) return;
    NSEventModifierFlags flags = event.modifierFlags & (NSEventModifierFlagCommand |
        NSEventModifierFlagOption | NSEventModifierFlagControl | NSEventModifierFlagShift);
    [self.steps addObject:@[@(event.keyCode), @(flags)]];
    self.label.stringValue = [NSString stringWithFormat:@"%lu keystroke(s) recorded", (unsigned long)self.steps.count];
}
@end

@interface Mapper : NSObject <NSApplicationDelegate>
@property NSStatusItem *item;
@property NSMenuItem *toggle;
@property NSMenuItem *captureStatus;
@property BOOL enabled;
@end

@implementation Mapper {
    Gesture _gestures[16];
    MultiFingerTap _multiTap;
    DownSwipe _downSwipe;
    double _swipeIgnoreUntil;
    unsigned long long _cursor;
    double _ignoreUntil;
    id _globalMonitor;
    id _localMonitor;
    NSString *_deviceStatus;
    IONotificationPortRef _deviceNotifications;
    io_iterator_t _matchedDevices, _removedDevices;
    NSUInteger _connectionRevision;
    NSMenuItem *_manualReconnect;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    _deviceStatus = startCapture();
    self.item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.item.button.accessibilityLabel = @"Magicker Mouse";
    [self applyMenuBarIcon];
    [self updateStatusIcon];
    NSMenu *menu = [NSMenu new];
    self.toggle = [menu addItemWithTitle:@"Enable Gestures" action:@selector(toggleGestures:) keyEquivalent:@""];
    self.toggle.target = self;
    self.captureStatus = [menu addItemWithTitle:_deviceStatus action:nil keyEquivalent:@""];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *mappings = [menu addItemWithTitle:@"Gesture Actions" action:nil keyEquivalent:@""];
    mappings.submenu = [NSMenu new];
    NSArray *names = gestureNames();
    const NSInteger menuOrder[] = {0, 1, 2, 3, 4, 5, 10, 12, 6, 11, 8, 7, 9};
    for (NSUInteger index = 0; index < sizeof(menuOrder) / sizeof(menuOrder[0]); index++) {
        NSInteger gesture = menuOrder[index];
        NSMenuItem *row = [mappings.submenu addItemWithTitle:names[gesture] action:nil keyEquivalent:@""];
        row.submenu = [NSMenu new];
        NSArray *actions = actionNames();
        for (NSInteger action = 0; action < (NSInteger)actions.count; action++) {
            NSMenuItem *choice = [row.submenu addItemWithTitle:actions[action]
                action:@selector(changeMapping:) keyEquivalent:@""];
            choice.target = self;
            choice.tag = action;
            choice.representedObject = @(gesture);
            choice.state = selectedAction(gesture) == action ? NSControlStateValueOn : NSControlStateValueOff;
        }
    }
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *autoReconnect = [menu addItemWithTitle:@"Auto Reconnect"
        action:@selector(toggleAutoReconnect:) keyEquivalent:@""];
    autoReconnect.target = self;
    _manualReconnect = [menu addItemWithTitle:@"Reconnect Mouse"
        action:@selector(reconnectMouse:) keyEquivalent:@""];
    _manualReconnect.target = self;
    [self configureAutoReconnect:autoReconnect];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [menu addItemWithTitle:@"Quit Magicker Mouse" action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;
    NSMenuItem *iconItem = [menu insertItemWithTitle:@"Menu Bar Icon" action:nil
        keyEquivalent:@"" atIndex:menu.numberOfItems - 1];
    iconItem.submenu = [NSMenu new];
    NSArray *titles = @[@"Classic Mouse", @"Black Mouse", @"Angled Mouse", @"Wand",
                        @"Wizard Mouse", @"Spark Mouse", @"Wizard Mouse Face",
                        @"Potion Mouse", @"Cosmic Mouse", @"Wizard Hat", @"Cheese Spell",
                        @"Lightning Mouse", @"Crystal Mouse"];
    for (NSString *title in titles) {
        NSMenuItem *choice = [iconItem.submenu addItemWithTitle:title
            action:@selector(selectMenuBarIcon:) keyEquivalent:@""];
        choice.target = self;
        choice.tag = iconItem.submenu.numberOfItems - 1;
        choice.state = choice.tag == [self menuBarIconIndex] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    self.item.menu = menu;
    [NSUserDefaults.standardUserDefaults registerDefaults:@{@"GesturesEnabled": @YES}];
    [self refreshConnection:nil];
    [NSTimer scheduledTimerWithTimeInterval:0.02 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
}

- (NSInteger)menuBarIconIndex {
    NSInteger index = [NSUserDefaults.standardUserDefaults integerForKey:@"MenuBarIcon"];
    return index >= 0 && index < 13 ? index : 0;
}

- (void)applyMenuBarIcon {
    NSArray *resources = @[@"MouseSpark", @"BlackMouse", @"AngledMouse", @"Wand",
                           @"WizardMouse", @"SparkMouse", @"WizardMouseFace",
                           @"PotionMouse", @"CosmicMouse", @"WizardHat", @"CheeseSpell",
                           @"LightningMouse", @"CrystalMouse"];
    NSInteger index = [self menuBarIconIndex];
    NSImage *icon = [[NSBundle.mainBundle imageForResource:resources[index]] copy];
    if (icon && icon.size.height > 0) {
        CGFloat scale = 18.0 / MAX(icon.size.width, icon.size.height);
        icon.size = NSMakeSize(icon.size.width * scale, icon.size.height * scale);
        icon.template = index != 1 && index < 7;
    }
    self.item.button.image = icon;
    self.item.button.title = icon ? @"" : @"Mouse";
}

- (void)selectMenuBarIcon:(NSMenuItem *)sender {
    [NSUserDefaults.standardUserDefaults setInteger:sender.tag forKey:@"MenuBarIcon"];
    for (NSMenuItem *choice in sender.menu.itemArray)
        choice.state = choice == sender ? NSControlStateValueOn : NSControlStateValueOff;
    [self applyMenuBarIcon];
}

- (void)updateStatusIcon {
    self.item.button.alphaValue = self.enabled ? 1 : 0.5;
    self.item.button.toolTip = self.enabled ? @"Magicker Mouse · Enabled" : @"Magicker Mouse · Paused";
}

- (void)changeMapping:(NSMenuItem *)sender {
    NSInteger gesture = [sender.representedObject integerValue];
    if (sender.tag == ActionMacro) {
        NSAlert *editor = [NSAlert new];
        editor.messageText = @"Record a custom macro";
        editor.informativeText = @"Click the recording area, then press up to 20 keys or shortcuts. Click Save to replace the current recording.";
        NSButton *save = [editor addButtonWithTitle:@"Save"];
        NSButton *cancel = [editor addButtonWithTitle:@"Cancel"];
        save.keyEquivalent = @"";
        cancel.keyEquivalent = @"";
        MacroRecorder *recorder = [[MacroRecorder alloc] initWithFrame:NSMakeRect(0, 0, 280, 42)];
        recorder.steps = [NSMutableArray array];
        recorder.label = [NSTextField labelWithString:@"Click here to record"];
        recorder.label.frame = NSMakeRect(8, 10, 265, 22);
        [recorder addSubview:recorder.label];
        editor.accessoryView = recorder;
        [self cancelForInput];
        NSWindow *window = editor.window;
        [NSApp activateIgnoringOtherApps:YES];
        [window makeKeyAndOrderFront:nil];
        [window makeFirstResponder:recorder];
        id monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
            handler:^NSEvent *(NSEvent *event) {
                if (event.window != window) return event;
                [recorder keyDown:event];
                return nil;
            }];
        NSModalResponse response = [editor runModal];
        [NSEvent removeMonitor:monitor];
        if (response != NSAlertFirstButtonReturn || recorder.steps.count == 0) return;
        [NSUserDefaults.standardUserDefaults setObject:recorder.steps forKey:macroKey(gesture)];
    }
    [NSUserDefaults.standardUserDefaults setInteger:sender.tag forKey:mappingKey(gesture)];
    for (NSMenuItem *choice in sender.menu.itemArray)
        choice.state = choice == sender ? NSControlStateValueOn : NSControlStateValueOff;
    [self cancelForInput];
}

static void drainDeviceIterator(io_iterator_t iterator) {
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) IOObjectRelease(service);
}

static void deviceListChanged(void *context, io_iterator_t iterator) {
    drainDeviceIterator(iterator);
    Mapper *mapper = (__bridge Mapper *)context;
    [mapper scheduleConnectionRefresh];
}

- (void)scheduleConnectionRefresh {
    NSUInteger revision = ++_connectionRevision;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (self->_deviceNotifications && revision == self->_connectionRevision)
            [self refreshConnection:nil];
    });
}

- (void)stopDeviceNotifications {
    ++_connectionRevision;
    if (_matchedDevices) IOObjectRelease(_matchedDevices);
    if (_removedDevices) IOObjectRelease(_removedDevices);
    if (_deviceNotifications) IONotificationPortDestroy(_deviceNotifications);
    _matchedDevices = _removedDevices = IO_OBJECT_NULL;
    _deviceNotifications = NULL;
}

- (void)configureAutoReconnect:(NSMenuItem *)item {
    [self stopDeviceNotifications];
    BOOL enabled = [NSUserDefaults.standardUserDefaults boolForKey:@"AutoReconnect"];
    if (enabled) {
        _deviceNotifications = IONotificationPortCreate(kIOMainPortDefault);
        if (_deviceNotifications) {
            void *context = (__bridge void *)self;
            kern_return_t added = IOServiceAddMatchingNotification(_deviceNotifications,
                kIOFirstMatchNotification, IOServiceMatching("AppleMultitouchDevice"),
                deviceListChanged, context, &_matchedDevices);
            kern_return_t removed = IOServiceAddMatchingNotification(_deviceNotifications,
                kIOTerminatedNotification, IOServiceMatching("AppleMultitouchDevice"),
                deviceListChanged, context, &_removedDevices);
            if (added == KERN_SUCCESS && removed == KERN_SUCCESS) {
                drainDeviceIterator(_matchedDevices);
                drainDeviceIterator(_removedDevices);
                IONotificationPortSetDispatchQueue(_deviceNotifications, dispatch_get_main_queue());
            } else {
                [self stopDeviceNotifications];
            }
        }
    }
    item.state = _deviceNotifications ? NSControlStateValueOn : NSControlStateValueOff;
    _manualReconnect.hidden = NO;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self stopDeviceNotifications];
}

- (void)toggleAutoReconnect:(NSMenuItem *)sender {
    BOOL enable = sender.state != NSControlStateValueOn;
    [NSUserDefaults.standardUserDefaults setBool:enable forKey:@"AutoReconnect"];
    [self configureAutoReconnect:sender];
    if (enable) [self refreshConnection:nil];
}

- (void)reconnectMouse:(id)sender {
    [self refreshConnection:nil];
}

- (void)refreshConnection:(NSTimer *)timer {
    void *previous = samples[0].device;
    _deviceStatus = startCapture();
    if (previous != samples[0].device) [self cancelForInput];
    self.captureStatus.title = _deviceStatus;
    if (!self.enabled && [NSUserDefaults.standardUserDefaults boolForKey:@"GesturesEnabled"] &&
        AXIsProcessTrusted()) [self toggleGestures:nil];
}

- (void)toggleGestures:(id)sender {
    if (!self.enabled) {
        if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{
            (__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES})) {
            self.captureStatus.title = @"Allow Accessibility, then choose Enable Gestures again";
            return;
        }
        NSEventMask mask = NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown |
                           NSEventMaskOtherMouseDown | NSEventMaskScrollWheel;
        _globalMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:mask handler:^(NSEvent *event) {
            [self observeMouseEvent:event];
        }];
        _localMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask handler:^NSEvent *(NSEvent *event) {
            [self observeMouseEvent:event];
            return event;
        }];
        if (!_globalMonitor || !_localMonitor) {
            [self pauseGestures];
            self.captureStatus.title = @"Could not monitor clicks and scrolling";
            return;
        }
        self.enabled = YES;
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"GesturesEnabled"];
        self.toggle.title = @"Pause Gestures";
        [self updateStatusIcon];
        self.captureStatus.title = _deviceStatus;
        [self cancelForInput];
        return;
    }
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"GesturesEnabled"];
    [self pauseGestures];
}

- (void)pauseGestures {
    self.enabled = NO;
    if (_globalMonitor) [NSEvent removeMonitor:_globalMonitor];
    if (_localMonitor) [NSEvent removeMonitor:_localMonitor];
    _globalMonitor = nil;
    _localMonitor = nil;
    self.toggle.title = @"Enable Gestures";
    [self updateStatusIcon];
    [self cancelForInput];
}

- (void)observeMouseEvent:(NSEvent *)event {
    if (event.type != NSEventTypeScrollWheel) {
        [self cancelForInput];
        return;
    }
    _multiTap = (MultiFingerTap){0};
    memset(_gestures, 0, sizeof(_gestures));
    _ignoreUntil = NSProcessInfo.processInfo.systemUptime + 0.18;
}

- (void)cancelForInput {
    _downSwipe = (DownSwipe){0};
    _swipeIgnoreUntil = NSProcessInfo.processInfo.systemUptime + 0.18;
    _multiTap = (MultiFingerTap){0};
    memset(_gestures, 0, sizeof(_gestures));
    _ignoreUntil = NSProcessInfo.processInfo.systemUptime + 0.18;
    pthread_mutex_lock(&lock);
    _cursor = framesReceived;
    pthread_mutex_unlock(&lock);
}

- (void)tick:(NSTimer *)timer {
    if (!self.enabled) return;
    double now = NSProcessInfo.processInfo.systemUptime;

    Sample batch[128];
    pthread_mutex_lock(&lock);
    unsigned long long end = framesReceived;
    if (end - _cursor > 128) {
        _cursor = end;
        _downSwipe = (DownSwipe){0};
        _multiTap = (MultiFingerTap){0};
        memset(_gestures, 0, sizeof(_gestures));
    }
    unsigned long long count = end - _cursor;
    for (unsigned long long i = 0; i < count; i++) batch[i] = trace[(_cursor + i) % TRACE_CAPACITY];
    _cursor = end;
    pthread_mutex_unlock(&lock);
    for (unsigned long long i = 0; i < count; i++) {
        if (batch[i].time >= _swipeIgnoreUntil && now - batch[i].time < 0.35 &&
            selectedAction(12) != ActionDisabled)
            trackDownSwipe(&_downSwipe, &batch[i]);
        if (batch[i].time >= _ignoreUntil && now - batch[i].time < 0.35) {
            flushTwoFingerTap(&_multiTap, batch[i].time);
            flushThreeFingerTap(&_multiTap, batch[i].time);
            processMultiFingerTap(&_multiTap, &batch[i]);
            processSample(&_gestures[0], &batch[i]);
        }
    }
    flushTap(&_gestures[0], now);
    flushTwoFingerTap(&_multiTap, now);
    flushThreeFingerTap(&_multiTap, now);
}
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--probe") == 0) {
            puts(startCapture().UTF8String);
            puts(dlsym(RTLD_DEFAULT, "CoreDockSendNotification") ? "Dock API available" : "Dock API unavailable");
            return 0;
        }
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        Mapper *delegate = [Mapper new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
