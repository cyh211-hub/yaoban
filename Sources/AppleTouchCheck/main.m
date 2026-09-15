// Isolated touch receiver. Default build is a bounded read-only diagnostic;
// YB_TOUCH_SERVICE builds the app's parent-controlled coordinate-only helper.
// Private API names/signatures researched in calftrail/TrackMagic's public header;
// no third-party control, gesture, or microphone implementation is included.
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include <stddef.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <string.h>
#include <mach/mach_time.h>

static int streamFD = -1;
static mach_timebase_info_data_t timebase;
static const double YBFrameStarvationInterval = 15.0;
static double uptime(void) { return (double)mach_absolute_time() * timebase.numer / timebase.denom / 1e9; }
static BOOL shouldRecoverAfterFrameSilence(double now, double lastFrameAt, double lastRecoveryAt) {
    return lastFrameAt > 0 && now - lastFrameAt >= YBFrameStarvationInterval &&
        now - lastRecoveryAt >= YBFrameStarvationInterval;
}
static void sendStream(const char *line, size_t length) {
    if (streamFD < 0) return;
    if (length > 200) _exit(74);
    size_t sent = 0;
    while (sent < length) {
        ssize_t written = write(streamFD, line + sent, length - sent);
        if (written > 0) { sent += (size_t)written; continue; }
        if (written < 0 && errno == EINTR) continue;
        // A partial nonblocking stream can turn a drag into a tap. Fail closed
        // so the parent receives EOF and resets its gesture state.
        _exit(74);
    }
}

// ABI layout only. Never dereference more contacts than the supported bound.
typedef struct { float x, y; } YBPoint;
typedef struct { YBPoint position, velocity; } YBVector;
typedef struct {
    int32_t frame;
    double timestamp;
    int32_t path, state, finger, hand;
    YBVector normalized;
    float pressure;
    int32_t reserved1;
    float angle, major, minor;
    YBVector absolute;
    int32_t reserved2, reserved3;
    float density;
} YBContact;
_Static_assert(sizeof(YBContact) == 96, "Unexpected contact ABI");
_Static_assert(offsetof(YBContact, normalized) == 32, "Unexpected coordinate ABI");
typedef void (*YBFrameCallback)(CFTypeRef, const YBContact *, size_t, double, size_t, void *);
typedef struct {
    pthread_mutex_t lock;
    CFTypeRef expected;
    BOOL accepting;
    uint64_t frames, contacts, rejected, releases;
    uint64_t states[8];
    double minX, minY, maxX, maxY;
    double lastFrameAt;
} YBObservation;

enum { YBMaxObservationGenerations = 128 };
static YBObservation observations[YBMaxObservationGenerations];
static size_t observationGenerations = 0;

// Contexts are never recycled: a late private callback from an old MTDevice
// can only see its permanently disabled generation, never a new device (ABA).
static YBObservation *newObservation(CFTypeRef device) {
    if (observationGenerations == YBMaxObservationGenerations) return NULL;
    YBObservation *state = &observations[observationGenerations++];
    memset(state, 0, sizeof(*state));
    pthread_mutex_init(&state->lock, NULL);
    state->expected = device;
    state->minX = state->minY = INFINITY;
    state->maxX = state->maxY = -INFINITY;
    state->lastFrameAt = uptime();
    return state;
}

static void cancelStream(void) {
    char line[48];
    int length = snprintf(line, sizeof(line), "C %.6f\n", uptime());
    if (length > 0 && (size_t)length < sizeof(line)) sendStream(line, (size_t)length);
}

static void announceReady(YBObservation *state) {
    pthread_mutex_lock(&state->lock);
    sendStream("READY\n", 6);
    state->accepting = YES;
    pthread_mutex_unlock(&state->lock);
}

static void receiveFrame(CFTypeRef device, const YBContact *contacts, size_t count,
                         double time, size_t frame, void *context) {
    (void)frame;
    YBObservation *state = context;
    if (!state) return;
    pthread_mutex_lock(&state->lock);
    if (!state->accepting || device != state->expected) { pthread_mutex_unlock(&state->lock); return; }
    if (count > 5 || (count && !contacts) || !isfinite(time)) {
        state->rejected++;
        cancelStream();
        pthread_mutex_unlock(&state->lock); return;
    }
    BOOL contactValid = count == 1 && isfinite(contacts[0].normalized.position.x) && isfinite(contacts[0].normalized.position.y) &&
        contacts[0].normalized.position.x >= -0.1 && contacts[0].normalized.position.x <= 1.1 &&
        contacts[0].normalized.position.y >= -0.1 && contacts[0].normalized.position.y <= 1.1 &&
        contacts[0].state >= 0 && contacts[0].state <= 7;
    if (count > 1 || (count == 1 && !contactValid)) {
        state->rejected++;
        cancelStream();
        pthread_mutex_unlock(&state->lock); return;
    }
    state->frames++;
    state->lastFrameAt = uptime();
    if (!count) {
        state->releases++;
        char line[48]; int length = snprintf(line, sizeof(line), "R %.6f\n", uptime());
        if (length > 0 && (size_t)length < sizeof(line)) sendStream(line, (size_t)length);
    } else {
        char line[200]; int length = snprintf(line, sizeof(line), "T %.6f %d %d %.6f %.6f\n", uptime(), contacts[0].path,
            contacts[0].state, contacts[0].normalized.position.x, contacts[0].normalized.position.y);
        if (length > 0 && (size_t)length < sizeof(line)) sendStream(line, (size_t)length);
        state->contacts++;
        state->states[contacts[0].state]++;
        state->minX = fmin(state->minX, contacts[0].normalized.position.x);
        state->minY = fmin(state->minY, contacts[0].normalized.position.y);
        state->maxX = fmax(state->maxX, contacts[0].normalized.position.x);
        state->maxY = fmax(state->maxY, contacts[0].normalized.position.y);
    }
    pthread_mutex_unlock(&state->lock);
}

static id property(io_registry_entry_t node, CFStringRef key) {
    return CFBridgingRelease(IORegistryEntryCreateCFProperty(node, key, kCFAllocatorDefault, 0));
}

static BOOL samePhysicalRemote(io_registry_entry_t service, NSString *expected) {
    io_registry_entry_t node = service;
    IOObjectRetain(node);
    BOOL matched = NO;
    for (int depth = 0; node && depth < 8; depth++) {
        id serial = property(node, CFSTR("SerialNumber"));
        if ([serial isKindOfClass:NSString.class] && [serial length] > 0 && [serial length] <= 256) {
            NSData *bytes = [serial dataUsingEncoding:NSUTF8StringEncoding];
            unsigned char digest[CC_SHA256_DIGEST_LENGTH];
            CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
            NSMutableString *identity = [NSMutableString stringWithString:@"apple3:"];
            for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [identity appendFormat:@"%02x", digest[i]];
            if ([identity isEqualToString:expected]) { matched = YES; break; }
        }
        io_registry_entry_t parent = 0;
        kern_return_t result = IORegistryEntryGetParentEntry(node, kIOServicePlane, &parent);
        IOObjectRelease(node);
        node = result == KERN_SUCCESS ? parent : 0;
    }
    if (node) IOObjectRelease(node);
    return matched;
}

// Every recovery repeats the same model, transport and hashed-serial checks as
// initial attachment. A stale MTDevice object is never reused for another HID.
static io_service_t exactBoundSurface(NSString *expected, NSUInteger *matches) {
    if (matches) *matches = 0;
    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleMultitouchDevice"), &iterator) != KERN_SUCCESS) return 0;
    io_service_t matched = 0, candidate = 0;
    NSUInteger count = 0;
    while ((candidate = IOIteratorNext(iterator))) {
        id transport = property(candidate, CFSTR("Transport"));
        BOOL model = [property(candidate, CFSTR("ProductID")) isEqual:@789];
        if (model && ([transport isEqual:@"Bluetooth Low Energy"] || [transport isEqual:@"Bluetooth"]) && samePhysicalRemote(candidate, expected)) {
            count++;
            if (!matched) { matched = candidate; IOObjectRetain(matched); }
        }
        IOObjectRelease(candidate);
    }
    IOObjectRelease(iterator);
    if (matches) *matches = count;
    if (count != 1 && matched) { IOObjectRelease(matched); matched = 0; }
    return matched;
}

static BOOL verifiedSurface(CFTypeRef device, io_service_t service,
                            int32_t (*getID)(CFTypeRef, uint64_t *),
                            int32_t (*dimensions)(CFTypeRef, int *, int *),
                            bool (*builtIn)(CFTypeRef)) {
    uint64_t deviceID = 0;
    int width = 0, height = 0;
    id registryID = property(service, CFSTR("Multitouch ID"));
    return device && [registryID isKindOfClass:NSNumber.class] && getID(device, &deviceID) == 0 &&
        deviceID == [registryID unsignedLongLongValue] && dimensions(device, &width, &height) == 0 &&
        width > 0 && height > 0 && !builtIn(device);
}

static void report(NSDictionary *values) {
    if (streamFD >= 0) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:values options:NSJSONWritingSortedKeys error:nil];
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

#ifndef YB_TOUCH_CHECK_NO_MAIN
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        int seconds = 0;
        NSString *requiredID = nil;
#ifdef YB_TOUCH_SERVICE
        if (argc != 3 || strcmp(argv[1], "--stream") != 0) return 2;
        requiredID = [[NSString alloc] initWithUTF8String:argv[2]];
        if (![[NSUUID alloc] initWithUUIDString:requiredID]) return 2;
        streamFD = dup(STDOUT_FILENO);
        if (streamFD < 0) return 2;
        fcntl(streamFD, F_SETFD, FD_CLOEXEC);
        fcntl(streamFD, F_SETFL, O_NONBLOCK);
        freopen("/dev/null", "w", stdout);
        fcntl(STDIN_FILENO, F_SETFL, O_NONBLOCK);
        signal(SIGPIPE, SIG_IGN);
        seconds = 1; // Stream lifetime is tied to the parent pipe, not a fixed timeout.
#else
        if (argc == 3 && strcmp(argv[1], "--observe") == 0) {
            char *end = NULL;
            long requested = strtol(argv[2], &end, 10);
            if (!end || *end || requested < 1 || requested > 180) return 2;
            seconds = (int)requested;
        } else if (argc != 1) { report(@{@"status":@"usage: check [--observe 1..180]"}); return 2; }
#endif
        mach_timebase_info(&timebase);
        NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *libraryURL = [support URLByAppendingPathComponent:@"MiRemoteLab/设备库.json"];
        NSData *data = [NSData dataWithContentsOfURL:libraryURL options:0 error:nil];
        NSDictionary *library = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![library isKindOfClass:NSDictionary.class] || ![library[@"devices"] isKindOfClass:NSArray.class]) {
            report(@{@"status":@"device-library-unavailable"}); return 2;
        }
        NSDictionary *selected = nil;
        for (id item in library[@"devices"]) {
            if ([item isKindOfClass:NSDictionary.class] && [item[@"id"] isEqual:library[@"selectedID"]]) selected = item;
        }
        NSDictionary *binding = [selected[@"binding"] isKindOfClass:NSDictionary.class] ? selected[@"binding"] : nil;
        if (requiredID && ![selected[@"id"] isEqual:requiredID]) return 2;
        NSString *expected = binding[@"hidIdentity"];
        if (![binding[@"modelID"] isEqual:@"apple-siri-remote"] || ![expected isKindOfClass:NSString.class] ||
            ![expected hasPrefix:@"apple3:"] || expected.length != 71) {
            report(@{@"status":@"select-bound-apple-remote-first"}); return 2;
        }
        NSUInteger matches = 0;
        io_service_t matched = exactBoundSurface(expected, &matches);
        if (!matched) {
            report(@{@"status":@"exact-bound-surface-unavailable", @"matches":@(matches)}); return 3;
        }
        // Load only the OS-owned library, after resolving an exact bound device.
        void *framework = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW | RTLD_LOCAL);
        CFTypeRef (*create)(io_service_t) = framework ? dlsym(framework, "MTDeviceCreateFromService") : NULL;
        void (*release)(CFTypeRef) = framework ? dlsym(framework, "MTDeviceRelease") : NULL;
        bool (*builtIn)(CFTypeRef) = framework ? dlsym(framework, "MTDeviceIsBuiltIn") : NULL;
        int32_t (*getID)(CFTypeRef, uint64_t *) = framework ? dlsym(framework, "MTDeviceGetDeviceID") : NULL;
        int32_t (*dimensions)(CFTypeRef, int *, int *) = framework ? dlsym(framework, "MTDeviceGetSensorSurfaceDimensions") : NULL;
        if (!create || !release || !builtIn || !getID || !dimensions) {
            report(@{@"status":@"private-interface-unavailable", @"libraryLoaded":@(framework != NULL),
                     @"create":@(create != NULL), @"release":@(release != NULL),
                     @"builtIn":@(builtIn != NULL), @"getID":@(getID != NULL), @"dimensions":@(dimensions != NULL)});
            IOObjectRelease(matched); return 4;
        }
        CFTypeRef device = create(matched);
        uint64_t deviceID = 0;
        int width = 0, height = 0;
        int32_t idResult = device ? getID(device, &deviceID) : -1;
        id registryID = property(matched, CFSTR("Multitouch ID"));
        BOOL identityMatches = device && [registryID isKindOfClass:NSNumber.class] && idResult == 0 && deviceID == [registryID unsignedLongLongValue];
        int32_t dimResult = device ? dimensions(device, &width, &height) : -1;
        BOOL usable = verifiedSurface(device, matched, getID, dimensions, builtIn);
        report(@{@"status":usable ? @"exact-bound-surface-opened" : @"surface-open-unverified",
                 @"identityVerified":@(identityMatches),
                 @"dimensionsAvailable":@(dimResult == 0), @"width":@(width), @"height":@(height),
                 @"callbacksStarted":@NO, @"cursorOutput":@NO, @"audioCapture":@NO});
        if (usable && seconds) {
            void (*subscribe)(CFTypeRef, YBFrameCallback, void *) = dlsym(framework, "MTRegisterContactFrameCallbackWithRefcon");
            void (*unsubscribe)(CFTypeRef, YBFrameCallback) = dlsym(framework, "MTUnregisterContactFrameCallback");
            int32_t (*start)(CFTypeRef, int) = dlsym(framework, "MTDeviceStart");
            int32_t (*stop)(CFTypeRef) = dlsym(framework, "MTDeviceStop");
            bool (*running)(CFTypeRef) = dlsym(framework, "MTDeviceIsRunning");
            if (!subscribe || !unsubscribe || !start || !stop || !running || ![selected[@"enabled"] boolValue]) {
                report(@{@"status":@"observation-unavailable-or-device-paused"});
                release(device); IOObjectRelease(matched); return 6;
            }
            // Each generation stays allocated until exit. Late callbacks can
            // never target a reused context for another MTDevice.
            YBObservation *observation = newObservation(device);
            if (!observation) { release(device); IOObjectRelease(matched); return 8; }
            subscribe(device, receiveFrame, observation);
            int32_t result = start(device, 0);
            BOOL started = result == 0 && running(device);
            if (started) announceReady(observation);
            report(@{@"status":started ? @"observation-started" : @"observation-start-failed",
                     @"seconds":@(seconds), @"result":@(result), @"cursorOutput":@NO});
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
            NSString *stopReason = started ? @"time-limit" : @"start-failed";
            double lastRecoveryAt = 0;
            int exitCode = started ? 0 : 7;
            while (started && (streamFD >= 0 || deadline.timeIntervalSinceNow > 0)) {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false);
                if (streamFD >= 0) {
                    char byte;
                    ssize_t count = read(STDIN_FILENO, &byte, 1);
                    if (count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR)) { stopReason = @"parent-closed"; break; }
                }
                NSData *currentData = [NSData dataWithContentsOfURL:libraryURL options:0 error:nil];
                id current = currentData ? [NSJSONSerialization JSONObjectWithData:currentData options:0 error:nil] : nil;
                BOOL stillSelected = NO;
                if ([current isKindOfClass:NSDictionary.class] && [current[@"selectedID"] isEqual:selected[@"id"]] &&
                    [current[@"devices"] isKindOfClass:NSArray.class]) {
                    for (id item in current[@"devices"]) {
                        if ([item isKindOfClass:NSDictionary.class] && [item[@"id"] isEqual:selected[@"id"]] &&
                            [item[@"enabled"] boolValue] && [item[@"binding"] isEqual:binding]) stillSelected = YES;
                    }
                }
                if (!stillSelected) { stopReason = @"selection-or-binding-changed"; break; }
                if (!running(device) || !samePhysicalRemote(matched, expected)) { stopReason = @"device-unavailable"; break; }
                double now = uptime();
                pthread_mutex_lock(&observation->lock);
                BOOL starved = shouldRecoverAfterFrameSilence(now, observation->lastFrameAt, lastRecoveryAt);
                pthread_mutex_unlock(&observation->lock);
                if (!starved) continue;

                // MTDeviceStart can succeed while a sleeping remote's service
                // remains stale and emits no callbacks. Retry only after a
                // 15-second quiet interval and only for the exact bound surface.
                lastRecoveryAt = now;
                pthread_mutex_lock(&observation->lock);
                observation->accepting = NO;
                pthread_mutex_unlock(&observation->lock);
                stop(device); unsubscribe(device, receiveFrame); release(device); IOObjectRelease(matched);
                matched = exactBoundSurface(expected, &matches);
                device = matched ? create(matched) : NULL;
                if (!matched || !verifiedSurface(device, matched, getID, dimensions, builtIn)) {
                    if (device) release(device);
                    if (matched) IOObjectRelease(matched);
                    device = NULL; matched = 0; stopReason = @"stale-surface-recovery-unavailable"; exitCode = 7; break;
                }
                YBObservation *nextObservation = newObservation(device);
                if (!nextObservation) {
                    release(device); IOObjectRelease(matched);
                    device = NULL; matched = 0; stopReason = @"stale-surface-recovery-limit"; exitCode = 8; break;
                }
                observation = nextObservation;
                subscribe(device, receiveFrame, observation);
                result = start(device, 0);
                if (result != 0 || !running(device)) { stopReason = @"stale-surface-recovery-start-failed"; exitCode = 7; break; }
                announceReady(observation);
            }
            pthread_mutex_lock(&observation->lock);
            observation->accepting = NO;
            pthread_mutex_unlock(&observation->lock);
            if (device) stop(device);
            if (device) unsubscribe(device, receiveFrame);
            uint64_t totalFrames = 0, totalContacts = 0, totalRejected = 0, totalReleases = 0;
            uint64_t totalStates[8] = {0};
            double minX = INFINITY, minY = INFINITY, maxX = -INFINITY, maxY = -INFINITY;
            for (size_t generation = 0; generation < observationGenerations; generation++) {
                YBObservation *state = &observations[generation];
                pthread_mutex_lock(&state->lock);
                totalFrames += state->frames; totalContacts += state->contacts;
                totalRejected += state->rejected; totalReleases += state->releases;
                for (int i = 0; i < 8; i++) totalStates[i] += state->states[i];
                minX = fmin(minX, state->minX); minY = fmin(minY, state->minY);
                maxX = fmax(maxX, state->maxX); maxY = fmax(maxY, state->maxY);
                pthread_mutex_unlock(&state->lock);
            }
            NSMutableDictionary *summary = [@{@"status":@"observation-stopped", @"reason":stopReason,
                @"frames":@(totalFrames), @"contacts":@(totalContacts),
                @"rejected":@(totalRejected), @"emptyFrames":@(totalReleases),
                @"cursorOutput":@NO, @"audioCapture":@NO} mutableCopy];
            NSMutableArray *states = [NSMutableArray array];
            for (int i = 0; i < 8; i++) [states addObject:@(totalStates[i])];
            summary[@"contactStates"] = states;
            if (totalContacts) {
                summary[@"xRange"] = @[@(minX), @(maxX)];
                summary[@"yRange"] = @[@(minY), @(maxY)];
            }
            report(summary);
            if (exitCode) { if (device) release(device); if (matched) IOObjectRelease(matched); return exitCode; }
        }
        if (device) release(device);
        if (matched) IOObjectRelease(matched);
        // Private framework cleanup is left to process exit.
        return usable ? 0 : 5;
    }
}
#endif
