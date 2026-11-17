#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOUSBHost/IOUSBHost.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static volatile sig_atomic_t stopped;
static void stop(int signalNumber) { (void)signalNumber; stopped = 1; }

static int usbProperty(io_service_t service, CFStringRef property) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, property, NULL, 0);
    if (!value) return -1;
    int result = -1;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &result);
    }
    CFRelease(value);
    return result;
}

static io_service_t findGameInterface(io_service_t device) {
    io_iterator_t interfaces = 0;
    if (IORegistryEntryGetChildIterator(device, kIOServicePlane, &interfaces) != KERN_SUCCESS) return 0;
    io_service_t candidate;
    while ((candidate = IOIteratorNext(interfaces))) {
        if (IOObjectConformsTo(candidate, "IOUSBHostInterface") &&
            usbProperty(candidate, CFSTR("bInterfaceNumber")) == 0) break;
        IOObjectRelease(candidate);
    }
    IOObjectRelease(interfaces);
    return candidate;
}

static BOOL sendMessage(IOUSBHostInterface *interface, IOUSBHostPipe *pipe, const uint8_t *bytes, size_t length) {
    NSError *error = nil;
    NSMutableData *buffer = [interface ioDataWithCapacity:length error:&error];
    if (!buffer) {
        fprintf(stderr, "Mémoire USB : %s\n", error.localizedDescription.UTF8String);
        return NO;
    }
    memcpy(buffer.mutableBytes, bytes, length);
    NSUInteger sent = 0;
    if (![pipe sendIORequestWithData:buffer bytesTransferred:&sent completionTimeout:0 error:&error] || sent != length) {
        fprintf(stderr, "Écriture USB (%02x) : %s\n", bytes[0], error ? error.localizedDescription.UTF8String : "transfert incomplet");
        return NO;
    }
    return YES;
}

static uint16_t word(const uint8_t *bytes) { return bytes[0] | (uint16_t)(bytes[1] << 8); }
static double stick(const uint8_t *bytes) {
    int16_t value = (int16_t)word(bytes);
    return value < 0 ? value / 32768.0 : value / 32767.0;
}
static void applyDeadZone(double *x, double *y) {
    const double deadZone = 0.16;
    double radius = hypot(*x, *y);
    double multiplier = radius <= deadZone ? 0 : (MIN(radius, 1) - deadZone) / ((1 - deadZone) * radius);
    *x *= multiplier;
    *y *= multiplier;
}

static double trigger(const uint8_t *bytes) { return MIN(word(bytes), 1023) / 1023.0; }

static void formatNames(char *buffer, size_t capacity, unsigned flags, const char *const *names, size_t count) {
    size_t used = 0;
    buffer[0] = '\0';
    for (size_t i = 0; i < count; i++) {
        if (names[i] && (flags & (1u << i))) {
            int written = snprintf(buffer + used, capacity - used, "%s\"%s\"", used ? "," : "", names[i]);
            if (written < 0 || (size_t)written >= capacity - used) break;
            used += (size_t)written;
        }
    }
}

static BOOL sendInput(int descriptor, const uint8_t state[18], BOOL guide) {
    static const char *const buttons[] = {
        NULL, NULL, "Start", "Back", "South", "East", "West", "North",
        NULL, NULL, NULL, NULL, "LeftShoulder", "RightShoulder", "LeftStickClick", "RightStickClick", "Guide"
    };
    static const char *const directions[] = {"DpadUp", "DpadDown", "DpadLeft", "DpadRight"};
    char buttonList[160], directionList[64], frame[PIPE_BUF];
    formatNames(buttonList, sizeof buttonList, word(state + 4) | (guide ? 1u << 16 : 0), buttons, sizeof buttons / sizeof buttons[0]);
    formatNames(directionList, sizeof directionList, state[5], directions, sizeof directions / sizeof directions[0]);
    double leftX = stick(state + 10), leftY = -stick(state + 12);
    double rightX = stick(state + 14), rightY = -stick(state + 16);
    applyDeadZone(&leftX, &leftY);
    applyDeadZone(&rightX, &rightY);
    int length = snprintf(frame, sizeof frame,
                          "{\"buttons\":[%s],\"dpad\":[%s],\"axes\":{\"LeftStickX\":%.5f,\"LeftStickY\":%.5f,\"RightStickX\":%.5f,\"RightStickY\":%.5f,\"LeftTrigger\":%.5f,\"RightTrigger\":%.5f}}\n",
                          buttonList, directionList, leftX, leftY, rightX, rightY,
                          trigger(state + 6), trigger(state + 8));
    if (length < 0 || (size_t)length >= sizeof frame) return NO;
    // Keep each frame atomic so a full pipe can drop it without sending partial JSON.
    ssize_t written = write(descriptor, frame, (size_t)length);
    return written == length || (written < 0 && (errno == EAGAIN || errno == EINTR));
}

static NSString *const appProfile = @"game-controller-compatible";
static NSString *const sdlProfile = @"sdl-compatible";

static NSString *profileForApp(NSString *identifier, NSString *bundlePath, NSString *executablePath) {
    NSString *name = identifier.lowercaseString;
    if ([name isEqualToString:@"com.apple.terminal"] || [name isEqualToString:@"com.apple.finder"] ||
        [name isEqualToString:@"com.apple.dock"] || [name isEqualToString:@"com.apple.systempreferences"] ||
        [name isEqualToString:@"com.openjoystickdriver"] || [name isEqualToString:@"io.github.xboxusbbridge.app"] ||
        [name isEqualToString:@"io.github.controller4macos.app"]) return nil;
    if ([name containsString:@"nx2apple"] || [bundlePath.lastPathComponent isEqualToString:@"NX2Apple.app"] ||
        [name isEqualToString:@"com.apple.safari"] || [name isEqualToString:@"com.google.chrome"] ||
        [name isEqualToString:@"com.microsoft.edgemac"]) return appProfile;
    if ([name isEqualToString:@"com.valvesoftware.steam"] || [name hasPrefix:@"com.valvesoftware.steam."] ||
        [executablePath.lowercaseString containsString:@"/steamapps/common/"]) return sdlProfile;
    for (NSString *folder in @[@"Contents/Frameworks", @"Contents/MacOS"]) {
        if (!bundlePath.length) break;
        NSString *path = [bundlePath stringByAppendingPathComponent:folder];
        for (NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:NULL]) {
            NSString *filename = file.lowercaseString;
            if ([filename isEqualToString:@"sdl2.framework"] || [filename isEqualToString:@"sdl3.framework"] ||
                (([filename hasPrefix:@"libsdl2"] || [filename hasPrefix:@"libsdl3"]) &&
                 [filename hasSuffix:@".dylib"])) return sdlProfile;
        }
    }
    return appProfile;
}

@interface ApplicationProfile : NSObject
@property(nonatomic, copy) NSString *fixed;
- (NSString *)profileAt:(NSTimeInterval)now;
@end

@implementation ApplicationProfile {
    NSString *_profile;
    NSString *_candidate;
    pid_t _applicationPID;
    NSTimeInterval _candidateSince;
    NSTimeInterval _lastCheck;
}

- (NSString *)profileAt:(NSTimeInterval)now {
    if (self.fixed) return self.fixed;
    if (now - _lastCheck >= 0.2) {
        _lastCheck = now;
        @autoreleasepool {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, YES);
            NSRunningApplication *app = NSWorkspace.sharedWorkspace.frontmostApplication;
            if (app && _applicationPID != app.processIdentifier) {
                _applicationPID = app.processIdentifier;
                NSString *desired = profileForApp(app.bundleIdentifier, app.bundleURL.path, app.executableURL.path);
                if (desired && ![desired isEqualToString:_candidate]) {
                    _candidate = desired;
                    _candidateSince = now;
                } else if (!desired) {
                    _candidate = _profile;
                }
            }
        }
    }
    if (_candidate && (!_profile || now - _candidateSince >= 0.45)) _profile = _candidate;
    return _profile ?: appProfile;
}
@end

static NSString *profileName(NSString *profile) {
    if ([profile isEqualToString:sdlProfile]) return @"Steam / SDL";
    return @"macOS / Safari";
}

@interface XboxVirtualFeed : NSObject
@property(nonatomic, copy) NSString *toolPath;
@property(nonatomic, strong) ApplicationProfile *selection;
- (BOOL)selectProfile:(NSString *)profile;
- (BOOL)publish:(const uint8_t *)state guide:(BOOL)guide;
- (BOOL)stop;
@end

@implementation XboxVirtualFeed {
    NSTask *_task;
    NSFileHandle *_writer;
    NSString *_profile;
    NSTimeInterval _startedAt;
    NSTimeInterval _retryAt;
    unsigned _retries;
}

- (BOOL)stop {
    if (_writer) {
        [_writer closeFile];
        _writer = nil;
    }
    if (_task.running) {
        for (int attempt = 0; attempt < 15 && _task.running; attempt++) [NSThread sleepForTimeInterval:0.02];
        if (_task.running) [_task terminate];
        for (int attempt = 0; attempt < 25 && _task.running; attempt++) [NSThread sleepForTimeInterval:0.02];
        if (_task.running) return NO;
    }
    _task = nil;
    return YES;
}

- (BOOL)selectProfile:(NSString *)profile {
    if (_task.running && [profile isEqualToString:_profile]) return YES;
    if (![self stop]) {
        fputs("Le profil précédent est encore actif. Arrête puis relance le programme.\n", stderr);
        return NO;
    }
    NSPipe *pipe = [NSPipe pipe];
    int writer = dup(pipe.fileHandleForWriting.fileDescriptor);
    if (writer < 0) { perror("Canal OpenJoystickDriver"); return NO; }
    // Seul le programme parent doit retenir ce descripteur pour que la fermeture produise EOF.
    if (fcntl(writer, F_SETFD, FD_CLOEXEC) < 0 || fcntl(writer, F_SETFL, O_NONBLOCK) < 0) {
        close(writer);
        perror("Canal OpenJoystickDriver");
        return NO;
    }
    _writer = [[NSFileHandle alloc] initWithFileDescriptor:writer closeOnDealloc:YES];
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:self.toolPath];
    task.arguments = @[@"virtual", @"feed", @"--as", profile, @"--timeout", @"5"];
    task.standardInput = pipe;
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        fprintf(stderr, "Démarrage d’OpenJoystickDriver : %s\n", error.localizedDescription.UTF8String);
        [self stop];
        return NO;
    }
    [pipe.fileHandleForWriting closeFile];
    _task = task;
    _profile = profile;
    _startedAt = NSProcessInfo.processInfo.systemUptime;
    fprintf(stderr, "Profil de la manette virtuelle : %s.\n", profileName(profile).UTF8String);
    return YES;
}

- (BOOL)retryFeedAt:(NSTimeInterval)now {
    if (![self stop]) return NO;
    if (_retries == 3) {
        fputs("OpenJoystickDriver reste indisponible après trois tentatives de reconnexion.\n", stderr);
        return NO;
    }
    _retryAt = now + 0.5 * (1u << _retries);
    _retries++;
    fputs("Connexion au pilote interrompue. Reconnexion de la manette virtuelle…\n", stderr);
    return YES;
}

- (BOOL)publish:(const uint8_t *)state guide:(BOOL)guide {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    NSString *desired = [self.selection profileAt:now];
    if (_task && now - _startedAt >= 10) _retries = 0;
    if (_task && !_task.running) return [self retryFeedAt:now];
    if (now < _retryAt) return YES;
    if (!_task || ![desired isEqualToString:_profile]) {
        if (![self selectProfile:desired]) return NO;
    }
    if (_task.running && sendInput(_writer.fileDescriptor, state, guide)) return YES;
    return [self retryFeedAt:now];
}
@end

static NSData *driverCommand(NSString *tool, NSArray<NSString *> *arguments, BOOL quiet) {
    NSTask *task = [[NSTask alloc] init];
    NSPipe *output = [NSPipe pipe];
    task.executableURL = [NSURL fileURLWithPath:tool];
    BOOL readsController = [arguments.firstObject isEqualToString:@"controller"] &&
        ([arguments[1] isEqualToString:@"list"] || [arguments[1] isEqualToString:@"show"]);
    task.arguments = [arguments arrayByAddingObjectsFromArray:@[@"--timeout", readsController ? @"3" : @"10"]];
    task.standardInput = NSFileHandle.fileHandleWithNullDevice;
    task.standardOutput = output;
    if (quiet) task.standardError = NSFileHandle.fileHandleWithNullDevice;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        fprintf(stderr, "Démarrage d’OpenJoystickDriver : %s\n", error.localizedDescription.UTF8String);
        return nil;
    }
    [output.fileHandleForWriting closeFile];
    NSData *data = [output.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    return task.terminationStatus == 0 ? data : nil;
}

static NSDictionary *driverJSON(NSString *tool, NSArray<NSString *> *arguments, BOOL quiet) {
    NSData *data = driverCommand(tool, [arguments arrayByAddingObject:@"--json"], quiet);
    id result = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    return [result isKindOfClass:NSDictionary.class] ? result : nil;
}

static NSString *driverProfile(NSString *profile) {
    if ([profile isEqualToString:@"SDLCompatible"]) return sdlProfile;
    if ([profile isEqualToString:@"GameControllerCompatible"]) return appProfile;
    if ([profile isEqualToString:@"Generic"]) return @"generic";
    return nil;
}

static BOOL setDriverProfile(NSString *tool, NSString *target, NSString *profile, BOOL byUnit, BOOL quiet) {
    NSArray *arguments = profile ? @[@"virtual", @"set", profile, target] : @[@"virtual", @"reset", target];
    if (byUnit) arguments = [arguments arrayByAddingObject:@"--unit"];
    return driverCommand(tool, arguments, quiet) != nil;
}

static int runSCUF(NSString *tool, ApplicationProfile *selection) {
    NSString *const model = @"1B1C:3A03";
    NSMutableDictionary<NSString *, id> *priorProfiles = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *changedUnits = [NSMutableSet set];
    NSString *unit = nil;
    NSString *applied = nil;
    NSString *readyProfile = nil;
    NSTimeInterval nextPoll = 0;
    NSTimeInterval retryAt = 0;
    BOOL waiting = NO;
    fputs("Appuie sur A ou bouge un stick pour réveiller la SCUF.\n", stderr);
    while (!stopped) {
        @autoreleasepool {
            NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
            NSString *desired = [selection profileAt:now];
            if (now >= nextPoll) {
                nextPoll = now + 1.5;
                NSDictionary *report = driverJSON(tool, @[@"controller", @"show", model], YES);
                NSString *attachedUnit = report[@"unit"];
                if (attachedUnit.length) {
                    if (waiting) fputs("SCUF détectée par OpenJoystickDriver.\n", stderr);
                    unit = attachedUnit;
                    waiting = NO;
                    NSDictionary *configuration = report[@"virtual"];
                    applied = driverProfile(configuration[@"profile"]);
                    if (!priorProfiles[unit]) {
                        BOOL overridden = [configuration[@"source"] isEqualToString:@"override"];
                        priorProfiles[unit] = (overridden ? applied : nil) ?: NSNull.null;
                    }
                    NSDictionary *publication = report[@"publication"];
                    NSString *published = driverProfile(publication[@"target"]);
                    if ([publication[@"state"] isEqualToString:@"Published"] && [published isEqualToString:desired] &&
                        ![published isEqualToString:readyProfile]) {
                        fprintf(stderr, "Manette virtuelle prête : %s.\n", profileName(published).UTF8String);
                        readyProfile = published;
                    }
                } else {
                    if (!waiting) fputs("SCUF en attente dans le pilote. Rebranche-la si nécessaire.\n", stderr);
                    unit = nil;
                    applied = nil;
                    readyProfile = nil;
                    waiting = YES;
                }
            }
            if (!stopped && unit && ![desired isEqualToString:applied] && now >= retryAt) {
                if (setDriverProfile(tool, unit, desired, YES, NO)) {
                    [changedUnits addObject:unit];
                    applied = desired;
                    readyProfile = nil;
                    nextPoll = 0;
                } else {
                    retryAt = now + 2;
                }
            }
            [NSThread sleepForTimeInterval:0.15];
        }
    }
    for (NSString *key in changedUnits) {
        id prior = priorProfiles[key];
        NSString *profile = prior == NSNull.null ? nil : prior;
        if (!setDriverProfile(tool, key, profile, YES, YES))
            fputs("Le profil SCUF est conservé par OpenJoystickDriver. Tu peux remettre son choix sur Automatique dans le pilote.\n", stderr);
    }
    return 130;
}

static BOOL importJoyConPairProfile(NSString *tool, NSString *identifier) {
    NSDictionary *profile = @{
        @"apiVersion": @"openjoystickdriver/v1alpha2", @"kind": @"Profile",
        @"id": identifier, @"name": @"Pont manettes USB – Joy-Con 2",
        @"device": @{@"vendorID": @0x057e, @"productID": @0x2067},
        @"applicationScope": @{@"type": @"Global"},
        @"outputPolicy": @{@"virtualGamepad": @"Passthrough", @"physicalInput": @"Exclusive"},
        @"bindings": @[], @"joyConPair": @{@"gyroSelection": @"Disabled"}
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:profile options:0 error:NULL];
    // Use the launcher's private temporary directory so cleanup also covers an interrupted import.
    NSString *path = [tool.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"joycon-pair.json"];
    if (![json writeToFile:path atomically:YES]) return NO;
    NSData *result = driverCommand(tool, @[@"profile", @"import", path], NO);
    [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
    return result != nil;
}

static int runJoyCons(NSString *tool, ApplicationProfile *selection) {
    NSArray<NSString *> *models = @[@"057E:2067", @"057E:2066"];
    const char *sides[] = {"gauche", "droit"};
    NSString *sessionIDs[2] = {nil, nil};
    NSString *readyProfiles[2] = {nil, nil};
    NSString *priorProfiles[2] = {nil, nil};
    BOOL changedProfiles[2] = {NO, NO};
    NSTimeInterval nextProfileAttempt[2] = {0, 0};
    NSString *pairProfile = nil;
    BOOL profileImported = NO;
    NSString *pairSession = nil;
    NSUInteger pairAttempts = 0;
    NSTimeInterval nextPairAttempt = 0;
    fputs("Détache les Joy-Con 2 de la console et maintiens le bouton SYNC de chacun jusqu’au défilement des voyants.\n", stderr);
    fputs("OpenJoystickDriver attend les Joy-Con 2 en Bluetooth.\n", stderr);
    while (!stopped) {
        @autoreleasepool {
            NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
            NSString *desired = [selection profileAt:now];
            NSDictionary *snapshot = driverJSON(tool, @[@"controller", @"list"], YES);
            if (!snapshot) {
                [NSThread sleepForTimeInterval:0.6];
                continue;
            }
            NSString *attached[2] = {nil, nil};
            NSUInteger counts[2] = {0, 0};
            for (NSDictionary *controller in snapshot[@"items"]) {
                if (![controller[@"vendorID"] isEqual:@0x057e]) continue;
                NSNumber *product = controller[@"productID"];
                if (![product isEqual:@0x2067] && ![product isEqual:@0x2066]) continue;
                NSUInteger index = [product isEqual:@0x2067] ? 0 : 1;
                counts[index]++;
                attached[index] = controller[@"id"];
            }
            if (pairSession && (counts[0] > 1 || counts[1] > 1)) {
                driverCommand(tool, @[@"controller", @"unpair", pairSession], YES);
            }
            NSDictionary *reports[2] = {nil, nil};
            for (NSUInteger i = 0; i < 2 && !stopped; i++) {
                NSString *identifier = counts[i] == 1 ? attached[i] : nil;
                if (identifier) reports[i] = driverJSON(tool, @[@"controller", @"show", identifier], YES);
                if (identifier == sessionIDs[i] || [identifier isEqualToString:sessionIDs[i]]) continue;
                if (sessionIDs[i]) fprintf(stderr, "Joy-Con 2 %s déconnecté. Maintiens SYNC pour le reconnecter.\n", sides[i]);
                sessionIDs[i] = identifier;
                readyProfiles[i] = nil;
                nextProfileAttempt[i] = 0;
                pairSession = nil;
                pairAttempts = 0;
                nextPairAttempt = 0;
                if (identifier) fprintf(stderr, "Joy-Con 2 %s connecté. Bouge son stick pour envoyer une entrée.\n", sides[i]);
            }
            for (NSUInteger i = 0; i < 2 && !stopped; i++) {
                if (!reports[i] || (i == 1 && pairSession)) continue;
                NSDictionary *configuration = reports[i][@"virtual"];
                NSString *applied = driverProfile(configuration[@"profile"]);
                if (applied && ![applied isEqualToString:desired] && now >= nextProfileAttempt[i]) {
                    if (!changedProfiles[i] && [configuration[@"source"] isEqualToString:@"override"]) priorProfiles[i] = applied;
                    if (setDriverProfile(tool, sessionIDs[i], desired, NO, NO)) {
                        changedProfiles[i] = YES;
                        readyProfiles[i] = nil;
                    }
                    nextProfileAttempt[i] = now + 2;
                    continue;
                }
                NSDictionary *publication = reports[i][@"publication"];
                NSString *published = driverProfile(publication[@"target"]);
                if ([publication[@"state"] isEqualToString:@"Published"] && [published isEqualToString:desired] &&
                    ![published isEqualToString:readyProfiles[i]]) {
                    fprintf(stderr, "Manette virtuelle prête (%s) : %s.\n", pairSession ? "paire Joy-Con 2" : sides[i],
                            profileName(published).UTF8String);
                    readyProfiles[i] = published;
                }
            }
            if (!stopped && sessionIDs[0] && sessionIDs[1] && !pairSession &&
                pairAttempts < 3 && now >= nextPairAttempt) {
                pairAttempts++;
                if (!pairProfile) pairProfile = NSUUID.UUID.UUIDString;
                if (!profileImported) profileImported = importJoyConPairProfile(tool, pairProfile);
                if (profileImported) {
                    NSDictionary *pair = driverJSON(tool, @[@"controller", @"pair", sessionIDs[0], sessionIDs[1],
                                                           @"--profile", pairProfile], NO);
                    pairSession = pair[@"session"];
                }
                if (pairSession) {
                    readyProfiles[0] = nil;
                    for (NSUInteger i = 0; i < 2; i++)
                        driverCommand(tool, @[@"controller", @"player", sessionIDs[i], @"1"], YES);
                    fputs("Les deux Joy-Con 2 sont réunis en une manette. Bouge un stick pour activer la paire.\n", stderr);
                } else if (pairAttempts == 3) {
                    fputs("Le regroupement a échoué. Les Joy-Con 2 restent utilisables séparément.\n", stderr);
                }
                nextPairAttempt = NSProcessInfo.processInfo.systemUptime + 3;
            }
            [NSThread sleepForTimeInterval:0.6];
        }
    }
    if (pairSession) driverCommand(tool, @[@"controller", @"unpair", pairSession], YES);
    if (pairProfile && !driverCommand(tool, @[@"profile", @"delete", pairProfile, @"--force"], YES))
        fputs("Le profil temporaire « Pont manettes USB – Joy-Con 2 » reste dans OpenJoystickDriver.\n", stderr);
    for (NSUInteger i = 0; i < 2; i++) {
        if (changedProfiles[i] && !setDriverProfile(tool, models[i], priorProfiles[i], NO, YES))
            fprintf(stderr, "OpenJoystickDriver a conservé le dernier profil du Joy-Con %s.\n", sides[i]);
    }
    return 130;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        double probeSeconds = argc == 2 ? strtod(argv[1], NULL) : 0;
        XboxVirtualFeed *feed = nil;
        signal(SIGINT, stop);
        signal(SIGTERM, stop);
        if (argc == 3 || argc == 4) {
            NSString *mode = [NSString stringWithUTF8String:argv[1]];
            if (![mode isEqualToString:@"automatic"] && ![mode isEqualToString:appProfile] && ![mode isEqualToString:sdlProfile]) {
                fputs("Mode de manette inconnu.\n", stderr);
                return 2;
            }
            ApplicationProfile *selection = [[ApplicationProfile alloc] init];
            if (![mode isEqualToString:@"automatic"]) selection.fixed = mode;
            NSString *tool = [NSString stringWithUTF8String:argv[2]];
            if (argc == 4 && strcmp(argv[3], "scuf") == 0) return runSCUF(tool, selection);
            if (argc == 4 && strcmp(argv[3], "joycon2") == 0) return runJoyCons(tool, selection);
            if (argc == 4 && strcmp(argv[3], "xbox") != 0) return 2;
            feed = [[XboxVirtualFeed alloc] init];
            feed.toolPath = tool;
            feed.selection = selection;
            signal(SIGPIPE, SIG_IGN);
        }
        NSDictionary *match = @{@"IOProviderClass": @"IOUSBHostDevice", @"idVendor": @0x045e, @"idProduct": @0x02dd};
        io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, (__bridge_retained CFDictionaryRef)match);
        if (!service) { fputs("Manette 045e:02dd introuvable.\n", stderr); return 1; }

        NSError *error = nil;
        IOUSBHostDevice *device = nil;
        if (usbProperty(service, CFSTR("kUSBCurrentConfiguration")) != 1) {
            device = [[IOUSBHostDevice alloc] initWithIOService:service options:0 queue:nil error:&error interestHandler:nil];
            if (!device || ![device configureWithValue:1 matchInterfaces:YES error:&error]) {
                fprintf(stderr, "Configuration USB : %s\n", error.localizedDescription.UTF8String);
                IOObjectRelease(service);
                return 2;
            }
        }
        io_service_t gameInterface = 0;
        for (int attempt = 0; attempt < 20 && !gameInterface; attempt++) {
            gameInterface = findGameInterface(service);
            if (!gameInterface) [NSThread sleepForTimeInterval:0.05];
        }
        IOObjectRelease(service);
        if (!gameInterface) { fputs("Interface de jeu USB introuvable.\n", stderr); return 3; }

        IOUSBHostInterface *interface = [[IOUSBHostInterface alloc] initWithIOService:gameInterface options:0 queue:nil error:&error interestHandler:nil];
        IOObjectRelease(gameInterface);
        if (!interface) {
            fprintf(stderr, "Impossible d’ouvrir la manette en USB : %s\n", error.localizedDescription.UTF8String);
            fputs("Si Steam ou Chrome est ouvert, quitte-le avec Cmd+Q, puis relance ce fichier.\n", stderr);
            return 4;
        }
        IOUSBHostPipe *input = [interface copyPipeWithAddress:0x81 error:&error];
        IOUSBHostPipe *output = [interface copyPipeWithAddress:0x01 error:&error];
        if (!input || !output) { fprintf(stderr, "Points de terminaison USB : %s\n", error.localizedDescription.UTF8String); return 5; }

        const uint8_t power[] = {0x05, 0x20, 1, 1, 0};
        const uint8_t light[] = {0x0a, 0x20, 2, 3, 0, 1, 0x14};
        const uint8_t enable[] = {0x06, 0x20, 3, 2, 1, 0};
        if (!sendMessage(interface, output, power, sizeof power) ||
            !sendMessage(interface, output, light, sizeof light) ||
            !sendMessage(interface, output, enable, sizeof enable)) return 6;
        fputs("Manette initialisée. Appuie sur A ou bouge un stick.\n", stderr);

        NSMutableData *buffer = [interface ioDataWithCapacity:64 error:&error];
        if (!buffer) return 7;
        uint8_t state[18] = {0};
        BOOL guide = NO;
        BOOL received = NO;
        int failure = 0;
        size_t reports = 0;
        size_t changes = 0;
        NSTimeInterval stopAt = probeSeconds > 0 ? NSProcessInfo.processInfo.systemUptime + probeSeconds : INFINITY;
        NSTimeInterval lastFrame = 0;
        BOOL pending = NO;
        dispatch_semaphore_t ready = dispatch_semaphore_create(0);
        __block IOReturn readStatus;
        __block NSUInteger length;
        while (!stopped && NSProcessInfo.processInfo.systemUptime < stopAt) {
            if (![input enqueueIORequestWithData:buffer completionTimeout:0 error:&error
                completionHandler:^(IOReturn status, NSUInteger transferred) {
                    readStatus = status;
                    length = transferred;
                    dispatch_semaphore_signal(ready);
                }]) {
                fprintf(stderr, "Lecture USB : %s\n", error.localizedDescription.UTF8String);
                failure = 9;
                break;
            }
            BOOL timedOut = NO;
            while (dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, (pending ? 17 : 250) * NSEC_PER_MSEC))) {
                if (stopped || NSProcessInfo.processInfo.systemUptime >= stopAt) { timedOut = YES; break; }
                if (received && probeSeconds <= 0) {
                    BOOL sent = feed ? [feed publish:state guide:guide] : sendInput(STDOUT_FILENO, state, guide);
                    if (!sent) { failure = 10; break; }
                    lastFrame = NSProcessInfo.processInfo.systemUptime;
                    pending = NO;
                }
            }
            if (timedOut || failure) break;
            if (readStatus != kIOReturnSuccess) {
                fprintf(stderr, "Lecture USB : 0x%08x\n", readStatus);
                failure = 9;
                break;
            }
            const uint8_t *bytes = buffer.bytes;
            BOOL changed = NO;
            if (length >= 18 && bytes[0] == 0x20) {
                changed = !received || memcmp(state + 4, bytes + 4, 14) != 0;
                memcpy(state, bytes, sizeof state);
                reports++;
                received = YES;
            }
            if (length >= 5 && bytes[0] == 0x07) {
                if (bytes[1] == 0x30) {
                    const uint8_t ack[] = {0x01, 0x20, bytes[2], 9, 0, 7, 0x20, 2, 0, 0, 0, 0, 0};
                    sendMessage(interface, output, ack, sizeof ack);
                }
                BOOL pressed = (bytes[4] & 3) != 0;
                changed = pressed != guide;
                guide = pressed;
            }
            NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
            if (changed) changes++;
            if (probeSeconds > 0 && changed) sendInput(STDOUT_FILENO, state, guide);
            pending |= changed && probeSeconds <= 0;
            if (probeSeconds <= 0 && received && ((pending && now - lastFrame >= 0.017) || now - lastFrame >= 0.25)) {
                BOOL sent = feed ? [feed publish:state guide:guide] : sendInput(STDOUT_FILENO, state, guide);
                if (!sent) { failure = 10; break; }
                lastFrame = now;
                pending = NO;
            }
        }
        [feed stop];
        [interface destroy];
        [device destroy];
        if (probeSeconds > 0) fprintf(stderr, "Rapports d’entrée USB : %zu, changements : %zu\n", reports, changes);
        if (stopped) return 130;
        if (failure) return failure;
        return received ? 0 : 8;
    }
}
