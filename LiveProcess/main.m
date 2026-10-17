//
//  main.m
//  LiveProcess
//
//  Created by Duy Tran on 3/5/25.
//

#import <dlfcn.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import "../LiveContainer/utils.h"
#import "../LiveContainer/Tweaks/Tweaks.h"
#import "../SideStoreSupport/XPCServer.h"

@interface LiveProcessHandler : NSObject<NSExtensionRequestHandling>
@end
@implementation LiveProcessHandler
static NSExtensionContext *extensionContext;
static NSDictionary *retrievedAppInfo;
+ (NSExtensionContext *)extensionContext {
    return extensionContext;
}

+ (NSDictionary *)retrievedAppInfo {
    return retrievedAppInfo;
}

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context {
    extensionContext = context;
    retrievedAppInfo = [context.inputItems.firstObject userInfo];
    // Return control to LiveContainerMain
    CFRunLoopStop(CFRunLoopGetMain());
}
@end

// Host for guest apps' App Extensions (e.g. Gecko child processes in Reynard).
// The guest app (running inside LiveContainer) sends an extension request to
// our LiveProcess.appex with these keys in the input item's userInfo:
//  - lcGuestExtensionPath: absolute path to the guest .appex
//  - lcGuestExtensionPrincipalClass: principal class name (optional, falls back
//    to the appex's own Info.plist)
//  - lcGuestExtensionInputItems: NSExtensionItems forwarded to the guest handler
// Sandbox access to the .appex is granted by adding a bookmark to "bookmarks",
// which the normal bookmark resolution loop below already handles.
@interface LCGuestExtensionContext : NSExtensionContext
@property(nonatomic, copy) NSArray *guestInputItems;
@end
@implementation LCGuestExtensionContext
- (NSArray *)inputItems {
    return self.guestInputItems;
}
// Both completion paths are forwarded so the guest handler can finish or
// cancel the request it was started for
- (void)cancelRequestWithError:(NSError *)error {
    [LiveProcessHandler.extensionContext cancelRequestWithError:error];
}
- (void)completeRequestReturningItems:(NSArray *)items completionHandler:(void (^)(BOOL expired))completionHandler {
    [LiveProcessHandler.extensionContext completeRequestReturningItems:items completionHandler:completionHandler];
}
@end

// Unlike NSCAssert (compiled out in Release), failures here cancel the host's
// extension request, which surfaces the message to the guest app and to logs
static NSError *GuestExtensionError(NSString *description) {
    return [NSError errorWithDomain:@"LiveContainer.GuestExtension" code:1
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

// Returns an error only when launch must be aborted; a nil return hands
// control over to the guest handler for the remainder of the process lifetime
static NSError *LCLaunchGuestExtensionProcessInner(NSDictionary *appInfo) {
    NSString *extPath = appInfo[@"lcGuestExtensionPath"];
    NSBundle *extBundle = [NSBundle bundleWithPath:extPath];
    if(!extBundle) return GuestExtensionError([NSString stringWithFormat:@"guest extension bundle not found at %@", extPath]);

    // A real extension process sees its own .appex as the main bundle; guest
    // code such as Gecko's child bootstrap may look up resources through it
    overwriteMainNSBundle(extBundle);
    overwriteMainCFBundle();

    // Make @executable_path resolve into the guest app bundle so frameworks
    // embedded there can be found (same trick as bootStrapGuestApp)
    NSString *execPath = extBundle.executablePath;
    if(!execPath) return GuestExtensionError([NSString stringWithFormat:@"guest extension executable not found in %@", extPath]);
    const char *appExecPath = execPath.fileSystemRepresentation;
    const char **processPath = _CFGetProcessPath();
    if(processPath) *processPath = appExecPath;
    overwriteExecPath(appExecPath);

    // Cross-bundle loading requires the library validation bypass when JIT is on
    int csFlags = 0;
    csops(getpid(), 0, &csFlags, sizeof(csFlags));
    if(csFlags & CS_DEBUGGED) {
        init_bypassDyldLibValidation();
    }

    __block void *handle = NULL;
    __block const char *dlerr = NULL;
    bypass_seg_count_check(^{
        handle = dlopen_nolock(appExecPath, RTLD_LAZY | RTLD_GLOBAL);
        if(!handle) dlerr = dlerror();
    });
    if(!handle) return GuestExtensionError([NSString stringWithFormat:@"dlopen guest extension failed: %s", dlerr ?: "unknown"]);

    NSString *principalName = appInfo[@"lcGuestExtensionPrincipalClass"];
    if(!principalName) {
        principalName = extBundle.infoDictionary[@"NSExtension"][@"NSExtensionPrincipalClass"];
    }
    Class principalClass = NSClassFromString(principalName);
    if(!principalClass) return GuestExtensionError([NSString stringWithFormat:@"guest extension principal class %@ not found", principalName]);

    id guestInputItems = appInfo[@"lcGuestExtensionInputItems"];
    if(!guestInputItems) return GuestExtensionError(@"missing lcGuestExtensionInputItems");

    LCGuestExtensionContext *context = [[LCGuestExtensionContext alloc] init];
    context.guestInputItems = guestInputItems;

    // A real extension host keeps the principal object alive for the process
    // lifetime, and guests (Gecko) store it without retaining
    static id<NSExtensionRequestHandling> handler;
    handler = [[principalClass alloc] init];
    if(!handler) return GuestExtensionError(@"failed to create guest extension handler");
    [handler beginRequestWithExtensionContext:context];
    return nil;
}

static int LCLaunchGuestExtensionProcess(NSDictionary *appInfo) {
    NSError *error = LCLaunchGuestExtensionProcessInner(appInfo);
    if(error) {
        NSLog(@"[LC] guest extension launch failed: %@", error);
        [LiveProcessHandler.extensionContext cancelRequestWithError:error];
        return 0;
    }
    // Keep the process (and the extension request) alive; the guest handler
    // blocks in its own main loop and/or services the runloop from here
    CFRunLoopRun();
    return 0;
}

extern int LiveContainerMain(int argc, char *argv[]);
static char **_envp, **_apple = NULL;
int LiveProcessMain(int argc, char *argv[]) {
    // Let NSExtensionContext initialize, once it's done it will call CFRunLoopStop
    CFRunLoopRun();
    // Ensure app info is delivered
    NSDictionary *appInfo = LiveProcessHandler.retrievedAppInfo;
    NSCAssert(appInfo, @"Failed to retrieve app info");
    
    // Check if we received a request to execute a custom payload
    NSString *customPayloadDylib = appInfo[@"customPayloadDylib"];
    if(customPayloadDylib) {
        void *handle = dlopen(customPayloadDylib.fileSystemRepresentation, RTLD_LAZY);
        NSCAssert(appInfo, @"Failed to load custom payload dylib at path: %@", customPayloadDylib);
        
        NSString *customPayloadEntry = appInfo[@"customPayloadEntry"];
        NSCAssert(customPayloadEntry, @"Missing customPayloadEntry");
        int (*payloadEntry)(int, char **, char **, char **) = dlsym(handle, customPayloadEntry.UTF8String);
        return payloadEntry(argc, argv, _envp, _apple);
    }
    
    NSLog(@"Retrieved app info: %@", appInfo);
    // Set LiveContainer's home path
    setenv("LP_HOME_PATH", getenv("HOME"), 1);
    const char *overrideHomePath = [appInfo[@"lcHomePath"] fileSystemRepresentation];
    if(overrideHomePath) setenv("LC_HOME_PATH", overrideHomePath, 1);
    // Pass selected app info to user defaults
    NSUserDefaults *lcUserDefaults = NSUserDefaults.standardUserDefaults;
    [lcUserDefaults setObject:appInfo[@"hostUrlScheme"] forKey:@"hostUrlScheme"];
    [lcUserDefaults setObject:appInfo[@"launchAppUrlScheme"] forKey:@"launchAppUrlScheme"];
    [lcUserDefaults setObject:appInfo[@"selected"] forKey:@"selected"];
    [lcUserDefaults setObject:appInfo[@"selectedContainer"] forKey:@"selectedContainer"];
    
    bool access = false;
    NSArray* bookmarks = appInfo[@"bookmarks"];
    NSMutableArray<NSURL *>* bookmarkedUrls = [NSMutableArray array];
    for(int i = 0; i < bookmarks.count; i++) {
        bool isStale = false;
        NSError* error = nil;
        bookmarkedUrls[i] = [NSURL URLByResolvingBookmarkData:bookmarks[i] options:0 relativeToURL:nil bookmarkDataIsStale:&isStale error:&error];
        access = [bookmarkedUrls[i] startAccessingSecurityScopedResource];
    }

    // Guest apps may ask us to host their App Extensions (e.g. Gecko child
    // processes); this must run after bookmark resolution for sandbox access
    if(appInfo[@"lcGuestExtensionPath"]) {
        return LCLaunchGuestExtensionProcess(appInfo);
    }

    if ([appInfo[@"selected"] isEqualToString:@"builtinSideStore"]) {
        if(access && bookmarkedUrls.count > 0) {
            [lcUserDefaults setObject:bookmarkedUrls.firstObject.path forKey:@"specifiedSideStoreContainerPath"];
        }
        NSXPCListenerEndpoint* endpoint = appInfo[@"endpoint"];

        NSXPCConnection* connection = [[NSXPCConnection alloc] initWithListenerEndpoint:endpoint];
        connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(RefreshServer)];
        connection.interruptionHandler = ^{
            NSLog(@"interrupted!!!");
        };
        
        [connection activate];
        
        NSObject<RefreshServer>* proxy = [connection remoteObjectProxy];
        LiveProcessSideStoreHandler.shared.server = proxy;
        LiveProcessSideStoreHandler.shared.connection = connection;
        
    }

    
    return LiveContainerMain(argc, argv);
}

// this is our fake UIApplicationMain called from _xpc_objc_uimain (xpc_main)
__attribute__((visibility("default")))
int UIApplicationMain(int argc, char * argv[], NSString * principalClassName, NSString * delegateClassName) {
    return LiveProcessMain(argc, argv);
}

// NSExtensionMain will load UIKit and call UIApplicationMain, so we need to redirect it to our fake one
static void* (*orig_dlopen)(void* dyldApiInstancePtr, const char* path, int mode);
static void* hook_dlopen(void* dyldApiInstancePtr, const char* path, int mode) {
    const char *UIKitFrameworkPath = "/System/Library/Frameworks/UIKit.framework/UIKit";
    if(path && !strncmp(path, UIKitFrameworkPath, strlen(UIKitFrameworkPath))) {
        // switch back to original dlopen
        performHookDyldApi("dlopen", 2, (void**)&orig_dlopen, orig_dlopen);
        // FIXME: may be incompatible with jailbreak tweaks?
        return RTLD_MAIN_ONLY;
    } else {
        __attribute__((musttail)) return orig_dlopen(dyldApiInstancePtr, path, mode);
    }
}

// Extension entry point
int NSExtensionMain(int argc, char *argv[], char *envp[], char *apple[]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
    method_setImplementation(class_getInstanceMethod(NSClassFromString(@"NSXPCDecoder"), @selector(_validateAllowedClass:forKey:allowingInvocations:)), (IMP)hook_do_nothing);
#pragma clang diagnostic pop
    // hook dlopen UIKit
    performHookDyldApi("dlopen", 2, (void**)&orig_dlopen, hook_dlopen);
    // call the real one
    _envp = envp;
    _apple = apple;
    int (*orig_NSExtensionMain)(int argc, char * argv[]) = dlsym(RTLD_NEXT, "NSExtensionMain");
    return orig_NSExtensionMain(argc, argv);
}
