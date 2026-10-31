#import "include/BBCNativeMessaging.h"
#import <CommonCrypto/CommonHMAC.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <pthread.h>

static pthread_mutex_t SendLock = PTHREAD_MUTEX_INITIALIZER;
static int Channel = -1;
static const NSUInteger Limit = 131072;
static NSMutableDictionary<NSString *,NSDictionary *> *Typing;

static NSString *Proof(NSData *secret, NSString *nonce, BOOL server) {
    NSData *input = [[NSString stringWithFormat:@"%@:%@:helper",server ? @"server" : @"client",nonce] dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256,secret.bytes,secret.length,input.bytes,input.length,digest);
    return [[NSData dataWithBytes:digest length:sizeof(digest)] base64EncodedStringWithOptions:0];
}
static BOOL Equal(NSString *a, NSString *b) {
    NSData *left = [a dataUsingEncoding:NSUTF8StringEncoding], *right = [b dataUsingEncoding:NSUTF8StringEncoding];
    if (left.length == 0 || left.length != right.length) return NO;
    const unsigned char *x = left.bytes, *y = right.bytes; unsigned char diff = 0;
    for (NSUInteger i = 0; i < left.length; i++) diff |= x[i] ^ y[i];
    return diff == 0;
}
static BOOL WriteFrame(NSDictionary *value) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if (!json || json.length > Limit) return NO;
    NSMutableData *frame = [json mutableCopy]; [frame appendBytes:"\n" length:1];
    pthread_mutex_lock(&SendLock);
    NSUInteger offset = 0;
    while (Channel >= 0 && offset < frame.length) {
        ssize_t count = write(Channel, (const char *)frame.bytes + offset, frame.length-offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        offset += count;
    }
    pthread_mutex_unlock(&SendLock);
    return offset == frame.length;
}
static NSDictionary *ReadFrame(int fd, NSMutableData *buffer) {
    while (YES) {
        const void *newline = buffer.length ? memchr(buffer.bytes,'\n',buffer.length) : NULL;
        if (newline) {
            NSUInteger end = (const char *)newline - (const char *)buffer.bytes;
            NSData *data = [buffer subdataWithRange:NSMakeRange(0,end)];
            [buffer replaceBytesInRange:NSMakeRange(0,end+1) withBytes:NULL length:0];
            id packet = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            return [packet isKindOfClass:NSDictionary.class] ? packet : nil;
        }
        unsigned char bytes[8192]; ssize_t count = read(fd,bytes,sizeof(bytes));
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0 || buffer.length + count > Limit) return nil;
        [buffer appendBytes:bytes length:count];
    }
}

static void Connect(NSString *token, int port) {
    @autoreleasepool {
        NSData *secret = [[NSData alloc] initWithBase64EncodedString:token options:0];
        if (secret.length != 32 || port < 1 || port > 65535) return;
        int fd = socket(AF_INET,SOCK_STREAM,0);
        if (fd < 0) return;
        int noSignal = 1; setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,sizeof(noSignal));
        struct timeval timeout = {.tv_sec=5,.tv_usec=0};
        setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
        setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
        struct sockaddr_in address = {.sin_len=sizeof(address),.sin_family=AF_INET,.sin_port=htons((uint16_t)port)};
        address.sin_addr.s_addr = inet_addr("127.0.0.1");
        if (connect(fd,(struct sockaddr *)&address,sizeof(address)) != 0) { close(fd); return; }
        pthread_mutex_lock(&SendLock); Channel = fd; pthread_mutex_unlock(&SendLock);
        NSMutableData *buffer = [NSMutableData data];
        NSDictionary *challenge = ReadFrame(fd,buffer);
        NSString *nonce = challenge[@"nonce"];
        if (![challenge[@"kind"] isEqual:@"challenge"] || ![nonce isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:nonce]) goto disconnected;
        if (!WriteFrame(@{@"kind":@"authenticate",@"role":@"helper",@"proof":Proof(secret,nonce,NO)})) goto disconnected;
        {
            NSDictionary *accepted = ReadFrame(fd,buffer);
            if (![accepted[@"kind"] isEqual:@"authenticated"] || ![accepted[@"proof"] isKindOfClass:NSString.class] || !Equal(accepted[@"proof"],Proof(secret,nonce,YES))) goto disconnected;
        }
        timeout.tv_sec = 0; setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
        dispatch_async(dispatch_get_main_queue(), ^{
            Typing = [NSMutableDictionary dictionary];
            WriteFrame(@{@"kind":@"hello",@"version":@1,@"capabilities":BBCNativeCapabilities(nil)});
        });
        while (YES) {
            @autoreleasepool {
                NSDictionary *packet = ReadFrame(fd,buffer);
                NSString *identifier = packet[@"id"];
                NSDictionary *request = packet[@"request"];
                if (![packet[@"kind"] isEqual:@"command"] || ![identifier isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:identifier] || ![request isKindOfClass:NSDictionary.class]) break;
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSString *method = request[@"method"], *chat = request[@"chat_guid"], *lease = request[@"typing_id"];
                    if (([method isEqual:@"typing.start"] || [method isEqual:@"typing.stop"]) &&
                        (![chat isKindOfClass:NSString.class] || ![lease isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:lease])) {
                        WriteFrame(@{@"kind":@"result",@"id":identifier,@"result":@{@"ok":@NO,@"uncertain":@NO,@"failure_code":@"native_invalid_typing_session"}});
                        return;
                    }
                    if ([method isEqual:@"typing.stop"] && ![Typing[chat][@"typing_id"] isEqual:lease]) {
                        WriteFrame(@{@"kind":@"result",@"id":identifier,@"result":@{@"ok":@YES,@"cleanup":@"confirmed",@"unchanged":@YES}});
                        return;
                    }
                    BBCNativePerform(request,nil,^(NSDictionary *result) {
                        if (([result[@"ok"] boolValue] || [result[@"uncertain"] boolValue]) && [chat isKindOfClass:NSString.class]) {
                            if ([method isEqual:@"typing.start"] && [lease isKindOfClass:NSString.class] && [[NSUUID alloc] initWithUUIDString:lease]) {
                                Typing[chat] = request;
                                double remaining = MIN(30,MAX(0,[request[@"deadline"] doubleValue]/1000.0-NSDate.date.timeIntervalSince1970));
                                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(remaining*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
                                    if (![Typing[chat][@"typing_id"] isEqual:lease]) return;
                                    [Typing removeObjectForKey:chat];
                                    NSMutableDictionary *stop = [request mutableCopy]; stop[@"method"] = @"typing.stop";
                                    BBCNativePerform(stop,nil,^(NSDictionary *value) {});
                                });
                            }
                            if ([method isEqual:@"typing.stop"]) [Typing removeObjectForKey:chat];
                        }
                        WriteFrame(@{@"kind":@"result",@"id":identifier,@"result":result});
                    });
                });
            }
        }
disconnected:
        pthread_mutex_lock(&SendLock); Channel = -1; close(fd); pthread_mutex_unlock(&SendLock);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray *owned = Typing.allValues; [Typing removeAllObjects];
            for (NSDictionary *request in owned) {
                NSMutableDictionary *stop = [request mutableCopy]; stop[@"method"] = @"typing.stop";
                BBCNativePerform(stop,nil,^(NSDictionary *result) {});
            }
        });
    }
}

__attribute__((constructor)) static void StartBBCBridge(void) {
    @autoreleasepool {
        if (getuid() == 0 || geteuid() != getuid() || ![NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.MobileSMS"]) return;
        const char *rawToken = getenv("BBC_BRIDGE_SECRET"), *rawPort = getenv("BBC_BRIDGE_PORT");
        if (!rawToken || !rawPort) return;
        NSString *token = [NSString stringWithUTF8String:rawToken];
        int port = atoi(rawPort);
        unsetenv("BBC_BRIDGE_SECRET"); unsetenv("BBC_BRIDGE_PORT");
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{ Connect(token,port); });
    }
}
