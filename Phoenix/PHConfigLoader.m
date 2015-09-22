//
//  PHConfigLoader.m
//  Phoenix
//
//  Created by Steven on 12/2/13.
//  Copyright (c) 2013 Steven. All rights reserved.
//

#import "PHConfigLoader.h"

#import <JavaScriptCore/JavaScriptCore.h>

#import "PHHotKey.h"
#import "PHAlerts.h"
#import "PHPathWatcher.h"

#import "PHMousePosition.h"

#import "PHWindow.h"
#import "PHApp.h"
#import "NSScreen+PHExtension.h"

@interface PHConfigLoader ()

@property NSMutableArray* hotkeys;
@property NSMutableSet* configPaths;
@property PHPathWatcher* watcher;

@end


static NSString* PHConfigPath = @"~/.phoenix.js";


@implementation PHConfigLoader

- (id) init {
    if (self = [super init]) {
        self.configPaths = [NSMutableSet new];
    }
    return self;
}

- (void) resetConfigPaths {
    [self.configPaths removeAllObjects];
    [self.configPaths addObject: PHConfigPath];
}

- (void) addConfigPath: (NSString *) path {
    [self.configPaths addObject: path];
}

- (void) setupConfigWatcher {
    self.watcher = [PHPathWatcher watcherFor: [self.configPaths allObjects] handler:^{
        [[self class] cancelPreviousPerformRequestsWithTarget:self selector:@selector(reloadWithAlert) object:nil];
        [self performSelector:@selector(reloadWithAlert) withObject:nil afterDelay:0.25];
    }];
}

- (void)createConfigInFile:(NSString *)filename {
    [[NSFileManager defaultManager] createFileAtPath:filename
                                            contents:[@"" dataUsingEncoding:NSUTF8StringEncoding]
                                          attributes:nil];
    NSString *message = [NSString stringWithFormat:@"I just created %@ for you :)", filename];
    [[PHAlerts sharedAlerts] show:message duration:7.0];
}

- (void) reload {
    [self resetConfigPaths];
    
    NSString* filename = [PHConfigPath stringByStandardizingPath];
    NSString* config = [NSString stringWithContentsOfFile:filename encoding:NSUTF8StringEncoding error:NULL];
    
    if (!config) {
        [self createConfigInFile:filename];
        return;
    }
    
    [self.hotkeys makeObjectsPerformSelector:@selector(disable)];
    self.hotkeys = [NSMutableArray array];
    
    JSContext* ctx = [[JSContext alloc] initWithVirtualMachine:[[JSVirtualMachine alloc] init]];
    
    ctx.exceptionHandler = ^(JSContext* ctx, JSValue* val) {
        [[PHAlerts sharedAlerts] show:[NSString stringWithFormat:@"[js exception] %@", val] duration:3.0];
    };
    
    NSURL* _jsURL = [[NSBundle mainBundle] URLForResource:@"underscore-min" withExtension:@"js"];
    NSString* _js = [NSString stringWithContentsOfURL:_jsURL encoding:NSUTF8StringEncoding error:NULL];
    [ctx evaluateScript:_js];
    [self setupAPI:ctx];
    
    [ctx evaluateScript:config];
    [self setupConfigWatcher];
}

- (void) reloadWithAlert {
    [self reload];
    [[PHAlerts sharedAlerts] show:@"Phoenix config loaded" duration:1.0];
}

- (void) setupAPI:(JSContext*)ctx {
    JSValue* api = [JSValue valueWithNewObjectInContext:ctx];
    ctx[@"api"] = api;
    
    api[@"reload"] = ^(NSString* str) {
        [self reloadWithAlert];
    };
    
    api[@"launch"] = ^(NSString* appName) {
        [[NSWorkspace sharedWorkspace] launchApplication:appName];
    };
    
    api[@"alert"] = ^(NSString* str, CGFloat duration) {
        if (isnan(duration))
            duration = 2.0;
        
        [[PHAlerts sharedAlerts] show:str duration:duration];
    };
    
    api[@"cancelAlerts"] = ^() {
        [[PHAlerts sharedAlerts] cancelAlerts];
    };
    
    api[@"log"] = ^(NSString* msg) {
        NSLog(@"%@", msg); 
    };
    
    api[@"bind"] = ^(NSString* key, NSArray* mods, JSValue* handler) {
        PHHotKey* hotkey = [PHHotKey withKey:key mods:mods handler:^BOOL{
            return [[handler callWithArguments:@[]] toBool];
        }];
        [self.hotkeys addObject:hotkey];
        [hotkey enable];
        return hotkey;
    };

    api[@"runCommand"] = ^(NSString* path, NSArray *args) {
        NSTask *task = [[NSTask alloc] init];

        if (args) {
          [task setArguments:args];
        }

        [task setLaunchPath:path];
        [task launch];

        while([task isRunning]);
    };
    
    api[@"setTint"] = ^(NSArray *red, NSArray *green, NSArray *blue) {
        CGGammaValue cred[red.count];
        for (int i = 0; i < red.count; ++i) {
            cred[i] = [[red objectAtIndex:i] floatValue];
        }
        CGGammaValue cgreen[green.count];
        for (int i = 0; i < green.count; ++i) {
            cgreen[i] = [[green objectAtIndex:i] floatValue];
        }
        CGGammaValue cblue[blue.count];
        for (int i = 0; i < blue.count; ++i) {
            cblue[i] = [[blue objectAtIndex:i] floatValue];
        }
        CGSetDisplayTransferByTable(CGMainDisplayID(), (int)sizeof(cred) / sizeof(cred[0]), cred, cgreen, cblue);
    };
    
    __weak JSContext* weakCtx = ctx;
    
    ctx[@"require"] = ^(NSString *path) {
        path = [path stringByStandardizingPath];
        
        if(! [path hasPrefix: @"/"]) {
            NSString *configPath = [PHConfigPath stringByResolvingSymlinksInPath];
            NSURL *requirePathUrl = [NSURL URLWithString: path relativeToURL: [NSURL URLWithString: configPath]];
            path = [requirePathUrl absoluteString];
        }
        
        NSURL *pathUrl = [NSURL URLWithString:path];
        NSFileManager *fileManager = [NSFileManager defaultManager];
        BOOL isDir;
        BOOL fileExists = [fileManager fileExistsAtPath: path isDirectory: &isDir];

        // require a single JS file
        if (fileExists && ! isDir){
            [self addConfigPath: path];
            NSString* _js = [NSString stringWithContentsOfFile: path
                                                      encoding: NSUTF8StringEncoding
                                                         error: NULL];
            return [weakCtx evaluateScript:_js];

        // require a directory of JS files
        } else if (fileExists && isDir){
            NSArray *contents = [fileManager contentsOfDirectoryAtURL:pathUrl
                                           includingPropertiesForKeys:@[]
                                                              options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                error:nil];
            NSPredicate *predicate = [NSPredicate predicateWithFormat:@"pathExtension == 'js'"];
            JSValue *requireResp = [JSValue valueWithNewObjectInContext:weakCtx];
            for (NSURL *fileURL in [contents filteredArrayUsingPredicate:predicate]) {
                NSString *fileURLPath = [fileURL path];
                NSString *fileName = [fileURL lastPathComponent];
                NSString *requireKey = [fileName substringToIndex: fileName.length-3];
                // Enumerate each .js file in directory
                [self addConfigPath: fileURLPath];
                NSError *err;
                NSString* _js = [NSString stringWithContentsOfFile: fileURLPath
                                                          encoding: NSUTF8StringEncoding
                                                             error: &err];
                requireResp[requireKey] = [weakCtx evaluateScript:_js];
            }
            return requireResp;

        // require path does not exist (or something)
        } else {
            [self showJsException: [NSString stringWithFormat: @"Require: cannot find path %@", path]];
            JSValue *requireResp = [JSValue valueWithNewObjectInContext:weakCtx];
            return requireResp;
        }
    };
    
    ctx[@"Window"] = [PHWindow self];
    ctx[@"App"] = [PHApp self];
    ctx[@"Screen"] = [NSScreen self];
    ctx[@"MousePosition"] = [PHMousePosition self];
}

- (void) showJsException: (id) arg {
    [[PHAlerts sharedAlerts] show:[NSString stringWithFormat:@"[js exception] %@", arg] duration:3.0];
}

@end
