////////////////////////////////////////////////////////////////////////////
//
// Copyright 2014-2015 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

@import AppSandboxFileAccess;

#import "RLMDocument.h"
#import "RLMBrowserConstants.h"
#import "RLMDynamicSchemaLoader.h"
#import "RLMRealmBrowserWindowController.h"

@interface RLMDocument ()

@property (nonatomic, strong) NSURL *securityScopedURL;

@property (nonatomic, copy) NSURL *syncURL;
@property (nonatomic, copy) NSURL *authServerURL;
@property (nonatomic, strong) RLMSyncCredential *credential;

@property (nonatomic, strong) RLMSyncUser *user;
@property (nonatomic, strong) RLMDynamicSchemaLoader *schemaLoader;

@end

@implementation RLMDocument

- (instancetype)initWithContentsOfURL:(NSURL *)absoluteURL ofType:(NSString *)typeName error:(NSError **)outError
{
    if (![typeName.lowercaseString isEqualToString:kRealmUTIIdentifier]) {
        return nil;
    }

    if (absoluteURL.isFileURL) {
        return [self initWithContentsOfFileURL:absoluteURL error:outError];
    } else {
        return [self initWithContentsOfSyncURL:absoluteURL credential:nil authServerURL:nil error:outError];
    }
}

- (instancetype)initWithContentsOfFileURL:(NSURL *)fileURL error:(NSError **)outError {
    if (![fileURL.pathExtension.lowercaseString isEqualToString:kRealmFileExtension]) {
        return nil;
    }

    BOOL isDir = NO;
    if (!([[NSFileManager defaultManager] fileExistsAtPath:fileURL.path isDirectory:&isDir] && isDir == NO)) {
        return nil;
    }

    NSURL *folderURL = fileURL.URLByDeletingLastPathComponent;

    self = [super init];

    if (self != nil) {
        self.fileURL = fileURL;

        // In case we're trying to open Realm file located in app's container directory there is no reason to ask access permissions
        if (![[NSFileManager defaultManager] isWritableFileAtPath:folderURL.path]) {
            [[AppSandboxFileAccess fileAccess] requestAccessPermissionsForFileURL:folderURL persistPermission:YES withBlock:^(NSURL *securityScopedFileURL, NSData *bookmarkData) {
                self.securityScopedURL = securityScopedFileURL;
            }];

            if (self.securityScopedURL == nil) {
                return nil;
            }
        }

        [self.securityScopedURL startAccessingSecurityScopedResource];

        self.presentedRealm = [[RLMRealmNode alloc] initWithFileURL:self.fileURL];

        if ([self.presentedRealm realmFileRequiresFormatUpgrade]) {
            self.state = RLMDocumentStateRequiresFormatUpgrade;
        } else {
            NSError *error;
            if (![self loadWithError:&error]) {
                if (error.code == RLMErrorFileAccess) {
                    self.state = RLMDocumentStateNeedsEncryptionKey;
                } else {
                    if (outError != nil) {
                        *outError = error;
                    }

                    return nil;
                }
            }
        }
    }

    return self;
}

- (instancetype)initWithContentsOfSyncURL:(NSURL *)syncURL credential:(RLMSyncCredential *)credential authServerURL:(NSURL *)authServerURL error:(NSError **)outError {
    self = [super init];

    if (self != nil) {
        self.syncURL = syncURL;

        if (authServerURL != nil) {
            self.authServerURL = authServerURL;
        } else {
            NSURLComponents *authServerURLComponents = [[NSURLComponents alloc] init];

            authServerURLComponents.scheme = [syncURL.scheme isEqualToString:kSecureRealmURLScheme] ? @"https" : @"http";
            authServerURLComponents.host = syncURL.host;
            authServerURLComponents.port = syncURL.port;

            self.authServerURL = authServerURLComponents.URL;
        }

        self.state = RLMDocumentStateNeedsValidCredential;

        if (credential != nil) {
            [self loadWithCredential:credential completionHandler:nil];
        }
    }

    return self;
}

- (void)dealloc {
    if (self.user.isValid) {
        [self.user logOut];
    }

    if (self.securityScopedURL != nil) {
        //In certain instances, RLMRealm's C++ destructor method will attempt to clean up
        //specific auxiliary files belonging to this realm file.
        //If the destructor call occurs after the access to the sandbox resource has been released here,
        //and it attempts to delete any files, RLMRealm will throw an exception.
        //Mac OS X apps only have a finite number of open sandbox resources at any given time, so while it's not necessary
        //to release them straight away, it is still good practice to do so eventually.
        //As such, this will release the handle a minute, after closing the document.
        NSURL *scopedURL = self.securityScopedURL;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [scopedURL stopAccessingSecurityScopedResource];
        });
    }
}

- (BOOL)loadByPerformingFormatUpgradeWithError:(NSError **)error {
    NSAssert(self.state == RLMDocumentStateRequiresFormatUpgrade, @"Invalid document state");

    return [self loadWithError:error];
}

- (BOOL)loadWithEncryptionKey:(NSData *)key error:(NSError **)error {
    NSAssert(self.state == RLMDocumentStateNeedsEncryptionKey, @"Invalid document state");

    self.presentedRealm.encryptionKey = key;

    return [self loadWithError:error];
}

- (void)loadWithCredential:(RLMSyncCredential *)credential completionHandler:(void (^)(NSError *error))completionHandler {
    // Workaround for access token auth, state will be set to RLMDocumentStateUnrecoverableError in case of invalid token
    NSAssert(self.state == RLMDocumentStateNeedsValidCredential || self.state == RLMDocumentStateUnrecoverableError, @"Invalid document state");

    completionHandler = completionHandler ?: ^(NSError *error) {};

    self.credential = credential;
    self.state = RLMDocumentStateLoadingSchema;

    [RLMSyncUser authenticateWithCredential:self.credential authServerURL:self.authServerURL onCompletion:^(RLMSyncUser *user, NSError *error) {
        if (user == nil) {
            self.state = RLMDocumentStateNeedsValidCredential;

            // FIXME: workaround for https://github.com/realm/realm-cocoa-private/issues/204
            if (error.code == RLMSyncErrorHTTPStatusCodeError && [[error.userInfo valueForKey:@"statusCode"] integerValue] == 400) {
                NSMutableDictionary *userInfo = [error.userInfo mutableCopy];

                [userInfo setValue:@"Invalid credentials." forKey:NSLocalizedDescriptionKey];
                [userInfo setValue:@"Please check your authentication credentials and that you have an access to the specified URL." forKey:NSLocalizedRecoverySuggestionErrorKey];

                NSError *authenticationError = [[NSError alloc] initWithDomain:error.domain code:error.code userInfo:userInfo];

                error = authenticationError;
            }

            completionHandler(error);
        } else {
            self.user = user;

            // FIXME: workaround for loading schema while using dynamic API
            self.schemaLoader = [[RLMDynamicSchemaLoader alloc] initWithSyncURL:self.syncURL user:self.user];

            [self.schemaLoader loadSchemaWithCompletionHandler:^(NSError *error) {
                self.schemaLoader = nil;

                if (error == nil) {
                    self.presentedRealm = [[RLMRealmNode alloc] initWithSyncURL:self.syncURL user:self.user];

                    [self loadWithError:&error];
                } else {
                    self.state = RLMDocumentStateUnrecoverableError;
                }
                
                completionHandler(error);
            }];
        }
    }];
}

- (BOOL)loadWithError:(NSError **)error {
    NSAssert(self.presentedRealm != nil, @"Presented Realm must be created before loading");

    BOOL result = [self.presentedRealm connect:error];

    self.state = result ? RLMDocumentStateLoaded : RLMDocumentStateUnrecoverableError;

    return result;
}

#pragma mark NSDocument overrides

- (void)makeWindowControllers
{
    RLMRealmBrowserWindowController *windowController = [[RLMRealmBrowserWindowController alloc] initWithWindowNibName:self.windowNibName];
    [self addWindowController:windowController];
}

- (NSString *)windowNibName
{
    return @"RLMDocument";
}

- (NSData *)dataOfType:(NSString *)typeName error:(NSError **)outError
{
    // As we do not use the usual file handling mechanism we just returns nil (but it is necessary
    // to override this method as the default implementation throws an exception.
    return nil;
}

- (BOOL)readFromData:(NSData *)data ofType:(NSString *)typeName error:(NSError **)outError
{
    // As we do not use the usual file handling mechanism we just returns YES (but it is necessary
    // to override this method as the default implementation throws an exception.
    return YES;
}

- (NSString *)displayName
{
    return self.syncURL ? self.syncURL.absoluteString : self.fileURL.lastPathComponent.stringByDeletingPathExtension;
}

@end
