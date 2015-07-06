#import <Chuzzle.h>
#import "main.h"

#define MMABashProfileContainsSourceLine [contents.split(@"\n").chuzzle containsObject:self.bashProfileLine]
#define MMABundlePathPlus(x) [self.bundle.bundlePath stringByAppendingPathComponent:x]

Promise *mdfind(NSString *app) {
    return [NSTask:@[@"/usr/bin/mdfind", app, @"kind:app"]].promise.then(^(NSString *stdout){
        id apps = stdout.split(@"\n").chuzzle;
        if (!apps)
            @throw [NSString stringWithFormat:@"%@ not found", app];
        return PMKManifold([apps firstObject], apps);
    });
}

static Promise *MMSyncPrefs(id domain) {
    id fmt = @"from Foundation import CFPreferencesAppSynchronize\nCFPreferencesAppSynchronize('%@')";
    id py = [NSString stringWithFormat:fmt, domain];
    return [NSTask:@[@"/usr/bin/python", @"-c", py]].promise;
}

static Promise *MMWritePrefs(NSArray *args) {
    NSMutableArray *ma = [NSMutableArray arrayWithObjects:@"write", nil];
    [ma addObjectsFromArray:args];

    NSTask *task = [NSTask new];
    task.launchPath = @"/usr/bin/defaults";
    task.arguments = ma;
    return task.promise;
}

#define MMWritePrefs(...) MMWritePrefs(@[__VA_ARGS__])



@implementation MMAPreferencePane {
    IBOutlet MMALED *mavericks;
    IBOutlet MMALED *xcode;
    IBOutlet MMALED *git;
    IBOutlet MMALED *textmate;
    IBOutlet MMASwitchView *bigSwitch;
    IBOutlet NSButton *refresh;
    IBOutlet NSProgressIndicator *spinner;

    Promise *switcher;
    Promise *checker;
    
    NSNumber* xcodeBaseBundleId;
    NSNumber* currentxCodeVersion;
}

- (NSString *)bashProfileLine {
    id profile = [self.bundle.bundlePath stringByAppendingPathComponent:@"Contents/etc/profile"];
    profile = [profile stringByReplacingOccurrencesOfString:@"~".stringByExpandingTildeInPath withString:@"~"];
    return [NSString stringWithFormat:@"source %@", profile];
}


- (void)mainViewDidLoad {
    bigSwitch.state  = NSOffState;
    bigSwitch.target = self;
    bigSwitch.action = @selector(onSwitchToggled);

    refresh.target = self;
    refresh.action = @selector(check);

    [self loadRemoteConfig];
    
    [spinner startAnimation:self];
    [self check];
    checker.finally(^{
        [spinner stopAnimation:self];
    });

    NSString *path = @"~/.bash_profile".stringByExpandingTildeInPath;
    NSString *contents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
    bigSwitch.state = MMABashProfileContainsSourceLine ? NSOnState : NSOffState;
}


-(void)loadRemoteConfig
{
    NSURLResponse* response;
    NSError* error;
    NSData* data = [NSURLConnection sendSynchronousRequest:[NSURLRequest
                                                            requestWithURL:[NSURL URLWithString:@"https://s3-us-west-2.amazonaws.com/mmprefpane/mmpref_pane.json"]]
                                         returningResponse:&response error:&error];
    
    if (error != nil) {
        id info = @{NSLocalizedDescriptionKey: @"Could not locate remote resource for tool versions."};
        @throw [NSError errorWithDomain:MMAErrorDomain code:MMADiagnosticFailedRed userInfo:info];
    }
    else{
        NSDictionary* jsonData = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:nil];
        xcodeBaseBundleId = jsonData[@"xcode base bundle id"];
        currentxCodeVersion = jsonData[@"current Xcode version"];
    }
}

- (void)awakeFromNib {
    bigSwitch.target = self;
    bigSwitch.action = @selector(onSwitchToggled);
}

- (IBAction)check {
    if (checker)
        return;

    [@[mavericks, xcode, git, textmate] makeObjectsPerformSelector:@selector(reset)];

    id p1, p2, p3, p6;

    [mavericks check:p1 = MMACheckMavericks()];
    [xcode check:p2 = MMACheckXcode(xcodeBaseBundleId, currentxCodeVersion)];
    [git check:p3 = MMACheckGit()];
    [textmate check:p6 = MMACheckTextMate()];

    checker = [Promise when:@[p1, p2, p3, p6]].finally(^{
        checker = nil;
    });
}

- (void)activate {
    if (switcher)
        return;

    dispatch_queue_t const bgq = dispatch_get_global_queue(0, 0);

    id terminalPromises = dispatch_promise(^{
        id args = @[@"/usr/bin/defaults", @"read", @"com.apple.Terminal", @"Default Window Settings"];
        [NSTask:args].promise.then(^(id stdout){
            if ([NSStringChomp(stdout) isEqual:@"MobileMakers"])
                return [Promise promiseWithValue:@YES];
            id promises = @[
                [NSTask:@[@"/usr/bin/open", @"-g", MMABundlePathPlus(@"Contents/Resources/MobileMakers.terminal")]].promise,
                MMWritePrefs(@"com.apple.Terminal", @"Default Window Settings", @"MobileMakers"),
                MMWritePrefs(@"com.apple.Terminal", @"Startup Window Settings", @"MobileMakers")
            ];
            return [Promise when:promises];
        });
    });
    
    id xcodePromises = @[
        dispatch_promise(^id{
            id err = nil;
            id mgr = [NSFileManager defaultManager];
            id dst = @"~/Library/Developer/Xcode/UserData/FontAndColorThemes".stringByExpandingTildeInPath;
            id src = [self.bundle.bundlePath stringByAppendingString:@"/Contents/Resources/MobileMakers.dvtcolortheme"];
            [mgr createDirectoryAtPath:dst withIntermediateDirectories:YES attributes:nil error:nil];
            [mgr copyItemAtPath:src toPath:[dst stringByAppendingString:@"/MobileMakers.dvtcolortheme"] error:&err];
            //if ([err code] == 516 || !err)
            //    return MMWritePrefs(@"com.apple.dt.Xcode", @"DVTFontAndColorCurrentTheme", @"MobileMakers.dvtcolortheme");
            return nil;
        }),
        MMWritePrefs(@"com.apple.dt.Xcode", @"DVTTextEditorTrimWhitespaceOnlyLines", @"-bool", @"YES"),
        MMWritePrefs(@"com.apple.dt.Xcode", @"DVTTextShowLineNumbers", @"-bool", @"YES"),
        MMWritePrefs(@"com.apple.dt.Xcode", @"DVTTextEditorTrimTrailingWhitespace", @"-bool", @"YES"),
    ];

    // Not currently used --dbora
//    id gitxPromise = MMACheckGitX().catch(^{
//        return [NSURLConnection download:@"http://builds.phere.net/GitX/development/GitX-dev.dmg"].then(^(NSString *tmpPath){
//            return [NSTask:@[@"/usr/bin/hdiutil", @"mount", tmpPath]].promise;
//        }).thenOn(bgq, ^(NSString *stdout){
//            NSString *ln = stdout.split(@"\n").chuzzle.lastObject;
//            NSUInteger const start = [ln rangeOfString:@"/Volumes"].location;
//            if (start == NSNotFound) {
//                NSLog(@"%@", stdout);
//                @throw @"Could not mount GitX. Try installing it yourself manually.";
//            }
//            NSString *mountPath = [[ln substringFromIndex:start] stringByAppendingPathComponent:@"GitX.app"];
//
//            NSString *toPath = [MMAApplicationsDirectory() stringByAppendingPathComponent:@"GitX.app"];
//
//            id err = nil;
//            [[NSFileManager defaultManager] copyItemAtPath:mountPath toPath:toPath error:&err];
//
//            NSTask *task = [NSTask:@[@"/usr/bin/hdiutil", @"unmount", mountPath]];
//            [task launch];
//            [task waitUntilExit];
//
//            if (err) @throw err;
//        });
//    });

    id textMatePromise = MMACheckTextMate().catch(^{
        return [NSURLConnection download:@"https://api.textmate.org/downloads/release"].thenOn(bgq, ^(NSString *tmpPath){
            id dst = @"~/Applications".stringByExpandingTildeInPath;
            [[NSFileManager defaultManager] createDirectoryAtPath:dst withIntermediateDirectories:NO attributes:nil error:nil];
            return [NSTask:@[@"/usr/bin/tar", @"xjf", tmpPath, @"-C", dst]].promise;
        });
    });

    // doing these sequentially or git freaks out
    id gitPromise = [NSTask:@"/usr/bin/git config --global color.ui auto"].promise.then(^{
        return [NSTask:@"/usr/bin/git config --global push.default simple"].promise;
    }).then(^{
        return [NSTask:@"/usr/bin/git config --global credential.helper cache"].promise;
    }).then(^{
        id args = @[@"/usr/bin/git", @"config", @"--global", @"core.excludesfile", MMABundlePathPlus(@"Contents/etc/gitignore")];
        return [NSTask:args].promise;
    });

    id promises = @[
        textMatePromise,
        gitPromise,
        [Promise when:terminalPromises].then(^{
            return MMSyncPrefs(@"com.apple.Terminal");
        }),
        [Promise when:xcodePromises].then(^{
            return MMSyncPrefs(@"com.apple.dt.Xcode");
        })
    ];

    NSString *bashProfilePath = @"~/.bash_profile".stringByExpandingTildeInPath;

    [spinner startAnimation:self];
    bigSwitch.enabled = NO;

    switcher = [Promise when:promises].then(^{
        [self check];
        return checker;
    }).then(^{
        return [NSString pmk_stringWithContentsOfFile:bashProfilePath].catch(^(NSError *err){
            if (err.domain == NSCocoaErrorDomain && err.code == 260)
                return @"";  // no such file
            @throw err;
        });
    }).then(^(NSString *contents) {
        if (!MMABashProfileContainsSourceLine) {
            contents = [contents stringByAppendingFormat:@"\n\n%@\n", self.bashProfileLine];
            [contents writeToFile:bashProfilePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }).catch(^(NSError *error){
        [spinner stopAnimation:self];
        [[NSAlert alertWithError:error] runModal];
        [bigSwitch setState:NSOffState animate:YES];
    }).finally(^{
        bigSwitch.enabled = YES;
        [spinner stopAnimation:self];
        switcher = nil;
    });
}

- (void)deactivate {
    if (switcher)
        return;

    NSString *path = @"~/.bash_profile".stringByExpandingTildeInPath;
    switcher = [NSString pmk_stringWithContentsOfFile:path].then(^(NSString *bashProfile){
        NSMutableArray *lines = [NSMutableArray arrayWithArray:bashProfile.split(@"\n").chuzzle];
        [lines removeObject:self.bashProfileLine];
        [lines.join(@"\n") writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }).finally(^{
        switcher = nil;
    });
}

- (IBAction)onSwitchToggled {
    if (switcher)
        return;

    if (bigSwitch.state == NSOnState) {
        [self activate];
    } else
        [self deactivate];
}

@end


@implementation NSString (MM)

+ (Promise *)pmk_stringWithContentsOfFile:(NSString *)path {
    return dispatch_promise(^{
        id err;
        id str = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&err];
        if (err)
            @throw err;
        else
            return str ?: @"";
    });
}

@end



@implementation NSURLConnection (MMA)

+ (Promise *)download:(NSString *)url {
    id path = [[NSURL URLWithString:url] pathComponents].lastObject;
    path = [@"/tmp" stringByAppendingPathComponent:path];

    if ([[NSFileManager defaultManager] fileExistsAtPath:path])
        return [Promise promiseWithValue:path];

    return [NSURLConnection GET:url].then(^(NSData *data){
        [data writeToFile:path atomically:YES];
        return path;
    });
}

@end


NSString *MMAApplicationsDirectory() {
    id s = @"~/Applications".stringByExpandingTildeInPath;
    BOOL isdir;
    if ([[NSFileManager defaultManager] fileExistsAtPath:s isDirectory:&isdir] && isdir)
        return s;

    // if user is not admin this will fail and prompt them to install it themselves
    return @"/Applications";
}
