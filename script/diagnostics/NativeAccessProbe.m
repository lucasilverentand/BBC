#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <unistd.h>

// Declarations only. The probe resolves Apple's installed classes at runtime.
@protocol BBCDaemonObservation
+ (id)sharedInstance;
- (BOOL)connectToDaemonWithLaunch:(BOOL)launch;
- (BOOL)isConnected;
- (void)disconnectFromDaemon;
@end

static void Emit(NSDictionary *report) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil];
    fwrite(json.bytes, 1, json.length, stdout);
    putchar('\n');
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL connect = argc == 2 && strcmp(argv[1], "--connect") == 0;
        if (argc > 2 || (argc == 2 && !connect && strcmp(argv[1], "--metadata") != 0)) {
            fprintf(stderr, "Usage: probe_native_access.sh [--metadata|--connect]\n");
            return 64;
        }
        alarm(12);
        NSMutableDictionary *report = [@{
            @"probe": @"bbc-standalone-imcore",
            @"bundle_id": NSBundle.mainBundle.bundleIdentifier ?: @"none",
            @"os": NSProcessInfo.processInfo.operatingSystemVersionString,
            @"pid": @(getpid()),
            @"mutation_attempted": @NO,
            @"connection_attempted": @NO,
            @"sip_on_daemon_connection": @NO
        } mutableCopy];
        uint32_t config = 0;
        int (*readCSR)(uint32_t *) = dlsym(RTLD_DEFAULT, "csr_get_active_config");
        BOOL csrKnown = readCSR && readCSR(&config) == 0;
        report[@"csr_config"] = csrKnown ? @(config) : NSNull.null;
        report[@"sip_fully_enabled"] = csrKnown ? @((BOOL)(config == 0)) : NSNull.null;

        if (!dlopen("/System/Library/PrivateFrameworks/IMCore.framework/IMCore", RTLD_LAZY | RTLD_LOCAL)) {
            report[@"failure"] = @"framework_unavailable";
            Emit(report);
            return 2;
        }
        Class controllerClass = NSClassFromString(@"IMDaemonController");
        Class messageClass = NSClassFromString(@"IMMessage");
        report[@"emoji_setter_present"] = @((BOOL)(class_getInstanceMethod(messageClass, NSSelectorFromString(@"_associatedMessageEmoji:")) != NULL));
        report[@"emoji_getter_present"] = @((BOOL)(class_getInstanceMethod(messageClass, NSSelectorFromString(@"associatedMessageEmoji")) != NULL));
        NSDictionary *expected = @{
            @"connectToDaemonWithLaunch:": @"B20@0:8B16",
            @"isConnected": @"B16@0:8",
            @"disconnectFromDaemon": @"v16@0:8"
        };
        Method shared = class_getClassMethod(controllerClass, @selector(sharedInstance));
        BOOL compatible = shared && strcmp(method_getTypeEncoding(shared), "@16@0:8") == 0;
        for (NSString *name in expected) {
            Method method = class_getInstanceMethod(controllerClass, NSSelectorFromString(name));
            if (!method || strcmp(method_getTypeEncoding(method), [expected[name] UTF8String]) != 0) compatible = NO;
        }
        report[@"connection_signatures_supported"] = @(compatible);
        if (!connect) { Emit(report); return 0; }
        if (!compatible) {
            report[@"failure"] = @"signature_unavailable";
            Emit(report);
            return 2;
        }
        BOOL connected = NO;
        @try {
            id<BBCDaemonObservation> controller = [(id<BBCDaemonObservation>)controllerClass sharedInstance];
            report[@"connected_before"] = @([controller isConnected]);
            report[@"connection_attempted"] = @YES;
            // Never launch Messages, claim an Apple listener identity, request
            // extra capabilities, restart the daemon or dispatch a mutation.
            report[@"connect_return"] = @([controller connectToDaemonWithLaunch:NO]);
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
            while (![controller isConnected] && deadline.timeIntervalSinceNow > 0) {
                [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            }
            connected = [controller isConnected];
            report[@"connected_after"] = @(connected);
            [controller disconnectFromDaemon];
        } @catch (NSException *exception) {
            report[@"failure"] = @"native_exception";
            report[@"exception_name"] = exception.name;
            connected = NO;
        }
        BOOL sipOn = connected && csrKnown && config == 0;
        report[@"sip_on_daemon_connection"] = @(sipOn);
        Emit(report);
        // An accepted connection on a weakened/unknown host cannot pass the
        // SIP-on check. A daemon connection alone never verifies a Tapback.
        return !connected ? 2 : (sipOn ? 0 : 3);
    }
}
