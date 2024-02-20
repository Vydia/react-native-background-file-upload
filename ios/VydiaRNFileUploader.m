#import <Foundation/Foundation.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <React/RCTEventEmitter.h>
#import <React/RCTBridgeModule.h>
#import <Photos/Photos.h>

#import "VydiaRNFileUploader.h"

@implementation VydiaRNFileUploader{
    unsigned long uploadId;
    NSMutableDictionary *_responsesData;
    NSURLSession *_urlSession;
    void (^backgroundSessionCompletionHandler)(void);
    BOOL isObserving;
}

RCT_EXPORT_MODULE();

static NSString *BACKGROUND_SESSION_ID = @"ReactNativeBackgroundUpload";
static VydiaRNFileUploader *sharedInstance;


+ (BOOL)requiresMainQueueSetup {
    return NO;
}

- (id)initPrivate {
    if (self = [super init]) {
        uploadId = 0;
        _responsesData = [NSMutableDictionary dictionary];
        _urlSession = nil;
        backgroundSessionCompletionHandler = nil;
        isObserving = NO;
    }
    return self;
}

// singleton access
+ (VydiaRNFileUploader*)sharedInstance {
    @synchronized(self) {
        if (sharedInstance == nil)
            sharedInstance = [[self alloc] initPrivate];
    }
    return sharedInstance;
}

-(id) init {
    return [VydiaRNFileUploader sharedInstance];
}

- (void)_sendEventWithName:(NSString *)eventName body:(id)body {

    // add a delay to give time to event listeners to be set up
    double delayInSeconds = 0.5;
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, delayInSeconds * NSEC_PER_SEC);

    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
        if (self->isObserving && self.bridge != nil) {
            [self sendEventWithName:eventName body:body];
        }
    });

}

- (NSArray<NSString *> *)supportedEvents {
    return @[
        @"RNFileUploader-progress",
        @"RNFileUploader-error",
        @"RNFileUploader-cancelled",
        @"RNFileUploader-completed",
        @"RNFileUploader-bgExpired"
    ];
}

- (void)startObserving {
    isObserving = YES;

    // JS side is ready to receive events; create the background url session if necessary
    // iOS will then deliver the tasks completed while the app was dead (if any)
//    double delayInSeconds = 0.5;
//    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, delayInSeconds * NSEC_PER_SEC);
//    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
//        NSLog(@"RNBU startObserving: recreate urlSession if necessary");
//        [self urlSession];
//    });

    // why was the delay even needed?
    //NSLog(@"RNBU startObserving: recreate urlSession if necessary");
    [self urlSession];
}

-(void)stopObserving {
    isObserving = NO;
}

- (void)setBackgroundSessionCompletionHandler:(void (^)(void))handler {
    @synchronized (self) {
        backgroundSessionCompletionHandler = handler;
        //NSLog(@"RNBU setBackgroundSessionCompletionHandler");
    }
}


/*
 Gets file information for the path specified.  Example valid path is: file:///var/mobile/Containers/Data/Application/3C8A0EFB-A316-45C0-A30A-761BF8CCF2F8/tmp/trim.A5F76017-14E9-4890-907E-36A045AF9436.MOV
 Returns an object such as: {mimeType: "video/quicktime", size: 2569900, exists: true, name: "trim.AF9A9225-FC37-416B-A25B-4EDB8275A625.MOV", extension: "MOV"}
 */
RCT_EXPORT_METHOD(getFileInfo:(NSString *)path resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject)
{
    @try {
        NSURL *fileUri = [NSURL URLWithString: path];
        NSString *pathWithoutProtocol = [fileUri path];
        NSString *name = [fileUri lastPathComponent];
        NSString *extension = [name pathExtension];
        bool exists = [[NSFileManager defaultManager] fileExistsAtPath:pathWithoutProtocol];
        NSMutableDictionary *params = [NSMutableDictionary dictionaryWithObjectsAndKeys: name, @"name", nil];
        [params setObject:extension forKey:@"extension"];
        [params setObject:[NSNumber numberWithBool:exists] forKey:@"exists"];

        if (exists)
        {
            [params setObject:[self guessMIMETypeFromFileName:name] forKey:@"mimeType"];
            NSError* error;
            NSDictionary<NSFileAttributeKey, id> *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:pathWithoutProtocol error:&error];
            if (error == nil)
            {
                unsigned long long fileSize = [attributes fileSize];
                [params setObject:[NSNumber numberWithLong:fileSize] forKey:@"size"];
            }
        }
        resolve(params);
    }
    @catch (NSException *exception) {
        reject(@"RN Uploader", exception.name, nil);
    }
}

/*
 Borrowed from http://stackoverflow.com/questions/2439020/wheres-the-iphone-mime-type-database
 */
- (NSString *)guessMIMETypeFromFileName: (NSString *)fileName {
    CFStringRef UTI = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (__bridge CFStringRef)[fileName pathExtension], NULL);
    CFStringRef MIMEType = UTTypeCopyPreferredTagWithClass(UTI, kUTTagClassMIMEType);

    if (UTI) {
        CFRelease(UTI);
    }

    if (!MIMEType) {
        return @"application/octet-stream";
    }

    NSString *dest = [NSString stringWithString:(__bridge NSString *)(MIMEType)];
    CFRelease(MIMEType);
    return dest;
}

/*
 Utility method to copy a PHAsset file into a local temp file, which can then be uploaded.
 */
- (void)copyAssetToFile: (NSString *)assetUrl completionHandler: (void(^)(NSString *__nullable tempFileUrl, NSError *__nullable error))completionHandler {
    NSURL *url = [NSURL URLWithString:assetUrl];
    PHAsset *asset = [PHAsset fetchAssetsWithALAssetURLs:@[url] options:nil].lastObject;
    if (!asset) {
        NSMutableDictionary* details = [NSMutableDictionary dictionary];
        [details setValue:@"Asset could not be fetched.  Are you missing permissions?" forKey:NSLocalizedDescriptionKey];
        completionHandler(nil,  [NSError errorWithDomain:@"RNUploader" code:5 userInfo:details]);
        return;
    }
    PHAssetResource *assetResource = [[PHAssetResource assetResourcesForAsset:asset] firstObject];
    NSString *pathToWrite = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    NSURL *pathUrl = [NSURL fileURLWithPath:pathToWrite];
    NSString *fileURI = pathUrl.absoluteString;

    PHAssetResourceRequestOptions *options = [PHAssetResourceRequestOptions new];
    options.networkAccessAllowed = YES;

    [[PHAssetResourceManager defaultManager] writeDataForAssetResource:assetResource toFile:pathUrl options:options completionHandler:^(NSError * _Nullable e) {
        if (e == nil) {
            completionHandler(fileURI, nil);
        }
        else {
            completionHandler(nil, e);
        }
    }];
}

/*
 * Starts a file upload.
 * Options are passed in as the first argument as a js hash:
 * {
 *   url: string.  url to post to.
 *   path: string.  path to the file on the device
 *   headers: hash of name/value header pairs
 * }
 *
 * Returns a promise with the string ID of the upload.
 */
RCT_EXPORT_METHOD(startUpload:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject)
{

    NSString *uploadUrl = options[@"url"];
    __block NSString *fileURI = options[@"path"] ?: @"";
    NSString *method = options[@"method"] ?: @"POST";
    NSString *uploadType = options[@"type"] ?: @"raw";
    NSString *fieldName = options[@"field"];
    NSString *customUploadId = options[@"customUploadId"];
    NSDictionary *headers = options[@"headers"];
    NSDictionary *parameters = options[@"parameters"];


    NSString *thisUploadId = customUploadId;

    if(!thisUploadId){
        @synchronized(self)
        {
            thisUploadId = [NSString stringWithFormat:@"%lu", uploadId++];

        }
    }


    @try {
        NSURL *requestUrl = [NSURL URLWithString: uploadUrl];
        if (requestUrl == nil) {
            @throw @"Request URL cannot be nil";
        }

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestUrl];
        [request setHTTPMethod: method];

        [headers enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull val, BOOL * _Nonnull stop) {
            if ([val respondsToSelector:@selector(stringValue)]) {
                val = [val stringValue];
            }
            if ([val isKindOfClass:[NSString class]]) {
                [request setValue:val forHTTPHeaderField:key];
            }
        }];


        // asset library files have to be copied over to a temp file.  they can't be uploaded directly
        if ([fileURI hasPrefix:@"assets-library"]) {
            dispatch_group_t group = dispatch_group_create();
            dispatch_group_enter(group);
            [self copyAssetToFile:fileURI completionHandler:^(NSString * _Nullable tempFileUrl, NSError * _Nullable error) {
                if (error) {
                    dispatch_group_leave(group);
                    reject(@"RN Uploader", @"Asset could not be copied to temp file.", nil);
                    return;
                }
                fileURI = tempFileUrl;
                dispatch_group_leave(group);
            }];
            dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        }

        NSURLSessionUploadTask *uploadTask;

        if ([uploadType isEqualToString:@"multipart"]) {
            NSString *uuidStr = [[NSUUID UUID] UUIDString];
            [request setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", uuidStr] forHTTPHeaderField:@"Content-Type"];

            NSData *httpBody = [self createBodyWithBoundary:uuidStr path:fileURI parameters: parameters fieldName:fieldName];

            [request setHTTPBody: httpBody];
            uploadTask = [[self urlSession] uploadTaskWithStreamedRequest:request];


        } else {
            if (parameters.count > 0) {
                reject(@"RN Uploader", @"Parameters supported only in multipart type", nil);
                return;
            }

            uploadTask = [[self urlSession] uploadTaskWithRequest:request fromFile:[NSURL URLWithString: fileURI]];
        }

        uploadTask.taskDescription = thisUploadId;
        //NSLog(@"RNBU will start upload %@", uploadTask.taskDescription);
        [uploadTask resume];
        resolve(uploadTask.taskDescription);
    }
    @catch (NSException *exception) {
        //NSLog(@"RNBU startUpload error: %@", exception);
        reject(@"RN Uploader", exception.name, nil);
    }
}

/*
 * Cancels file upload
 * Accepts upload ID as a first argument, this upload will be cancelled
 * Event "cancelled" will be fired when upload is cancelled.
 */
RCT_EXPORT_METHOD(cancelUpload: (NSString *)cancelUploadId resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject) {
    [_urlSession getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks, NSArray *downloadTasks) {
        for (NSURLSessionTask *uploadTask in uploadTasks) {
            if ([uploadTask.taskDescription isEqualToString:cancelUploadId]){
                // == checks if references are equal, while isEqualToString checks the string value
                [uploadTask cancel];
            }
        }
    }];
    resolve([NSNumber numberWithBool:YES]);
}


/*
 * Returns remaining allowed background time
 */
RCT_REMAP_METHOD(getRemainingBgTime, getRemainingBgTimeResolver:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject) {

    dispatch_sync(dispatch_get_main_queue(), ^(void){
        double time = [[UIApplication sharedApplication] backgroundTimeRemaining];
        //NSLog(@"Background xx time Remaining: %f", time);
        resolve([NSNumber numberWithDouble:time]);
    });
}

// Let the OS it can suspend, must be called after enqueing all requests
RCT_EXPORT_METHOD(canSuspendIfBackground) {
    //NSLog(@"RNBU canSuspendIfBackground");

    // run with delay to give JS some time
    double delayInSeconds = 0.2;
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, delayInSeconds * NSEC_PER_SEC);
    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
        @synchronized (self) {
            if (self->backgroundSessionCompletionHandler) {
                self->backgroundSessionCompletionHandler();
                //NSLog(@"RNBU did call backgroundSessionCompletionHandler (canSuspendIfBackground)");
                self->backgroundSessionCompletionHandler = nil;
            }
        }
    });
}

// requests / releases background task time to the OS
// returns task id
RCT_REMAP_METHOD(beginBackgroundTask, beginBackgroundTaskResolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject){

    __block NSUInteger taskId = UIBackgroundTaskInvalid;

    taskId = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        //NSLog(@"RNBU beginBackgroundTaskWithExpirationHandler id: %ul", taskId);

        // do not use the other send event cause it has a delay
        // always send expire event, even if task id is invalid
        if (self->isObserving && self.bridge != nil) {
            [self sendEventWithName:@"RNFileUploader-bgExpired" body:@{@"id": [NSNumber numberWithUnsignedLong:taskId]}];
        }

        if (taskId != UIBackgroundTaskInvalid){

            //double time = [[UIApplication sharedApplication] backgroundTimeRemaining];
            //NSLog(@"Background xx time Remaining: %f", time);

            // dispatch async so we give time to JS to finish
            // we have about 3-4 seconds
            double delayInSeconds = 0.7;
            dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, delayInSeconds * NSEC_PER_SEC);

            dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
                [[UIApplication sharedApplication] endBackgroundTask: taskId];
            });

        }
    }];

    //NSLog(@"RNBU beginBackgroundTask id: %ul", taskId);
    resolve([NSNumber numberWithUnsignedLong:taskId]);

}


RCT_EXPORT_METHOD(endBackgroundTask: (NSUInteger)taskId resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject){

    @try{
        if(taskId != UIBackgroundTaskInvalid){
            [[UIApplication sharedApplication] endBackgroundTask: taskId];
        }

        //NSLog(@"RNBU endBackgroundTask id: %ul", taskId);
        resolve([NSNumber numberWithBool:YES]);
    }
    @catch (NSException *exception) {
        //NSLog(@"RNBU endBackgroundTask error: %@", exception);
        reject(@"RN Uploader", exception.name, nil);
    }
}



- (NSData *)createBodyWithBoundary:(NSString *)boundary
                         path:(NSString *)path
                         parameters:(NSDictionary *)parameters
                         fieldName:(NSString *)fieldName {

    NSMutableData *httpBody = [NSMutableData data];



    [parameters enumerateKeysAndObjectsUsingBlock:^(NSString *parameterKey, NSString *parameterValue, BOOL *stop) {
        [httpBody appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
        [httpBody appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"\r\n\r\n", parameterKey] dataUsingEncoding:NSUTF8StringEncoding]];
        [httpBody appendData:[[NSString stringWithFormat:@"%@\r\n", parameterValue] dataUsingEncoding:NSUTF8StringEncoding]];
    }];


    // resolve path
    if ([path length] > 0){
        NSURL *fileUri = [NSURL URLWithString: path];
        NSString *pathWithoutProtocol = [fileUri path];

        NSData *data = [[NSFileManager defaultManager] contentsAtPath:pathWithoutProtocol];
        NSString *filename  = [path lastPathComponent];
        NSString *mimetype  = [self guessMIMETypeFromFileName:path];

        [httpBody appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
        [httpBody appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"; filename=\"%@\"\r\n", fieldName, filename] dataUsingEncoding:NSUTF8StringEncoding]];
        [httpBody appendData:[[NSString stringWithFormat:@"Content-Type: %@\r\n\r\n", mimetype] dataUsingEncoding:NSUTF8StringEncoding]];
        [httpBody appendData:data];
        [httpBody appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];

    }

    [httpBody appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];

    return httpBody;
}

- (NSURLSession *)urlSession {
    @synchronized (self) {
        if (_urlSession == nil) {
            NSURLSessionConfiguration *sessionConfiguration = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:BACKGROUND_SESSION_ID];

            // UPDATE: Enforce a timeout here because we will otherwise
            // not get errors if the server times out
            sessionConfiguration.timeoutIntervalForResource = 5 * 60;

            _urlSession = [NSURLSession sessionWithConfiguration:sessionConfiguration delegate:self delegateQueue:nil];
        }
    }

    return _urlSession;
}

#pragma NSURLSessionTaskDelegate

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    NSMutableDictionary *data = [NSMutableDictionary dictionaryWithObjectsAndKeys:task.taskDescription, @"id", nil];
    NSURLSessionDataTask *uploadTask = (NSURLSessionDataTask *)task;
    NSHTTPURLResponse *response = (NSHTTPURLResponse *)uploadTask.response;
    if (response != nil)
    {
        [data setObject:[NSNumber numberWithInteger:response.statusCode] forKey:@"responseCode"];
    }

    // add headers
    NSMutableDictionary *headers = [[NSMutableDictionary alloc] init];
    NSDictionary *respHeaders = response.allHeaderFields;
    for (NSString *key in respHeaders)
    {
        headers[[key lowercaseString]] = respHeaders[key];
    }
    [data setObject:headers forKey:@"responseHeaders"];

    // Add data that was collected earlier by the didReceiveData method
    NSMutableData *responseData = _responsesData[@(task.taskIdentifier)];
    if (responseData) {
        [_responsesData removeObjectForKey:@(task.taskIdentifier)];
        NSString *response = [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding];
        [data setObject:response forKey:@"responseBody"];
    } else {
        [data setObject:[NSNull null] forKey:@"responseBody"];
    }


    if (error == nil) {
        [self _sendEventWithName:@"RNFileUploader-completed" body:data];
        //NSLog(@"RNBU did complete upload %@", task.taskDescription);
    } else {
        [data setObject:error.localizedDescription forKey:@"error"];
        if (error.code == NSURLErrorCancelled) {
            [self _sendEventWithName:@"RNFileUploader-cancelled" body:data];
            //NSLog(@"RNBU did cancel upload %@", task.taskDescription);
        } else {
            [self _sendEventWithName:@"RNFileUploader-error" body:data];
            //NSLog(@"RNBU did error upload %@", task.taskDescription);
        }
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
   didSendBodyData:(int64_t)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
    float progress = -1;
    if (totalBytesExpectedToSend > 0) { // see documentation.  For unknown size it's -1 (NSURLSessionTransferSizeUnknown)
        progress = 100.0 * (float)totalBytesSent / (float)totalBytesExpectedToSend;
    }
    [self _sendEventWithName:@"RNFileUploader-progress" body:@{ @"id": task.taskDescription, @"progress": [NSNumber numberWithFloat:progress] }];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    if (!data.length) return;
    // Hold returned data so it can be picked up by the didCompleteWithError method later
    NSMutableData *responseData = _responsesData[@(dataTask.taskIdentifier)];
    if (!responseData) {
        responseData = [NSMutableData dataWithData:data];
        _responsesData[@(dataTask.taskIdentifier)] = responseData;
    } else {
        [responseData appendData:data];
    }
}


// this will allow the app *technically* to wake up, run some code
// and then sleep. We will set a very short timeout (less than 5 seconds)
// to call the completion handler if it wasn't called already
- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
    //NSLog(@"RNBU URLSessionDidFinishEventsForBackgroundURLSession");

    if (backgroundSessionCompletionHandler) {
        double delayInSeconds = 4;
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, delayInSeconds * NSEC_PER_SEC);
        dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
            @synchronized (self) {
                if (self->backgroundSessionCompletionHandler) {
                    self->backgroundSessionCompletionHandler();
                    //NSLog(@"RNBU did call backgroundSessionCompletionHandler (URLSessionDidFinishEventsForBackgroundURLSession)");
                    self->backgroundSessionCompletionHandler = nil;
                }
            }
        });
    }
}

@end
