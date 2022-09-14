//
// Copyright © 2021 osy. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/debugserver.h>
#include <libimobiledevice/heartbeat.h>
#include <libimobiledevice/installation_proxy.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/mobile_image_mounter.h>
#include <libimobiledevice/notification_proxy.h>
#include <libimobiledevice/sbservices.h>
#include <libimobiledevice/service.h>
#include <libimobiledevice/afc.h>
#include <libimobiledevice-glue/utils.h>
#include "common/userpref.h"
#import "JBApp.h"
#import "JBHostDevice.h"
#import "Jitterbug.h"
#import "Jitterbug-Swift.h"
#import "CacheStorage.h"
#include <dirent.h>
#define wait_ms(x) { struct timespec ts; ts.tv_sec = 0; ts.tv_nsec = x * 1000000; nanosleep(&ts, NULL); }
#ifdef HAVE_CONFIG_H
#include <config.h>
#endif
#include <stdlib.h>
#define _GNU_SOURCE 1
#define __USE_GNU 1
#include <stdio.h>
#include <string.h>
#include <getopt.h>
#include <errno.h>
#include <time.h>
#include <libgen.h>
#include <inttypes.h>
#include <limits.h>
#include <sys/stat.h>
#include <dirent.h>
#ifdef HAVE_UNISTD_H
#include <unistd.h>
#endif
#ifndef WIN32
#include <signal.h>
#endif

#include <plist/plist.h>

#include <zip.h>


#define TOOL_NAME "jitterbug"
NSString *const kJBErrorDomain = @"com.osy86.Jitterbug";
const NSInteger kJBHostImageNotMounted = -666;
static const char PKG_PATH[] = "PublicStaging";
static const char PATH_PREFIX[] = "/private/var/mobile/Media";
@interface JBHostDevice ()

@property (nonatomic, readwrite) BOOL isUsbDevice;
@property (nonatomic, readwrite) NSString *hostname;
@property (nonatomic, readwrite) NSData *address;
@property (nonatomic, nullable, readwrite) NSString *udid;
@property (nonatomic) idevice_t device;
@property (nonatomic) lockdownd_client_t lockdown;
@property (nonatomic, nonnull) dispatch_queue_t timerQueue;
@property (nonatomic, nonnull) dispatch_semaphore_t timerCancelEvent;
@property (nonatomic, nullable) dispatch_source_t heartbeat;

@end

@implementation JBHostDevice

#pragma mark - Properties and initializers

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (void)setName:(NSString * _Nonnull)name {
    if (_name != name) {
        [self propertyWillChange];
        _name = name;
    }
}

- (void)setHostDeviceType:(JBHostDeviceType)hostDeviceType {
    if (_hostDeviceType != hostDeviceType) {
        [self propertyWillChange];
        _hostDeviceType = hostDeviceType;
    }
}

- (void)setDiscovered:(BOOL)discovered {
    if (_discovered != discovered) {
        [self propertyWillChange];
        _discovered = discovered;
    }
}

- (void)setLockdown:(lockdownd_client_t)lockdown {
    if (_lockdown != lockdown) {
        [self propertyWillChange];
        _lockdown = lockdown;
    }
}

- (NSString *)identifier {
    if (self.isUsbDevice) {
        return self.udid;
    } else {
        return self.hostname;
    }
}

- (BOOL)isConnected {
    return self.lockdown != nil;
}

- (void)setupDispatchQueue {
    self.timerQueue = dispatch_queue_create("heartbeatQueue", DISPATCH_QUEUE_SERIAL);
    self.timerCancelEvent = dispatch_semaphore_create(0);
}

- (instancetype)initWithHostname:(NSString *)hostname address:(NSData *)address {
    if (self = [super init]) {
        self.isUsbDevice = NO;
        self.hostname = hostname;
        self.udid = @"";
        self.address = address;
        self.name = hostname;
        self.hostDeviceType = JBHostDeviceTypeUnknown;
        [self setupDispatchQueue];
    }
    return self;
}

- (instancetype)initWithUdid:(NSString *)udid address:(NSData *)address {
    if (self = [super init]) {
        self.isUsbDevice = YES;
        self.hostname = @"";
        self.udid = udid;
        self.address = address ? address : [NSData data];
        self.name = udid;
        self.hostDeviceType = JBHostDeviceTypeUnknown;
        [self setupDispatchQueue];
    }
    return self;
}

- (void)dealloc {
    [self stopLockdown];
}

#pragma mark - NSCoding

- (nullable instancetype)initWithCoder:(nonnull NSCoder *)coder {
    if (self = [self init]) {
        self.isUsbDevice = [coder decodeBoolForKey:@"isUsbDevice"];
        self.name = [coder decodeObjectForKey:@"name"];
        if (!self.name) {
            return nil;
        }
        self.hostname = [coder decodeObjectForKey:@"hostname"];
        if (!self.hostname) {
            return nil;
        }
        self.udid = [coder decodeObjectForKey:@"udid"];
        if (!self.udid) {
            return nil;
        }
        self.address = [coder decodeObjectForKey:@"address"];
        if (!self.address) {
            return nil;
        }
        self.hostDeviceType = [coder decodeIntegerForKey:@"hostDeviceType"];
        if (!self.hostDeviceType) {
            return nil;
        }
        [self setupDispatchQueue];
    }
    return self;
}

- (void)encodeWithCoder:(nonnull NSCoder *)coder {
    [coder encodeBool:self.isUsbDevice forKey:@"isUsbDevice"];
    [coder encodeObject:self.name forKey:@"name"];
    [coder encodeObject:self.hostname forKey:@"hostname"];
    [coder encodeObject:self.udid forKey:@"udid"];
    [coder encodeObject:self.address forKey:@"address"];
    [coder encodeInteger:self.hostDeviceType forKey:@"hostDeviceType"];
}

#pragma mark - Methods

static service_error_t service_client_factory_start_service_with_lockdown(lockdownd_client_t lckd, idevice_t device, const char* service_name, void **client, const char* label, int32_t (*constructor_func)(idevice_t, lockdownd_service_descriptor_t, void**), int32_t *error_code)
{
    *client = NULL;

    lockdownd_service_descriptor_t service = NULL;
    lockdownd_start_service(lckd, service_name, &service);

    if (!service || service->port == 0) {
        DEBUG_PRINT("Could not start service %s!", service_name);
        return SERVICE_E_START_SERVICE_ERROR;
    }

    int32_t ec;
    if (constructor_func) {
        ec = (int32_t)constructor_func(device, service, client);
    } else {
        ec = service_client_new(device, service, (service_client_t*)client);
    }
    if (error_code) {
        *error_code = ec;
    }

    if (ec != SERVICE_E_SUCCESS) {
        DEBUG_PRINT("Could not connect to service %s! Port: %i, error: %i", service_name, service->port, ec);
    }

    lockdownd_service_descriptor_free(service);
    service = NULL;

    return (ec == SERVICE_E_SUCCESS) ? SERVICE_E_SUCCESS : SERVICE_E_START_SERVICE_ERROR;
}

- (void)createError:(NSError **)error withString:(NSString *)string code:(NSInteger)code {
    if (error) {
        *error = [NSError errorWithDomain:kJBErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: string}];
    }
}

- (void)createError:(NSError **)error withString:(NSString *)string {
    [self createError:error withString:string code:-1];
}

- (void)stopLockdown {
    [self stopHeartbeat];
    if (self.lockdown) {
        lockdownd_client_free(self.lockdown);
        self.lockdown = NULL;
    }
    if (self.device) {
        idevice_free(self.device);
        self.device = NULL;
    }
    if (self.udid.length > 0) {
        cachePairingRemove(self.udid.UTF8String);
    }
}

- (BOOL)startLockdownWithPairingUrl:(NSURL *)url error:(NSError **)error {
    idevice_error_t derr = IDEVICE_E_SUCCESS;
    lockdownd_error_t lerr = LOCKDOWN_E_SUCCESS;
    
    assert(!self.isUsbDevice);
    [self stopLockdown];
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:error];
    if (!data) {
        return NO;
    }
    NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:error];
    if (!plist) {
        return NO;
    }
    NSString *udid = plist[@"UDID"];
    if (!udid) {
        [self createError:error withString:NSLocalizedString(@"Pairing data missing key 'UDID'", @"JBHostDevice")];
    }
    if (!cachePairingUpdateData(udid.UTF8String, (__bridge CFDataRef)(data))) {
        if (!cachePairingAdd(udid.UTF8String, (__bridge CFDataRef)(self.address), (__bridge CFDataRef)(data))) {
            [self createError:error withString:NSLocalizedString(@"Failed cache pairing data.", @"JBHostDevice")];
            return NO;
        }
    }
    
    if ((derr = idevice_new_with_options(&_device, udid.UTF8String, IDEVICE_LOOKUP_NETWORK)) != IDEVICE_E_SUCCESS) {
        [self createError:error withString:NSLocalizedString(@"Failed to create device.", @"JBHostDevice") code:derr];
        goto error;
    }
    
    if ((lerr = lockdownd_client_new_with_handshake(self.device, &_lockdown, TOOL_NAME)) != LOCKDOWN_E_SUCCESS) {
        [self createError:error withString:NSLocalizedString(@"Failed to communicate with device. Make sure the device is connected and unlocked and that the pairing is valid.", @"JBHostDevice") code:lerr];
        goto error;
    }
    
    /**
     * We need a unique heartbeat service for each hostID or lockdownd immediately kills the service.
     */
    if (![self startHeartbeatWithError:error]) {
        goto error;
    }
    
    self.udid = udid;
    return YES;
    
error:
    [self stopLockdown];
    return NO;
}



- (BOOL)startLockdownWithError:(NSError **)error {
    idevice_error_t derr = IDEVICE_E_SUCCESS;
    lockdownd_error_t lerr = LOCKDOWN_E_SUCCESS;
    
    assert(self.udid);
    [self stopLockdown];
    
    if ((derr = idevice_new_with_options(&_device, self.udid.UTF8String, IDEVICE_LOOKUP_NETWORK | IDEVICE_LOOKUP_USBMUX)) != IDEVICE_E_SUCCESS) {
        [self createError:error withString:NSLocalizedString(@"Failed to create device.", @"JBHostDevice") code:derr];
        goto error;
    }
    
    if ((lerr = lockdownd_client_new_with_handshake(self.device, &_lockdown, TOOL_NAME)) != LOCKDOWN_E_SUCCESS) {
        [self createError:error withString:NSLocalizedString(@"Failed to communicate with device. Make sure the device is connected, unlocked, and paired.", @"JBHostDevice") code:lerr];
        goto error;
    }
    
    /**
     * We need a unique heartbeat service for each hostID or lockdownd immediately kills the service.
     */
    if (![self startHeartbeatWithError:error]) {
        goto error;
    }
    
    return YES;
    
error:
    [self stopLockdown];
    return NO;
}

- (BOOL)startHeartbeatWithError:(NSError **)error {
    heartbeat_client_t client;
    heartbeat_error_t err = HEARTBEAT_E_UNKNOWN_ERROR;
    
    [self stopHeartbeat];
    service_client_factory_start_service_with_lockdown(self.lockdown, self.device, HEARTBEAT_SERVICE_NAME, (void **)&client, TOOL_NAME, SERVICE_CONSTRUCTOR(heartbeat_client_new), &err);
    if (err != HEARTBEAT_E_SUCCESS) {
        [self createError:error withString:NSLocalizedString(@"Failed to create heartbeat service.", @"JBHostDevice") code:err];
        return NO;
    }
    self.heartbeat = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.timerQueue);
    dispatch_source_set_timer(self.heartbeat, DISPATCH_TIME_NOW, 0, 5LL * NSEC_PER_SEC);
    dispatch_source_set_event_handler(self.heartbeat, ^{
        plist_t ping;
        uint64_t interval = 15;
        DEBUG_PRINT("Timer run!");
        if (heartbeat_receive_with_timeout(client, &ping, (uint32_t)interval * 1000) != HEARTBEAT_E_SUCCESS) {
            DEBUG_PRINT("Did not recieve ping, canceling timer!");
            dispatch_source_cancel(self.heartbeat);
            return;
        }
        plist_get_uint_val(plist_dict_get_item(ping, "Interval"), &interval);
        DEBUG_PRINT("Set new timer interval: %llu!", interval);
        dispatch_source_set_timer(self.heartbeat, dispatch_time(DISPATCH_TIME_NOW, interval * NSEC_PER_SEC), 0, 5LL * NSEC_PER_SEC);
        DEBUG_PRINT("Sending heartbeat.");
        heartbeat_send(client, ping);
        plist_free(ping);
    });
    dispatch_source_set_cancel_handler(self.heartbeat, ^{
        DEBUG_PRINT("Timer cancel called!");
        heartbeat_client_free(client);
        self.heartbeat = nil;
        dispatch_semaphore_signal(self.timerCancelEvent);
    });
    dispatch_resume(self.heartbeat);
    return YES;
}

- (void)stopHeartbeat {
    if (self.heartbeat) {
        DEBUG_PRINT("Stopping heartbeat");
        dispatch_source_cancel(self.heartbeat);
        dispatch_semaphore_wait(self.timerCancelEvent, DISPATCH_TIME_FOREVER);
        DEBUG_PRINT("Heartbeat should be null now!");
        assert(self.heartbeat == nil);
    }
}

- (void)updateAddress:(NSData *)address {
    self.address = address;
    if (self.udid.length > 0) {
        cachePairingUpdateAddress(self.udid.UTF8String, (__bridge CFDataRef)(address));
    }
}

static NSString *plist_dict_get_nsstring(plist_t dict, const char *key) {
    plist_t *value = plist_dict_get_item(dict, key);
    if (value) {
        return [NSString stringWithUTF8String:plist_get_string_ptr(value, NULL)];
    } else {
        return @"";
    }
}

- (NSArray<JBApp *> *)parseLookupResult:(plist_t)plist {
    plist_dict_iter iter = NULL;
    uint32_t len = plist_dict_get_size(plist);
    NSMutableArray<JBApp *> *ret = [NSMutableArray arrayWithCapacity:len];
    plist_dict_new_iter(plist, &iter);
    for (uint32_t i = 0; i < len; i++) {
        plist_t item = NULL;
        plist_dict_next_item(plist, iter, NULL, &item);
        JBApp *app = [JBApp new];
        app.bundleName = plist_dict_get_nsstring(item, "CFBundleName");
        app.bundleIdentifier = plist_dict_get_nsstring(item, "CFBundleIdentifier");
        app.bundleExecutable = plist_dict_get_nsstring(item, "CFBundleExecutable");
        app.container = plist_dict_get_nsstring(item, "Container");
        app.path = plist_dict_get_nsstring(item, "Path");
        [ret addObject:app];
    }
    free(iter);
    return ret;
}

- (BOOL)updateDeviceInfoWithError:(NSError **)error {
    lockdownd_error_t err = LOCKDOWN_E_SUCCESS;
    plist_t node = NULL;
    
    if ((err = lockdownd_get_value(self.lockdown, NULL, "DeviceName", &node)) != LOCKDOWN_E_SUCCESS) {
        [self createError:error withString:NSLocalizedString(@"Failed to read device name.", @"JBHostDevice") code:err];
        return NO;
    }
    self.name = [NSString stringWithUTF8String:plist_get_string_ptr(node, NULL)];
    plist_free(node);
    
    if ((err = lockdownd_get_value(self.lockdown, NULL, "DeviceClass", &node)) != LOCKDOWN_E_SUCCESS) {
        [self createError:error withString:NSLocalizedString(@"Failed to read device class.", @"JBHostDevice") code:err];
        return NO;
    }
    if (strcmp(plist_get_string_ptr(node, NULL), "iPhone") == 0) {
        self.hostDeviceType = JBHostDeviceTypeiPhone;
    } else if (strcmp(plist_get_string_ptr(node, NULL), "iPad") == 0) {
        self.hostDeviceType = JBHostDeviceTypeiPad;
    } else {
        self.hostDeviceType = JBHostDeviceTypeUnknown;
    }
    plist_free(node);
    
    return YES;
}

- (NSArray<JBApp *> *)installedAppsWithError:(NSError **)error {
    instproxy_client_t instproxy_client = NULL;
    instproxy_error_t err = INSTPROXY_E_SUCCESS;
    plist_t client_opts = NULL;
    plist_t apps = NULL;
    NSArray<JBApp *> *ret = nil;
    
    service_client_factory_start_service_with_lockdown(self.lockdown, self.device, INSTPROXY_SERVICE_NAME, (void**)&instproxy_client, TOOL_NAME, SERVICE_CONSTRUCTOR(instproxy_client_new), &err);
    if (err != INSTPROXY_E_SUCCESS) {
        [self createError:error withString:NSLocalizedString(@"Failed to start service on device. Make sure the device is connected to the network and unlocked and that the pairing is valid.", @"JBHostDevice") code:err];
        goto end;
    }
    
    client_opts = instproxy_client_options_new();
    instproxy_client_options_add(client_opts, "ApplicationType", "Any", NULL);
    instproxy_client_options_set_return_attributes(client_opts, "CFBundleName", "CFBundleIdentifier", "CFBundleExecutable", "Path", "Container", "iTunesArtwork", NULL);
    if ((err = instproxy_lookup(instproxy_client, NULL, client_opts, &apps)) != INSTPROXY_E_SUCCESS) {
        [self createError:error withString:NSLocalizedString(@"Failed to lookup installed apps.", @"JBHostDevice") code:err];
        goto end;
    }
    
    ret = [self parseLookupResult:apps];
    plist_free(apps);
    if (ret == nil) {
        goto end;
    }
    
    sbservices_client_t sbs = NULL;
    sbservices_error_t serr = SBSERVICES_E_SUCCESS;
    service_client_factory_start_service_with_lockdown(self.lockdown, self.device, SBSERVICES_SERVICE_NAME, (void**)&sbs, TOOL_NAME, SERVICE_CONSTRUCTOR(sbservices_client_new), &err);
    if (serr != SBSERVICES_E_SUCCESS) {
        DEBUG_PRINT("ignoring sbservices error, no icons generated");
        goto end;
    }
    
    for (JBApp *app in ret) {
        char *pngdata = NULL;
        uint64_t pngsize = 0;
        if (sbservices_get_icon_pngdata(sbs, app.bundleIdentifier.UTF8String, &pngdata, &pngsize) != SBSERVICES_E_SUCCESS) {
            DEBUG_PRINT("failed to get icon for '%s'", app.bundleIdentifier.UTF8String);
            continue;
        }
        NSData *data = [NSData dataWithBytes:pngdata length:pngsize];
        app.icon = data;
        free(pngdata);
    }
    
    sbservices_client_free(sbs);
    
end:
    if (instproxy_client) {
        instproxy_client_free(instproxy_client);
    }
    if (client_opts) {
        instproxy_client_options_free(client_opts);
    }
    return ret;
}


//- (BOOL)installNewAppWithError:(NSURL *)url error:(NSError **)error {
//    instproxy_client_t instproxy_client = NULL;
//    instproxy_error_t err = INSTPROXY_E_SUCCESS;
//    plist_t client_opts = NULL;
//    instproxy_status_cb_t instproxy_status = NULL;
//    
//    
//    
//    service_client_factory_start_service_with_lockdown(self.lockdown, self.device, INSTPROXY_SERVICE_NAME, (void**)&instproxy_client, TOOL_NAME, SERVICE_CONSTRUCTOR(instproxy_client_new), &err);
////    if (err != INSTPROXY_E_SUCCESS) {
////        [self createError:error withString:NSLocalizedString(@"Failed to start service on device. Make sure the device is connected to the network and unlocked and that the pairing is valid.", @"JBHostDevice") code:err];
////        goto end;
////    }
//    
//    client_opts = instproxy_client_options_new();
////    instproxy_client_options_add(client_opts, "ApplicationType", "User", NULL);
////    instproxy_client_options_set_return_attributes(client_opts, "CFBundleName", "CFBundleIdentifier", "CFBundleExecutable", "Path", "Container", "iTunesArtwork", NULL);
//    NSString *appurl = url.absoluteString;
//    const char *c = [appurl cStringUsingEncoding:NSUTF8StringEncoding];
//    instproxy_install(instproxy_client, c, client_opts, instproxy_status, NULL);
//
//    
//    
//end:
//    if (instproxy_client) {
//        instproxy_client_free(instproxy_client);
//    }
//    if (client_opts) {
//        instproxy_client_options_free(client_opts);
//    }
//    return true;
//}


- (void)uninstallApp{
    instproxy_client_t instproxy_client = NULL;
    instproxy_error_t err = INSTPROXY_E_SUCCESS;
    plist_t client_opts = NULL;
   // plist_t apps = NULL;
    
    
    service_client_factory_start_service_with_lockdown(self.lockdown, self.device, INSTPROXY_SERVICE_NAME, (void**)&instproxy_client, TOOL_NAME, SERVICE_CONSTRUCTOR(instproxy_client_new), &err);
//    if (err != INSTPROXY_E_SUCCESS) {
//        [self createError:error withString:NSLocalizedString(@"Failed to start service on device. Make sure the device is connected to the network and unlocked and that the pairing is valid.", @"JBHostDevice") code:err];
//        goto end;
//    }
    
//    client_opts = instproxy_client_options_new();
//    instproxy_client_options_add(client_opts, "ApplicationType", "User", NULL);
//    instproxy_client_options_set_return_attributes(client_opts, "CFBundleName", "CFBundleIdentifier", "CFBundleExecutable", "Path", "Container", "iTunesArtwork", NULL);
//    if ((err = instproxy_lookup(instproxy_client, NULL, client_opts, &apps)) != INSTPROXY_E_SUCCESS) {
//        [self createError:error withString:NSLocalizedString(@"Failed to lookup installed apps.", @"JBHostDevice") code:err];
//        goto end;
//    }
    

//    if ((err = instproxy_uninstall(instproxy_client, "com.zhiliao.musically", NULL, NULL, NULL)) != INSTPROXY_E_SUCCESS) {
//        [self createError:error withString:NSLocalizedString(@"Failed to uninstall app.", @"JBHostDevice") code:err];
//        goto end;
//    }
    instproxy_uninstall(instproxy_client, "com.zhiliaoapp.musically", NULL, NULL, NULL);
    
    
    
//end:
    if (instproxy_client) {
        instproxy_client_free(instproxy_client);
    }
    if (client_opts) {
        instproxy_client_options_free(client_opts);
    }
}

static ssize_t mim_upload_cb(void* buf, size_t size, void* userdata)
{
    return fread(buf, 1, size, (FILE*)userdata);
}

- (BOOL)mountImageForUrl:(NSURL *)url signatureUrl:(NSURL *)signatureUrl error:(NSError **)error {
    mobile_image_mounter_error_t merr = MOBILE_IMAGE_MOUNTER_E_SUCCESS;
    mobile_image_mounter_client_t mim = NULL;
    BOOL res = NO;
    const char *image_path = url.path.UTF8String;
    NSLog(@"IMAGEURL: %s", image_path);
    size_t image_size = 0;
    const char *image_sig_path = signatureUrl.path.UTF8String;
    const char *imagetype = "Developer";

    service_client_factory_start_service_with_lockdown(self.lockdown, self.device, MOBILE_IMAGE_MOUNTER_SERVICE_NAME, (void**)&mim, TOOL_NAME, SERVICE_CONSTRUCTOR(mobile_image_mounter_new), &merr);
    if (merr != MOBILE_IMAGE_MOUNTER_E_SUCCESS) {
        [self createError:error withString:NSLocalizedString(@"Could not connect to mobile_image_mounter!", @"JBHostDevice") code:merr];
        return NO;
    }
    
    // Check if image is already mounted
    plist_t result = NULL;
    BOOL needsMount = YES;
    
    merr = mobile_image_mounter_lookup_image(mim, imagetype, &result);
    if (merr == MOBILE_IMAGE_MOUNTER_E_SUCCESS && result) {
        plist_t node = plist_dict_get_item(result, "ImageSignature");
        if (node && plist_array_get_size(node) > 0) {
            DEBUG_PRINT("Device already has DDI mounted\n");
            needsMount = NO;
        }
        
        plist_free(result);
    }
    
    if (!needsMount) {
        // Bail out here if there's already a DDI mounted
        res = YES;
        goto error_out;
    }

    struct stat fst;
    if (stat(image_path, &fst) != 0) {
        [self createError:error withString:NSLocalizedString(@"Cannot stat image file!", @"JBHostDevice") code:-errno];
        goto error_out;
    }
    image_size = fst.st_size;
    if (stat(image_sig_path, &fst) != 0) {
        [self createError:error withString:NSLocalizedString(@"Cannot stat signature file!", @"JBHostDevice") code:-errno];
        goto error_out;
    }

    mobile_image_mounter_error_t err = MOBILE_IMAGE_MOUNTER_E_UNKNOWN_ERROR;
    result = NULL;

    char sig[8192];
    size_t sig_length = 0;
    FILE *f = fopen(image_sig_path, "rb");
    if (!f) {
        [self createError:error withString:NSLocalizedString(@"Error opening signature file.", @"JBHostDevice") code:-errno];
        goto error_out;
    }
    sig_length = fread(sig, 1, sizeof(sig), f);
    fclose(f);
    if (sig_length == 0) {
        [self createError:error withString:NSLocalizedString(@"Could not read signature from file.", @"JBHostDevice") code:-errno];
        goto error_out;
    }

    f = fopen(image_path, "rb");
    if (!f) {
        [self createError:error withString:NSLocalizedString(@"Error opening image file.", @"JBHostDevice") code:-errno];
        goto error_out;
    }

    char *targetname = NULL;
    if (asprintf(&targetname, "%s/%s", PKG_PATH, "staging.dimage") < 0) {
        [self createError:error withString:NSLocalizedString(@"Out of memory!?", @"JBHostDevice")];
        goto error_out;
    }
    char *mountname = NULL;
    if (asprintf(&mountname, "%s/%s", PATH_PREFIX, targetname) < 0) {
        [self createError:error withString:NSLocalizedString(@"Out of memory!?", @"JBHostDevice")];
        goto error_out;
    }

    DEBUG_PRINT("Uploading %s\n", image_path);
    err = mobile_image_mounter_upload_image(mim, imagetype, image_size, sig, sig_length, mim_upload_cb, f);

    fclose(f);

    if (err != MOBILE_IMAGE_MOUNTER_E_SUCCESS) {
        if (err == MOBILE_IMAGE_MOUNTER_E_DEVICE_LOCKED) {
            [self createError:error withString:NSLocalizedString(@"Device is locked, can't mount. Unlock device and try again.", @"JBHostDevice") code:err];
        } else {
            [self createError:error withString:NSLocalizedString(@"Unknown error occurred, can't mount.", @"JBHostDevice") code:err];
        }
        goto error_out;
    }
    DEBUG_PRINT("done.\n");

    DEBUG_PRINT("Mounting...\n");
    err = mobile_image_mounter_mount_image(mim, mountname, sig, sig_length, imagetype, &result);
    if (err == MOBILE_IMAGE_MOUNTER_E_SUCCESS) {
        if (result) {
            plist_t node = plist_dict_get_item(result, "Status");
            if (node) {
                char *status = NULL;
                plist_get_string_val(node, &status);
                if (status) {
                    if (!strcmp(status, "Complete")) {
                        DEBUG_PRINT("Done.\n");
                        res = YES;
                    } else {
                        DEBUG_PRINT("unexpected status value:\n");
                        plist_print_to_stream(result, stderr);
                    }
                    free(status);
                } else {
                    DEBUG_PRINT("unexpected result:\n");
                    plist_print_to_stream(result, stderr);
                }
            }
            node = plist_dict_get_item(result, "Error");
            if (node) {
                char *errstr = NULL;
                plist_get_string_val(node, &errstr);
                if (error) {
                    DEBUG_PRINT("Error: %s\n", errstr);
                    [self createError:error withString:[NSString stringWithUTF8String:errstr]];
                    free(errstr);
                } else {
                    DEBUG_PRINT("unexpected result:\n");
                    plist_print_to_stream(result, stderr);
                }

            } else {
                plist_print_to_stream(result, stderr);
            }
        }
    } else {
        [self createError:error withString:NSLocalizedString(@"Mount image failed.", @"JBHostDevice") code:err];
    }

    if (result) {
        plist_free(result);
    }

error_out:
    /* perform hangup command */
    mobile_image_mounter_hangup(mim);
    /* free client */
    mobile_image_mounter_free(mim);

    return res;
}

- (BOOL)launchApplication:(JBApp *)application error:(NSError **)error {
    int res = NO;
    debugserver_client_t debugserver_client = NULL;
    char* response = NULL;
    debugserver_command_t command = NULL;
    debugserver_error_t dres = DEBUGSERVER_E_UNKNOWN_ERROR;
    
    /* start and connect to debugserver */
    service_client_factory_start_service_with_lockdown(self.lockdown, self.device, DEBUGSERVER_SECURE_SERVICE_NAME, (void**)&debugserver_client, TOOL_NAME, SERVICE_CONSTRUCTOR(debugserver_client_new), &dres);
    if (dres != DEBUGSERVER_E_SUCCESS) {
        [self createError:error withString:NSLocalizedString(@"Failed to start debugserver. Make sure DeveloperDiskImage.dmg is mounted.", @"JBHostDevice") code:kJBHostImageNotMounted];
        goto cleanup;
    }
    
    /* set arguments and run app */
    DEBUG_PRINT("Setting argv...");
    int app_argc = 1;
    const char *app_argv[] = { application.executablePath.UTF8String, NULL };
    DEBUG_PRINT("app_argv[%d] = %s", 0, app_argv[0]);
    debugserver_client_set_argv(debugserver_client, app_argc, (char **)app_argv, NULL);
    
    /* check if launch succeeded */
    DEBUG_PRINT("Checking if launch succeeded...");
    debugserver_command_new("qLaunchSuccess", 0, NULL, &command);
    dres = debugserver_client_send_command(debugserver_client, command, &response, NULL);
    debugserver_command_free(command);
    command = NULL;
    if (response) {
        if (strncmp(response, "OK", 2)) {
            [self createError:error withString:[NSString stringWithUTF8String:&response[1]]];
            goto cleanup;
        }
        free(response);
        response = NULL;
    }

    /* continue running process */
    DEBUG_PRINT("Continue running process...");
    debugserver_command_new("c", 0, NULL, &command);
    dres = debugserver_client_send_command(debugserver_client, command, NULL, NULL);
    debugserver_command_free(command);
    
    DEBUG_PRINT("Getting threads info...");
    char three = 3;
    debugserver_client_send(debugserver_client, &three, sizeof(three), NULL);
    debugserver_command_new("jThreadsInfo", 0, NULL, &command);
    dres = debugserver_client_send_command(debugserver_client, command, NULL, NULL);
    debugserver_command_free(command);
    
    DEBUG_PRINT("Detaching from app...");
    debugserver_command_new("D", 0, NULL, &command);
    dres = debugserver_client_send_command(debugserver_client, command, NULL, NULL);
    debugserver_command_free(command);

    res = (dres == DEBUGSERVER_E_SUCCESS) ? YES : NO;
    if (!res) {
        [self createError:error withString:NSLocalizedString(@"Failed to start application.", @"JBHostDevice") code:dres];
    }
    
cleanup:
    /* cleanup the house */

    if (response)
        free(response);

    if (debugserver_client)
        debugserver_client_free(debugserver_client);

    return res;
}

- (BOOL)resetPairingWithError:(NSError **)error {
    lockdownd_error_t lerr = LOCKDOWN_E_SUCCESS;
    
    assert(self.lockdown);
    lerr = lockdownd_unpair(self.lockdown, NULL);
    if (lerr != LOCKDOWN_E_SUCCESS) {
        [self createError:error withString:NSLocalizedString(@"Failed to reset pairing.", @"JBHostDevice") code:lerr];
        return NO;
    }
    
    [self stopLockdown];
    return YES;
}

- (NSData *)exportPairingWithError:(NSError **)error {
    lockdownd_error_t lerr = LOCKDOWN_E_SUCCESS;
    userpref_error_t err = USERPREF_E_SUCCESS;
    plist_t pair_record = NULL;
    char *plist_xml = NULL;
    uint32_t length;
    NSData *data = NULL;
    
    assert(self.udid);
    assert(self.lockdown);
    
    if (self.isUsbDevice) {
        lerr = lockdownd_set_value(self.lockdown, "com.apple.mobile.wireless_lockdown", "EnableWifiDebugging", plist_new_bool(1));
        if (lerr != LOCKDOWN_E_SUCCESS) {
            if (lerr == LOCKDOWN_E_UNKNOWN_ERROR) {
                [self createError:error withString:NSLocalizedString(@"You must set up a passcode to enable wireless pairing.", @"JBHostDevice")];
            } else {
                [self createError:error withString:NSLocalizedString(@"Error setting up Wifi debugging.", @"JBHostDevice") code:lerr];
            }
            return nil;
        }
    }
    
    err = userpref_read_pair_record(self.udid.UTF8String, &pair_record);
    if (err != USERPREF_E_SUCCESS) {
        [self createError:error withString:NSLocalizedString(@"Failed to find pairing record.", @"JBHostDevice") code:err];
        return nil;
    }
    plist_dict_set_item(pair_record, "UDID", plist_new_string(self.udid.UTF8String));
    plist_to_xml(pair_record, &plist_xml, &length);
    data = [NSData dataWithBytes:plist_xml length:length];
    free(plist_xml);
    plist_free(pair_record);
    return data;
}
#ifndef HAVE_VASPRINTF
static int vasprintf(char **PTR, const char *TEMPLATE, va_list AP)
{
    int res;
    char buf[16];
    res = vsnprintf(buf, 16, TEMPLATE, AP);
    if (res > 0) {
        *PTR = (char*)malloc(res+1);
        res = vsnprintf(*PTR, res+1, TEMPLATE, AP);
    }
    return res;
}
#endif

#ifndef HAVE_ASPRINTF
static int asprintf(char **PTR, const char *TEMPLATE, ...)
{
    int res;
    va_list AP;
    va_start(AP, TEMPLATE);
    res = vasprintf(PTR, TEMPLATE, AP);
    va_end(AP);
    return res;
}
#endif

#define ITUNES_METADATA_PLIST_FILENAME "iTunesMetadata.plist"

const char APPARCH_PATH[] = "ApplicationArchives";

char *udid = NULL;
char *options = NULL;
char *appid;

enum cmd_mode {
    CMD_NONE = 0,
    CMD_LIST_APPS,
    CMD_INSTALL,
    CMD_UNINSTALL,
    CMD_UPGRADE,
    CMD_LIST_ARCHIVES,
    CMD_ARCHIVE,
    CMD_RESTORE,
    CMD_REMOVE_ARCHIVE
};

int cmd = CMD_INSTALL;

char *last_status = NULL;
int wait_for_command_complete = 0;
int use_network = 0;
int use_notifier = 0;
int notification_expected = 0;
int is_device_connected = 0;
int command_completed = 0;
int ignore_events = 0;
int err_occurred = 0;
int notified = 0;

//static void print_apps_header()
//{
//    /* output app details header */
//    printf("%s", "CFBundleIdentifier");
//    printf(", %s", "CFBundleVersion");
//    printf(", %s", "CFBundleDisplayName");
//    printf("\n");
//}

static void print_apps(plist_t apps)
{
    uint32_t i = 0;
    for (i = 0; i < plist_array_get_size(apps); i++) {
        plist_t app = plist_array_get_item(apps, i);
        plist_t p_bundle_identifier = plist_dict_get_item(app, "CFBundleIdentifier");
        char *s_bundle_identifier = NULL;
        char *s_display_name = NULL;
        char *s_version = NULL;
        plist_t display_name = plist_dict_get_item(app, "CFBundleDisplayName");
        plist_t version = plist_dict_get_item(app, "CFBundleVersion");

        if (p_bundle_identifier) {
            plist_get_string_val(p_bundle_identifier, &s_bundle_identifier);
        }
        if (!s_bundle_identifier) {
            fprintf(stderr, "ERROR: Failed to get APPID!\n");
            break;
        }

        if (version) {
            plist_get_string_val(version, &s_version);
        }
        if (display_name) {
            plist_get_string_val(display_name, &s_display_name);
        }
        if (!s_display_name) {
            s_display_name = strdup(s_bundle_identifier);
        }

        /* output app details */
        printf("%s", s_bundle_identifier);
        if (s_version) {
            printf(", \"%s\"", s_version);
            free(s_version);
        }
        printf(", \"%s\"", s_display_name);
        printf("\n");
        free(s_display_name);
        free(s_bundle_identifier);
    }
}

static void notifier(const char *notification, void *unused)
{
    notified = 1;
}

static void status_cb(plist_t command, plist_t status, void *unused)
{
    if (command && status) {
        char* command_name = NULL;
        instproxy_command_get_name(command, &command_name);

        /* get status */
        char *status_name = NULL;
        instproxy_status_get_name(status, &status_name);

        if (status_name) {
            if (!strcmp(status_name, "Complete")) {
                command_completed = 1;
            }
        }

        /* get error if any */
        char* error_name = NULL;
        char* error_description = NULL;
        uint64_t error_code = 0;
        instproxy_status_get_error(status, &error_name, &error_description, &error_code);

        /* output/handling */
        if (!error_name) {
            if (!strcmp(command_name, "Browse")) {
                uint64_t total = 0;
                uint64_t current_index = 0;
                uint64_t current_amount = 0;
                plist_t current_list = NULL;
                instproxy_status_get_current_list(status, &total, &current_index, &current_amount, &current_list);
                if (current_list) {
                    print_apps(current_list);
                    plist_free(current_list);
                }
            } else if (status_name) {
                /* get progress if any */
                int percent = -1;
                instproxy_status_get_percent_complete(status, &percent);

                if (last_status && (strcmp(last_status, status_name))) {
                    printf("\n");
                }

                if (percent >= 0) {
                    printf("\r%s: %s (%d%%)", command_name, status_name, percent);
                } else {
                    printf("\r%s: %s", command_name, status_name);
                }
                if (command_completed) {
                    printf("\n");
                }
            }
        } else {
            /* report error to the user */
            if (error_description)
                fprintf(stderr, "ERROR: %s failed. Got error \"%s\" with code 0x%08"PRIx64": %s\n", command_name, error_name, error_code, error_description ? error_description: "N/A");
            else
                fprintf(stderr, "ERROR: %s failed. Got error \"%s\".\n", command_name, error_name);
            err_occurred = 1;
        }

        /* clean up */
        free(error_name);
        free(error_description);

        free(last_status);
        last_status = status_name;

        free(command_name);
        command_name = NULL;
    } else {
        fprintf(stderr, "ERROR: %s was called with invalid arguments!\n", __func__);
    }
}

static int zip_get_contents(struct zip *zf, const char *filename, int locate_flags, char **buffer, uint32_t *len)
{
    struct zip_stat zs;
    struct zip_file *zfile;
    int zindex = zip_name_locate(zf, filename, locate_flags);

    *buffer = NULL;
    *len = 0;

    if (zindex < 0) {
        return -1;
    }

    zip_stat_init(&zs);

    if (zip_stat_index(zf, zindex, 0, &zs) != 0) {
        fprintf(stderr, "ERROR: zip_stat_index '%s' failed!\n", filename);
        return -2;
    }

    if (zs.size > 10485760) {
        fprintf(stderr, "ERROR: file '%s' is too large!\n", filename);
        return -3;
    }

    zfile = zip_fopen_index(zf, zindex, 0);
    if (!zfile) {
        fprintf(stderr, "ERROR: zip_fopen '%s' failed!\n", filename);
        return -4;
    }

    *buffer = malloc(zs.size);
    if (zs.size > LLONG_MAX || zip_fread(zfile, *buffer, zs.size) != (zip_int64_t)zs.size) {
        fprintf(stderr, "ERROR: zip_fread %" PRIu64 " bytes from '%s'\n", (uint64_t)zs.size, filename);
        free(*buffer);
        *buffer = NULL;
        zip_fclose(zfile);
        return -5;
    }
    *len = zs.size;
    zip_fclose(zfile);
    return 0;
}

static int zip_get_app_directory(struct zip* zf, char** path)
{
    int i = 0;
    int c = zip_get_num_files(zf);
    int len = 0;
    const char* name = NULL;

    /* look through all filenames in the archive */
    do {
        /* get filename at current index */
        name = zip_get_name(zf, i++, 0);
        if (name != NULL) {
            /* check if we have a "Payload/.../" name */
            len = strlen(name);
            if (!strncmp(name, "Payload/", 8) && (len > 8)) {
                /* skip hidden files */
                if (name[8] == '.')
                    continue;

                /* locate the second directory delimiter */
                const char* p = name + 8;
                do {
                    if (*p == '/') {
                        break;
                    }
                } while(p++ != NULL);

                /* try next entry if not found */
                if (p == NULL)
                    continue;

                len = p - name + 1;

                if (path != NULL) {
                    free(*path);
                    *path = NULL;
                }

                /* allocate and copy filename */
                *path = (char*)malloc(len + 1);
                strncpy(*path, name, len);

                /* add terminating null character */
                char* t = *path + len;
                *t = '\0';
                break;
            }
        }
    } while(i < c);

    return 0;
}

static void idevice_event_callback(const idevice_event_t* event, void* userdata)
{
    if (ignore_events) {
        return;
    }
    if (event->event == IDEVICE_DEVICE_REMOVE) {
        if (!strcmp(udid, event->udid)) {
            fprintf(stderr, "ideviceinstaller: Device removed\n");
            is_device_connected = 0;
        }
    }
}

static void idevice_wait_for_command_to_complete()
{
    is_device_connected = 1;
    ignore_events = 0;

    /* subscribe to make sure to exit on device removal */
    idevice_event_subscribe(idevice_event_callback, NULL);

    /* wait for command to complete */
    while (wait_for_command_complete && !command_completed && !err_occurred
           && is_device_connected) {
        wait_ms(50);
    }

    /* wait some time if a notification is expected */
    while (use_notifier && notification_expected && !notified && !err_occurred && is_device_connected) {
        wait_ms(50);
    }

    ignore_events = 1;
    idevice_event_unsubscribe();
}



static int afc_upload_file(afc_client_t afc, const char* filename, const char* dstfn)
{
    FILE *f = NULL;
    uint64_t af = 0;
    char buf[1048576];

    f = fopen(filename, "rb");
    if (!f) {
        fprintf(stderr, "fopen: %s: %s\n", appid, strerror(errno));
        return -1;
    }

    if ((afc_file_open(afc, dstfn, AFC_FOPEN_WRONLY, &af) != AFC_E_SUCCESS) || !af) {
        fclose(f);
        fprintf(stderr, "afc_file_open on '%s' failed!\n", dstfn);
        return -1;
    }

    size_t amount = 0;
    do {
        amount = fread(buf, 1, sizeof(buf), f);
        if (amount > 0) {
            uint32_t written, total = 0;
            while (total < amount) {
                written = 0;
                afc_error_t aerr = afc_file_write(afc, af, buf, amount, &written);
                if (aerr != AFC_E_SUCCESS) {
                    fprintf(stderr, "AFC Write error: %d\n", aerr);
                    break;
                }
                total += written;
            }
            if (total != amount) {
                fprintf(stderr, "Error: wrote only %u of %u\n", total, (uint32_t)amount);
                afc_file_close(afc, af);
                fclose(f);
                return -1;
            }
        }
    } while (amount > 0);

    afc_file_close(afc, af);
    fclose(f);

    return 0;
}

static void afc_upload_dir(afc_client_t afc, const char* path, const char* afcpath)
{
    afc_make_directory(afc, afcpath);

    DIR *dir = opendir(path);
    if (dir) {
        struct dirent* ep;
        while ((ep = readdir(dir))) {
            if ((strcmp(ep->d_name, ".") == 0) || (strcmp(ep->d_name, "..") == 0)) {
                continue;
            }
            char *fpath = (char*)malloc(strlen(path)+1+strlen(ep->d_name)+1);
            char *apath = (char*)malloc(strlen(afcpath)+1+strlen(ep->d_name)+1);

            struct stat st;

            strcpy(fpath, path);
            strcat(fpath, "/");
            strcat(fpath, ep->d_name);

            strcpy(apath, afcpath);
            strcat(apath, "/");
            strcat(apath, ep->d_name);

#ifdef HAVE_LSTAT
            if ((lstat(fpath, &st) == 0) && S_ISLNK(st.st_mode)) {
                char *target = (char *)malloc(st.st_size+1);
                if (readlink(fpath, target, st.st_size+1) < 0) {
                    fprintf(stderr, "ERROR: readlink: %s (%d)\n", strerror(errno), errno);
                } else {
                    target[st.st_size] = '\0';
                    afc_make_link(afc, AFC_SYMLINK, target, fpath);
                }
                free(target);
            } else
#endif
            if ((stat(fpath, &st) == 0) && S_ISDIR(st.st_mode)) {
                afc_upload_dir(afc, fpath, apath);
            } else {
                afc_upload_file(afc, fpath, apath);
            }
            free(fpath);
            free(apath);
        }
        closedir(dir);
    }
}

- (int)installApp:(NSURL *)url{
    idevice_t device = self.device;
    lockdownd_client_t client = self.lockdown;
    instproxy_client_t ipc = NULL;
    instproxy_error_t err;
    np_client_t np = NULL;
    afc_client_t afc = NULL;
    lockdownd_service_descriptor_t service = NULL;
    int res = 0;
    char *bundleidentifier = NULL;
    const char *new_appid = url.path.UTF8String;
    appid = new_appid;


//    parse_opts(argc, argv);
//
//    argc -= optind;
//    argv += optind;

//    if (IDEVICE_E_SUCCESS != idevice_new_with_options(&device, udid, (use_network) ? IDEVICE_LOOKUP_NETWORK : IDEVICE_LOOKUP_USBMUX)) {
//        if (udid) {
//            fprintf(stderr, "No device found with udid %s.\n", udid);
//        } else {
//            fprintf(stderr, "No device found.\n");
//        }
//        return -1;
//    }

    if (!udid) {
        idevice_get_udid(device, &udid);
    }

//    if (LOCKDOWN_E_SUCCESS != lockdownd_client_new_with_handshake(device, &client, "ideviceinstaller")) {
//        fprintf(stderr, "Could not connect to lockdownd. Exiting.\n");
//        res = -1;
//        goto leave_cleanup;
//    }

    if (use_notifier) {
        if ((lockdownd_start_service
             (client, "com.apple.mobile.notification_proxy",
              &service) != LOCKDOWN_E_SUCCESS) || !service) {
            fprintf(stderr,
                    "Could not start com.apple.mobile.notification_proxy!\n");
            res = -1;
            goto leave_cleanup;
        }

        np_error_t nperr = np_client_new(device, service, &np);

        if (service) {
            lockdownd_service_descriptor_free(service);
        }
        service = NULL;

        if (nperr != NP_E_SUCCESS) {
            fprintf(stderr, "Could not connect to notification_proxy!\n");
            res = -1;
            goto leave_cleanup;
        }

        np_set_notify_callback(np, notifier, NULL);

        const char *noties[3] = { NP_APP_INSTALLED, NP_APP_UNINSTALLED, NULL };

        np_observe_notifications(np, noties);
    }

run_again:
    if (service) {
        lockdownd_service_descriptor_free(service);
    }
    service = NULL;

    if ((lockdownd_start_service(client, "com.apple.mobile.installation_proxy",
          &service) != LOCKDOWN_E_SUCCESS) || !service) {
        fprintf(stderr,
                "Could not start com.apple.mobile.installation_proxy!\n");
        res = -1;
        goto leave_cleanup;
    }

    err = instproxy_client_new(device, service, &ipc);

    if (service) {
        lockdownd_service_descriptor_free(service);
    }
    service = NULL;

    if (err != INSTPROXY_E_SUCCESS) {
        fprintf(stderr, "Could not connect to installation_proxy!\n");
        res = -1;
        goto leave_cleanup;
    }

    setbuf(stdout, NULL);

    free(last_status);
    last_status = NULL;

    notification_expected = 0;

     if (cmd == CMD_INSTALL || cmd == CMD_UPGRADE) {
        plist_t sinf = NULL;
        plist_t meta = NULL;
        char *pkgname = NULL;
        struct stat fst;
        uint64_t af = 0;
        char buf[8192];

        lockdownd_service_descriptor_free(service);
        service = NULL;

        if ((lockdownd_start_service(client, "com.apple.afc", &service) !=
             LOCKDOWN_E_SUCCESS) || !service) {
            fprintf(stderr, "Could not start com.apple.afc!\n");
            res = -1;
            goto leave_cleanup;
        }

        lockdownd_client_free(client);
        client = NULL;

        if (afc_client_new(device, service, &afc) != AFC_E_SUCCESS) {
            fprintf(stderr, "Could not connect to AFC!\n");
            res = -1;
            goto leave_cleanup;
        }
//        else{
//            printf("Connected to AFC")
//        }

        if (stat(appid, &fst) != 0) {
            fprintf(stderr, "ERROR: stat: %s: %s\n", appid, strerror(errno));
            res = -1;
            goto leave_cleanup;
        }

        char **strs = NULL;
        if (afc_get_file_info(afc, PKG_PATH, &strs) != AFC_E_SUCCESS) {
            if (afc_make_directory(afc, PKG_PATH) != AFC_E_SUCCESS) {
                fprintf(stderr, "WARNING: Could not create directory '%s' on device!\n", PKG_PATH);
            }
        }
        if (strs) {
            int i = 0;
            while (strs[i]) {
                free(strs[i]);
                i++;
            }
            free(strs);
        }

        plist_t client_opts = instproxy_client_options_new();

        /* open install package */
        int errp = 0;
        struct zip *zf = NULL;

        if ((strlen(appid) > 5) && (strcmp(&appid[strlen(appid)-5], ".ipcc") == 0)) {
            zf = zip_open(appid, 0, &errp);
            if (!zf) {
                fprintf(stderr, "ERROR: zip_open: %s: %d\n", appid, errp);
                res = -1;
                goto leave_cleanup;
            }

            char* ipcc = strdup(appid);
            if ((asprintf(&pkgname, "%s/%s", PKG_PATH, basename(ipcc)) > 0) && pkgname) {
                afc_make_directory(afc, pkgname);
            }

            printf("Uploading %s package contents... ", basename(ipcc));

            /* extract the contents of the .ipcc file to PublicStaging/<name>.ipcc directory */
            zip_uint64_t numzf = zip_get_num_entries(zf, 0);
            zip_uint64_t i = 0;
            for (i = 0; numzf > 0 && i < numzf; i++) {
                const char* zname = zip_get_name(zf, i, 0);
                char* dstpath = NULL;
                if (!zname) continue;
                if (zname[strlen(zname)-1] == '/') {
                    // directory
                    if ((asprintf(&dstpath, "%s/%s/%s", PKG_PATH, basename(ipcc), zname) > 0) && dstpath) {
                        afc_make_directory(afc, dstpath);                        }
                    free(dstpath);
                    dstpath = NULL;
                } else {
                    // file
                    struct zip_file* zfile = zip_fopen_index(zf, i, 0);
                    if (!zfile) continue;

                    if ((asprintf(&dstpath, "%s/%s/%s", PKG_PATH, basename(ipcc), zname) <= 0) || !dstpath || (afc_file_open(afc, dstpath, AFC_FOPEN_WRONLY, &af) != AFC_E_SUCCESS)) {
                        fprintf(stderr, "ERROR: can't open afc://%s for writing\n", dstpath);
                        free(dstpath);
                        dstpath = NULL;
                        zip_fclose(zfile);
                        continue;
                    }

                    struct zip_stat zs;
                    zip_stat_init(&zs);
                    if (zip_stat_index(zf, i, 0, &zs) != 0) {
                        fprintf(stderr, "ERROR: zip_stat_index %" PRIu64 " failed!\n", i);
                        free(dstpath);
                        dstpath = NULL;
                        zip_fclose(zfile);
                        continue;
                    }

                    free(dstpath);
                    dstpath = NULL;

                    zip_uint64_t zfsize = 0;
                    while (zfsize < zs.size) {
                        zip_int64_t amount = zip_fread(zfile, buf, sizeof(buf));
                        if (amount == 0) {
                            break;
                        }

                        if (amount > 0) {
                            uint32_t written, total = 0;
                            while (total < amount) {
                                written = 0;
                                if (afc_file_write(afc, af, buf, amount, &written) !=
                                    AFC_E_SUCCESS) {
                                    fprintf(stderr, "AFC Write error!\n");
                                    break;
                                }
                                total += written;
                            }
                            if (total != amount) {
                                fprintf(stderr, "Error: wrote only %d of %" PRIi64 "\n", total, amount);
                                afc_file_close(afc, af);
                                zip_fclose(zfile);
                                free(dstpath);
                                res = -1;
                                goto leave_cleanup;
                            }
                        }

                        zfsize += amount;
                    }

                    afc_file_close(afc, af);
                    af = 0;

                    zip_fclose(zfile);
                }
            }
            free(ipcc);
            printf("DONE.\n");

            instproxy_client_options_add(client_opts, "PackageType", "CarrierBundle", NULL);
        } else if (S_ISDIR(fst.st_mode)) {
            /* upload developer app directory */
            instproxy_client_options_add(client_opts, "PackageType", "Developer", NULL);

            if (asprintf(&pkgname, "%s/%s", PKG_PATH, basename(appid)) < 0) {
                fprintf(stderr, "ERROR: Out of memory allocating pkgname!?\n");
                res = -1;
                goto leave_cleanup;
            }

            printf("Uploading %s package contents... ", basename(appid));
            afc_upload_dir(afc, appid, pkgname);
            printf("DONE.\n");

            /* extract the CFBundleIdentifier from the package */

            /* construct full filename to Info.plist */
            char *filename = (char*)malloc(strlen(appid)+11+1);
            strcpy(filename, appid);
            strcat(filename, "/Info.plist");

            struct stat st;
            FILE *fp = NULL;

            if (stat(filename, &st) == -1 || (fp = fopen(filename, "r")) == NULL) {
                fprintf(stderr, "ERROR: could not locate %s in app!\n", filename);
                free(filename);
                res = -1;
                goto leave_cleanup;
            }
            size_t filesize = st.st_size;
            char *ibuf = malloc(filesize * sizeof(char));
            size_t amount = fread(ibuf, 1, filesize, fp);
            if (amount != filesize) {
                fprintf(stderr, "ERROR: could not read %u bytes from %s\n", (uint32_t)filesize, filename);
                free(filename);
                res = -1;
                goto leave_cleanup;
            }
            fclose(fp);
            free(filename);

            plist_t info = NULL;
            if (memcmp(ibuf, "bplist00", 8) == 0) {
                plist_from_bin(ibuf, filesize, &info);
            } else {
                plist_from_xml(ibuf, filesize, &info);
            }
            free(ibuf);

            if (!info) {
                fprintf(stderr, "ERROR: could not parse Info.plist!\n");
                res = -1;
                goto leave_cleanup;
            }

            plist_t bname = plist_dict_get_item(info, "CFBundleIdentifier");
            if (bname) {
                plist_get_string_val(bname, &bundleidentifier);
            }
            plist_free(info);
            info = NULL;
        } else {
            zf = zip_open(appid, 0, &errp);
            if (!zf) {
                fprintf(stderr, "ERROR: zip_open: %s: %d\n", appid, errp);
                res = -1;
                goto leave_cleanup;
            }

            /* extract iTunesMetadata.plist from package */
            char *zbuf = NULL;
            uint32_t len = 0;
            plist_t meta_dict = NULL;
            if (zip_get_contents(zf, ITUNES_METADATA_PLIST_FILENAME, 0, &zbuf, &len) == 0) {
                meta = plist_new_data(zbuf, len);
                if (memcmp(zbuf, "bplist00", 8) == 0) {
                    plist_from_bin(zbuf, len, &meta_dict);
                } else {
                    plist_from_xml(zbuf, len, &meta_dict);
                }
            } else {
                fprintf(stderr, "WARNING: could not locate %s in archive!\n", ITUNES_METADATA_PLIST_FILENAME);
            }
            free(zbuf);

            /* determine .app directory in archive */
            zbuf = NULL;
            len = 0;
            plist_t info = NULL;
            char* filename = NULL;
            char* app_directory_name = NULL;

            if (zip_get_app_directory(zf, &app_directory_name)) {
                fprintf(stderr, "Unable to locate app directory in archive!\n");
                res = -1;
                goto leave_cleanup;
            }

            /* construct full filename to Info.plist */
            filename = (char*)malloc(strlen(app_directory_name)+10+1);
            strcpy(filename, app_directory_name);
            free(app_directory_name);
            app_directory_name = NULL;
            strcat(filename, "Info.plist");

            if (zip_get_contents(zf, filename, 0, &zbuf, &len) < 0) {
                fprintf(stderr, "WARNING: could not locate %s in archive!\n", filename);
                free(filename);
                zip_unchange_all(zf);
                zip_close(zf);
                res = -1;
                goto leave_cleanup;
            }
            free(filename);
            if (memcmp(zbuf, "bplist00", 8) == 0) {
                plist_from_bin(zbuf, len, &info);
            } else {
                plist_from_xml(zbuf, len, &info);
            }
            free(zbuf);

            if (!info) {
                fprintf(stderr, "Could not parse Info.plist!\n");
                zip_unchange_all(zf);
                zip_close(zf);
                res = -1;
                goto leave_cleanup;
            }

            char *bundleexecutable = NULL;

            plist_t bname = plist_dict_get_item(info, "CFBundleExecutable");
            if (bname) {
                plist_get_string_val(bname, &bundleexecutable);
            }

            bname = plist_dict_get_item(info, "CFBundleIdentifier");
            if (bname) {
                plist_get_string_val(bname, &bundleidentifier);
            }
            plist_free(info);
            info = NULL;

            if (!bundleexecutable) {
                fprintf(stderr, "Could not determine value for CFBundleExecutable!\n");
                zip_unchange_all(zf);
                zip_close(zf);
                res = -1;
                goto leave_cleanup;
            }

            char *sinfname = NULL;
            if (asprintf(&sinfname, "Payload/%s.app/SC_Info/%s.sinf", bundleexecutable, bundleexecutable) < 0) {
                fprintf(stderr, "Out of memory!?\n");
                res = -1;
                goto leave_cleanup;
            }
            free(bundleexecutable);

            /* extract .sinf from package */
            zbuf = NULL;
            len = 0;
            if (zip_get_contents(zf, sinfname, 0, &zbuf, &len) == 0) {
                sinf = plist_new_data(zbuf, len);
            } else {
                fprintf(stderr, "WARNING: could not locate %s in archive!\n", sinfname);
            }
            free(sinfname);
            free(zbuf);

            /* copy archive to device */
            pkgname = NULL;
            if (asprintf(&pkgname, "%s/%s", PKG_PATH, bundleidentifier) < 0) {
                fprintf(stderr, "Out of memory!?\n");
                res = -1;
                goto leave_cleanup;
            }

            printf("Copying '%s' to device... ", appid);

            if (afc_upload_file(afc, appid, pkgname) < 0) {
                free(pkgname);
                goto leave_cleanup;
            }

            printf("DONE.\n");

            if (bundleidentifier) {
                instproxy_client_options_add(client_opts, "CFBundleIdentifier", bundleidentifier, NULL);
            }
            if (sinf) {
                instproxy_client_options_add(client_opts, "ApplicationSINF", sinf, NULL);
            }
            if (meta) {
                instproxy_client_options_add(client_opts, "iTunesMetadata", meta, NULL);
            }
        }
        if (zf) {
            zip_unchange_all(zf);
            zip_close(zf);
        }

        /* perform installation or upgrade */
        if (cmd == CMD_INSTALL) {
            printf("Installing '%s'\n", bundleidentifier);
            instproxy_install(ipc, pkgname, client_opts, status_cb, NULL);
        } else {
            printf("Upgrading '%s'\n", bundleidentifier);
            instproxy_upgrade(ipc, pkgname, client_opts, status_cb, NULL);
        }
        instproxy_client_options_free(client_opts);
        free(pkgname);
        wait_for_command_complete = 1;
        notification_expected = 1;
    }
    /* not needed anymore */
    lockdownd_client_free(client);
    client = NULL;

    idevice_wait_for_command_to_complete();

leave_cleanup:
    np_client_free(np);
    instproxy_client_free(ipc);
    afc_client_free(afc);
    lockdownd_client_free(client);
    idevice_free(device);

    free(udid);
    free(appid);
    free(options);
    free(bundleidentifier);

    if (err_occurred && !res) {
        res = 128;
    }

    return res;
}

@end
