//
//  ALTDeviceManager.m
//  AltServer
//
//  Created by Riley Testut on 5/24/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

#import "ALTDeviceManager.h"
//
//#import "ALTWiredConnection+Private.h"
//#import "ALTNotificationConnection+Private.h"
//#import "ALTDebugConnection+Private.h"

//#import "ALTConstants.h"
//#import "NSError+ALTServerError.h"
//#import "NSError+libimobiledevice.h"
//
//#import <AppKit/AppKit.h>
//#import <UserNotifications/UserNotifications.h>
//#import "AltServer-Swift.h"

#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/installation_proxy.h>
#include <libimobiledevice/notification_proxy.h>
#include <libimobiledevice/afc.h>
#include <libimobiledevice/misagent.h>
#include <libimobiledevice/mobile_image_mounter.h>

//void ALTDeviceManagerUpdateStatus(plist_t command, plist_t status, void *udid);
//void ALTDeviceManagerUpdateAppDeletionStatus(plist_t command, plist_t status, void *uuid);
//void ALTDeviceDidChangeConnectionStatus(const idevice_event_t *event, void *user_data);
//ssize_t ALTDeviceManagerUploadFile(void *buffer, size_t size, void *user_data);
//
//NSNotificationName const ALTDeviceManagerDeviceDidConnectNotification = @"ALTDeviceManagerDeviceDidConnectNotification";
//NSNotificationName const ALTDeviceManagerDeviceDidDisconnectNotification = @"ALTDeviceManagerDeviceDidDisconnectNotification";
//
@interface ALTDeviceManager ()
//
//@property (nonatomic, readonly) NSMutableDictionary<NSUUID *, void (^)(NSError *)> *installationCompletionHandlers;
//@property (nonatomic, readonly) NSMutableDictionary<NSUUID *, void (^)(NSError *)> *deletionCompletionHandlers;
//
//@property (nonatomic, readonly) NSMutableDictionary<NSUUID *, NSProgress *> *installationProgress;
//
//@property (nonatomic, readonly) dispatch_queue_t installationQueue;
//@property (nonatomic, readonly) dispatch_queue_t devicesQueue;
//
//@property (nonatomic, readonly) NSMutableSet<ALTDevice *> *cachedDevices;
//
@end
//
@implementation ALTDeviceManager


+ (BOOL)writeDirectory:(NSURL *)directoryURL toDestinationURL:(NSURL *)destinationURL client:(afc_client_t)afc progress:(NSProgress *)progress error:(NSError **)error
{
    afc_make_directory(afc, destinationURL.relativePath.fileSystemRepresentation);
    
    if (progress == nil)
    {
        NSDirectoryEnumerator *countEnumerator = [[NSFileManager defaultManager] enumeratorAtURL:directoryURL
                                                                      includingPropertiesForKeys:@[]
                                                                                         options:0
                                                                                    errorHandler:^BOOL(NSURL * _Nonnull url, NSError * _Nonnull error) {
                                                                                        if (error) {
                                                                                            NSLog(@"[Error] %@ (%@)", error, url);
                                                                                            return NO;
                                                                                        }
                                                                                        
                                                                                        return YES;
                                                                                    }];
        
        NSInteger totalCount = 0;
        for (NSURL *__unused fileURL in countEnumerator)
        {
            totalCount++;
        }
        
        progress = [NSProgress progressWithTotalUnitCount:totalCount];
    }
    
    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtURL:directoryURL
                                                             includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                                                                options:NSDirectoryEnumerationSkipsSubdirectoryDescendants
                                                                           errorHandler:^BOOL(NSURL * _Nonnull url, NSError * _Nonnull error) {
                                                                               if (error) {
                                                                                   NSLog(@"[Error] %@ (%@)", error, url);
                                                                                   return NO;
                                                                               }
                                                                               
                                                                               return YES;
                                                                           }];
    
    for (NSURL *fileURL in enumerator)
    {
        NSNumber *isDirectory = nil;
        if (![fileURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:error])
        {
            return NO;
        }
        
        if ([isDirectory boolValue])
        {
            NSURL *destinationDirectoryURL = [destinationURL URLByAppendingPathComponent:fileURL.lastPathComponent isDirectory:YES];
            if (![self writeDirectory:fileURL toDestinationURL:destinationDirectoryURL client:afc progress:progress error:error])
            {
                return NO;
            }
        }
        else
        {
            NSURL *destinationFileURL = [destinationURL URLByAppendingPathComponent:fileURL.lastPathComponent isDirectory:NO];
            if (![self writeFile:fileURL toDestinationURL:destinationFileURL progress:progress client:afc error:error])
            {
                return NO;
            }
        }
        
        progress.completedUnitCount += 1;
    }
    
    return YES;
}

+ (BOOL)writeFile:(NSURL *)fileURL toDestinationURL:(NSURL *)destinationURL progress:(NSProgress *)progress client:(afc_client_t)afc error:(NSError **)error
{
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:fileURL.path];
    if (fileHandle == nil)
    {
        if (error)
        {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:@{NSURLErrorKey: fileURL}];
        }
        
        return NO;
    }
    
    NSData *data = [fileHandle readDataToEndOfFile];

    uint64_t af = 0;
    
    int openResult = afc_file_open(afc, destinationURL.relativePath.fileSystemRepresentation, AFC_FOPEN_WRONLY, &af);
    if (openResult != AFC_E_SUCCESS || af == 0)
    {
        if (openResult == AFC_E_OBJECT_IS_DIR)
        {
            NSLog(@"Treating file as directory: %@ %@", fileURL, destinationURL);
            return [self writeDirectory:fileURL toDestinationURL:destinationURL client:afc progress:progress error:error];
        }
        
        if (error)
        {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:@{NSURLErrorKey: destinationURL}];
        }
        
        return NO;
    }
    
    BOOL success = YES;
    uint32_t bytesWritten = 0;
        
    while (bytesWritten < data.length)
    {
        uint32_t count = 0;
        
        int writeResult = afc_file_write(afc, af, (const char *)data.bytes + bytesWritten, (uint32_t)data.length - bytesWritten, &count);
        if (writeResult != AFC_E_SUCCESS)
        {
            if (error)
            {
                NSLog(@"Failed writing file with error: %@ (%@ %@)", @(writeResult), fileURL, destinationURL);
                *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:@{NSURLErrorKey: destinationURL}];
            }
            
            success = NO;
            break;
        }
        
        bytesWritten += count;
    }
    
    if (bytesWritten != data.length)
    {
        if (error)
        {
            NSLog(@"Failed writing file due to mismatched sizes: %@ vs %@ (%@ %@)", @(bytesWritten), @(data.length), fileURL, destinationURL);
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:@{NSURLErrorKey: destinationURL}];
        }
        
        success = NO;
    }
    
    afc_file_close(afc, af);
    
    return success;
}
@end
