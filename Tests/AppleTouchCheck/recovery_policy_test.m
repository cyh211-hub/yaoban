// Offline contract for the helper's stale-frame recovery throttle. No devices,
// private callbacks, input events, or application state are opened.
#define YB_TOUCH_CHECK_NO_MAIN 1
#include "../../Sources/AppleTouchCheck/main.m"
#include <sys/wait.h>

static void check(BOOL condition, NSString *message) { NSCAssert(condition, message); }

static NSString *readPipe(int fd) {
    char buffer[256] = {0};
    ssize_t count = read(fd, buffer, sizeof(buffer) - 1);
    return [[NSString alloc] initWithBytes:buffer length:(NSUInteger)MAX(count, 0) encoding:NSUTF8StringEncoding];
}

int main(void) {
    mach_timebase_info(&timebase);
    check(!shouldRecoverAfterFrameSilence(14.99, 0.01, 0), @"wait before the first 15-second quiet interval");
    check(shouldRecoverAfterFrameSilence(15.01, 0.01, 0), @"recover after an initial quiet interval");
    check(!shouldRecoverAfterFrameSilence(30.00, 15.01, 0), @"a recent frame cancels recovery");
    check(!shouldRecoverAfterFrameSilence(30.00, 0.01, 20.00), @"the cooldown prevents rapid retries");
    check(shouldRecoverAfterFrameSilence(35.01, 0.01, 20.00), @"recovery can retry after its bounded cooldown");

    int readyPipe[2]; check(pipe(readyPipe) == 0, @"create ready pipe");
    streamFD = readyPipe[1];
    YBObservation *first = newObservation((CFTypeRef)0x1);
    check(first && !first->accepting, @"new callback context starts disabled");
    announceReady(first);
    check(first->accepting && [readPipe(readyPipe[0]) isEqualToString:@"READY\n"], @"READY is emitted before accepting frames");
    close(readyPipe[0]); close(readyPipe[1]); streamFD = -1;

    int cancelPipe[2]; check(pipe(cancelPipe) == 0, @"create cancel pipe");
    streamFD = cancelPipe[1];
    YBObservation *old = newObservation((CFTypeRef)0x2);
    YBObservation *current = newObservation((CFTypeRef)0x3);
    announceReady(old); announceReady(current);
    pthread_mutex_lock(&old->lock); old->accepting = NO; pthread_mutex_unlock(&old->lock);
    YBContact contact = {0}; contact.normalized.position.x = 0.5; contact.normalized.position.y = 0.5;
    receiveFrame((CFTypeRef)0x2, &contact, 1, 1, 1, old);
    check(old->frames == 0, @"late callback stays rejected by its retired context");
    double beforeBadFrame = current->lastFrameAt;
    receiveFrame((CFTypeRef)0x3, NULL, 6, 1, 1, current);
    NSString *cancelLines = readPipe(cancelPipe[0]);
    check([cancelLines containsString:@"C "], @"malformed callback emits cancellation");
    check(current->lastFrameAt == beforeBadFrame && current->frames == 0, @"bad callback does not refresh frame liveness");
    close(cancelPipe[0]); close(cancelPipe[1]); streamFD = -1;

    int fullPipe[2]; check(pipe(fullPipe) == 0, @"create full pipe");
    int flags = fcntl(fullPipe[1], F_GETFL); check(flags >= 0 && fcntl(fullPipe[1], F_SETFL, flags | O_NONBLOCK) == 0, @"make pipe nonblocking");
    char fill[4096] = {0}; while (write(fullPipe[1], fill, sizeof(fill)) > 0) {}
    pid_t child = fork(); check(child >= 0, @"fork stream failure child");
    if (child == 0) { streamFD = fullPipe[1]; sendStream("C 0\n", 4); _exit(0); }
    int status = 0; check(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 74, @"full nonblocking pipe fails closed");
    close(fullPipe[0]); close(fullPipe[1]);
    puts("PASS: stale recovery, READY ordering, malformed-frame cancellation, late-context rejection, and full-pipe fail-closed; no device opened");
    return 0;
}
