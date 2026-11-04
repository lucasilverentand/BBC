#import "include/BBCNativeMessaging.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#import <math.h>

// Only hard-coded selectors reach this function. IPC never exposes invocation.
static id Invoke(id receiver, NSString *name, NSArray *arguments) {
    SEL selector = NSSelectorFromString(name);
    NSMethodSignature *signature = [receiver methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != arguments.count + 2) {
        @throw [NSException exceptionWithName:@"BBCUnsupported" reason:nil userInfo:nil];
    }
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = receiver;
    invocation.selector = selector;
    for (NSUInteger index = 0; index < arguments.count; index++) {
        const char *type = [signature getArgumentTypeAtIndex:index + 2];
        id argument = arguments[index] == NSNull.null ? nil : arguments[index];
        if (type[0] == '@') { [invocation setArgument:&argument atIndex:index + 2]; }
        else if ((type[0] == 'B' || type[0] == 'c') && [argument isKindOfClass:NSNumber.class]) {
            BOOL value = [argument boolValue]; [invocation setArgument:&value atIndex:index + 2];
        } else if (type[0] == 'q' && [argument isKindOfClass:NSNumber.class]) {
            long long value = [argument longLongValue]; [invocation setArgument:&value atIndex:index + 2];
        } else if (type[0] == 'Q' && [argument isKindOfClass:NSNumber.class]) {
            unsigned long long value = [argument unsignedLongLongValue]; [invocation setArgument:&value atIndex:index + 2];
        } else if (strcmp(type, @encode(NSRange)) == 0 && [argument isKindOfClass:NSValue.class]) {
            NSRange value = [argument rangeValue]; [invocation setArgument:&value atIndex:index + 2];
        } else { @throw [NSException exceptionWithName:@"BBCUnsupported" reason:nil userInfo:nil]; }
    }
    [invocation retainArguments];
    [invocation invoke];
    if (signature.methodReturnType[0] == 'v') return NSNull.null;
    if (signature.methodReturnType[0] == '@') {
        __unsafe_unretained id value = nil;
        [invocation getReturnValue:&value];
        return value;
    }
    if (signature.methodReturnType[0] == 'B' || signature.methodReturnType[0] == 'c') { BOOL value = NO; [invocation getReturnValue:&value]; return @(value); }
    if (signature.methodReturnType[0] == 'q') { long long value = 0; [invocation getReturnValue:&value]; return @(value); }
    if (strcmp(signature.methodReturnType, @encode(NSRange)) == 0) { NSRange value; [invocation getReturnValue:&value]; return [NSValue valueWithRange:value]; }
    @throw [NSException exceptionWithName:@"BBCUnsupported" reason:nil userInfo:nil];
}

static Class Resolve(NSString *name, BBCNativeClassResolver resolver) { return resolver ? resolver(name) : NSClassFromString(name); }
static BOOL Has(id receiver, NSString *selector) { return receiver && [receiver respondsToSelector:NSSelectorFromString(selector)]; }
static NSDictionary *Failure(NSString *code, BOOL uncertain) { return @{@"ok":@NO, @"failure_code":code, @"uncertain":@(uncertain)}; }
static BOOL Text(id value, NSUInteger maximum) { return [value isKindOfClass:NSString.class] && [value length] > 0 && [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= maximum; }
static BOOL UUIDText(id value) { return [value isKindOfClass:NSString.class] && [[NSUUID alloc] initWithUUIDString:value] != nil; }
static NSString *const MessageInitializer = @"initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:threadIdentifier:";
static NSString *const ReactionFactory = @"initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:associatedMessageGUID:associatedMessageType:associatedMessageRange:messageSummaryInfo:";
static NSArray<NSString *> *AdvancedMethods(void) {
    return @[@"groups.create",@"groups.add",@"groups.remove",@"groups.name",@"groups.photo",@"groups.leave",@"messages.edit",@"messages.unsend",@"messages.multipart",@"availability"];
}
static NSArray<NSString *> *AdvancedCapabilities(BBCNativeClassResolver resolver);
static void PerformAdvanced(NSDictionary *request, BBCNativeClassResolver resolver, BBCNativeCompletion completion);

static NSDictionary *Pending(NSDictionary *identity) {
    NSMutableDictionary *value = [identity mutableCopy];
    [value addEntriesFromDictionary:@{@"accepted":@YES,@"uncertain":@YES,@"native_confirmation":@"pending",@"confirmation":@"native-call"}];
    return value;
}
static void Observe(BOOL (^predicate)(void), NSDictionary *identity, double deadline, BBCNativeCompletion completion) {
    @try {
        if (predicate()) {
            NSMutableDictionary *value = [identity mutableCopy];
            [value addEntriesFromDictionary:@{@"ok":@YES,@"confirmation":@"native-state"}];
            completion(value); return;
        }
    } @catch (NSException *exception) { completion(Pending(identity)); return; }
    if (NSDate.date.timeIntervalSince1970 >= deadline) { completion(Pending(identity)); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ Observe(predicate,identity,deadline,completion); });
}

// The public API targets the first native part. Reject ambiguous native parts
// rather than guessing a range from the plain-text database representation.
static id FirstPart(id message) {
    id item = Invoke(message,@"_imMessageItem",@[]);
    id parts = Invoke(item,@"_newChatItems",@[]);
    NSArray *candidates = [parts isKindOfClass:NSArray.class] ? parts : (parts ? @[parts] : @[]);
    id part = nil;
    for (id candidate in candidates) {
        if (Has(candidate,@"messagePartRange") && Has(candidate,@"index") && [Invoke(candidate,@"index",@[]) integerValue] == 0) {
            if (part) return nil;
            part = candidate;
        }
    }
    return part;
}

NSArray<NSString *> *BBCNativeCapabilities(BBCNativeClassResolver resolver) {
    Class registry = Resolve(@"IMChatRegistry", resolver), message = Resolve(@"IMMessage", resolver), chat = Resolve(@"IMChat", resolver);
    if (!Has(registry, @"sharedInstance")) return @[];
    NSMutableArray *features = [NSMutableArray array];
    if ([chat instancesRespondToSelector:NSSelectorFromString(@"markAllMessagesAsRead")]) [features addObject:@"read"];
    if ([chat instancesRespondToSelector:NSSelectorFromString(@"setLocalUserIsTyping:")]) [features addObject:@"typing"];
    BOOL canSend = [chat instancesRespondToSelector:NSSelectorFromString(@"sendMessage:onService:")] && Has(Resolve(@"IMService",resolver),@"iMessageService");
    if (canSend && [message instancesRespondToSelector:NSSelectorFromString(MessageInitializer)]) [features addObject:@"reply"];
    if (canSend && [message instancesRespondToSelector:NSSelectorFromString(ReactionFactory)]) {
        [features addObject:@"tapback"];
        if ([message instancesRespondToSelector:NSSelectorFromString(@"_associatedMessageEmoji:")]) [features addObject:@"custom-emoji"];
    }
    Class detector = Resolve(@"IMDDController", resolver);
    if (canSend && [message instancesRespondToSelector:NSSelectorFromString(MessageInitializer)] && Has(detector, @"sharedInstance") && [detector instancesRespondToSelector:NSSelectorFromString(@"scanMessage:outgoing:waitUntilDone:completionBlock:")]) [features addObject:@"link"];
    [features addObjectsFromArray:AdvancedCapabilities(resolver)];
    return features;
}

static void PerformWithMessageLoad(NSDictionary *request, BBCNativeClassResolver resolver, BOOL loadRequested, double loadDeadline, double scanTimeout, BBCNativeCompletion completion) {
    if ([AdvancedMethods() containsObject:request[@"method"] ?: NSNull.null]) { PerformAdvanced(request,resolver,completion); return; }
    __block BOOL attempted = NO;
    @try {
        NSString *method = request[@"method"], *chatID = request[@"chat_guid"], *targetID = request[@"message_guid"];
        if (![method isKindOfClass:NSString.class] || ![@[@"tapback",@"reply",@"link",@"read",@"typing.start",@"typing.stop"] containsObject:method] ||
            !Text(chatID,512) || !([chatID hasPrefix:@"any;-;"] || [chatID hasPrefix:@"iMessage;-;"]) || !UUIDText(targetID)) {
            completion(Failure(@"native_invalid_request",NO)); return;
        }
        id registry = Invoke(Resolve(@"IMChatRegistry", resolver), @"sharedInstance", @[]);
        id chat = Invoke(registry, @"existingChatWithGUID:", @[chatID]);
        if (!chat || ![Invoke(chat,@"guid",@[]) isEqual:chatID]) { completion(Failure(@"native_chat_missing",NO)); return; }
        // Owned lease cleanup must survive eviction of its anchor message.
        BOOL stoppingTyping = [method isEqual:@"typing.stop"];
        id target = stoppingTyping ? nil : Invoke(chat, @"messageForGUID:", @[targetID]);
        if (!target && !stoppingTyping) {
            BOOL waitForTapback = [method isEqual:@"tapback"];
            if (!loadRequested) {
                NSNumber *window = waitForTapback ? @1 : @0;
                Invoke(chat,@"loadMessagesBeforeAndAfterGUID:numberOfMessagesToLoadBeforeGUID:numberOfMessagesToLoadAfterGUID:loadImmediately:threadIdentifier:",@[targetID,window,window,@YES,NSNull.null]);
                loadRequested = YES;
                loadDeadline = NSDate.date.timeIntervalSince1970 + 5;
            }
            target = Invoke(chat,@"messageForGUID:",@[targetID]);
            if (waitForTapback && !target && NSDate.date.timeIntervalSince1970 < loadDeadline) {
                // Loading may complete asynchronously on Messages' main queue.
                // Request it once, then observe the exact target before any
                // mutation. There is only one continuation and one dispatch.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
                    PerformWithMessageLoad(request,resolver,YES,loadDeadline,scanTimeout,completion);
                });
                return;
            }
        }
        if (!stoppingTyping && (!target || ![Invoke(target,@"guid",@[]) isEqual:targetID])) { completion(Failure(@"native_message_missing",NO)); return; }
        if ([method isEqual:@"typing.start"] || [method isEqual:@"typing.stop"]) {
            if (!UUIDText(request[@"typing_id"])) { completion(Failure(@"native_invalid_typing_session",NO)); return; }
            if ([method isEqual:@"typing.start"]) {
                double deadline = [request[@"deadline"] isKindOfClass:NSNumber.class] ? [request[@"deadline"] doubleValue]/1000.0 : 0;
                double now = NSDate.date.timeIntervalSince1970;
                if (!isfinite(deadline) || deadline <= now || deadline > now+31) { completion(Failure(@"native_typing_expired",NO)); return; }
            }
            attempted = YES;
            Invoke(chat,@"setLocalUserIsTyping:",@[@([method isEqual:@"typing.start"])]);
            if ([Invoke(chat,@"localUserIsTyping",@[]) boolValue] != [method isEqual:@"typing.start"]) { completion(Failure(@"native_typing_unconfirmed",YES)); return; }
            completion(@{@"ok":@YES,@"confirmation":@"native-state"}); return;
        }
        if ([method isEqual:@"read"]) {
            attempted = YES; Invoke(chat,@"markAllMessagesAsRead",@[]);
            completion(@{@"ok":@YES,@"confirmation":@"native-call"}); return;
        }
        Class messageClass = Resolve(@"IMMessage",resolver);
        id service = Invoke(Resolve(@"IMService",resolver),@"iMessageService",@[]);
        if (!service || !Has(chat,@"sendMessage:onService:")) { completion(Failure(@"native_imessage_unavailable",NO)); return; }
        id message = nil;
        if ([method isEqual:@"tapback"]) {
            NSString *reaction = request[@"reaction"];
            NSArray *classic = @[@"love",@"like",@"dislike",@"laugh",@"emphasis",@"question"];
            NSUInteger index = [classic indexOfObject:reaction];
            BOOL custom = index == NSNotFound, remove = [request[@"remove"] boolValue];
            if (!Text(reaction,128) || (custom && [reaction rangeOfComposedCharacterSequenceAtIndex:0].length != reaction.length)) {
                completion(Failure(@"native_invalid_reaction",NO)); return;
            }
            long long type = (remove ? 3000 : 2000) + (custom ? 6 : (long long)index);
            NSString *reference = request[@"associated_message_guid"];
            NSString *partReference = [@"p:0/" stringByAppendingString:targetID];
            NSString *balloonReference = [@"bp:" stringByAppendingString:targetID];
            if (![reference isEqual:partReference] && ![reference isEqual:balloonReference]) { completion(Failure(@"native_invalid_reference",NO)); return; }
            id part = FirstPart(target);
            if (!part) { completion(Failure(@"native_part_unavailable",NO)); return; }
            id range = Invoke(part,@"messagePartRange",@[]);
            id summary = Invoke(part,@"messageSummaryInfo",@[]) ?: @{};
            if (![summary isKindOfClass:NSDictionary.class]) { completion(Failure(@"native_part_unavailable",NO)); return; }
            NSString *fallback = [NSString stringWithFormat:@"%@ %@ to a message",remove ? @"Removed" : @"Reacted",reaction];
            NSAttributedString *body = [[NSAttributedString alloc] initWithString:fallback];
            message = Invoke([messageClass alloc], ReactionFactory, @[NSNull.null,NSNull.null,body,NSNull.null,NSNull.null,@5,NSNull.null,NSUUID.UUID.UUIDString,NSNull.null,reference,@(type),range,summary]);
            if (custom) {
                Invoke(message,@"_associatedMessageEmoji:",@[reaction]);
                if (![Invoke(message,@"associatedMessageEmoji",@[]) isEqual:reaction]) { completion(Failure(@"native_emoji_unconfirmed",NO)); return; }
            }
        } else {
            NSString *text = request[@"text"];
            if (!Text(text,64000)) { completion(Failure(@"native_invalid_text",NO)); return; }
            id thread = NSNull.null;
            if ([method isEqual:@"reply"]) {
                thread = Invoke(target,@"threadIdentifier",@[]) ?: NSNull.null;
                if (thread == NSNull.null || [thread length] == 0) {
                    id part = FirstPart(target);
                    NSString *(*makeThread)(id) = dlsym(RTLD_DEFAULT,"IMCreateThreadIdentifierForMessagePartChatItem");
                    if (!part || !makeThread || resolver) { completion(Failure(@"native_thread_unavailable",NO)); return; }
                    thread = makeThread(part);
                    if (!Text(thread,512)) { completion(Failure(@"native_thread_unavailable",NO)); return; }
                }
            }
            message = Invoke([messageClass alloc],MessageInitializer,@[NSNull.null,NSNull.null,[[NSAttributedString alloc] initWithString:text],NSNull.null,NSNull.null,@(0x100005),NSNull.null,NSUUID.UUID.UUIDString,NSNull.null,thread]);
        }
        if (!message) { completion(Failure(@"native_message_creation_failed",NO)); return; }
        if ([method isEqual:@"link"]) {
            id detector = Invoke(Resolve(@"IMDDController",resolver),@"sharedInstance",@[]);
            // A callback can arrive more than once. Dispatch at most one send.
            __block BOOL finished = NO;
            // Finish before the broker's 24-second deadline. Check the monotonic
            // clock in the callback too: a blocked main queue can delay timers.
            double scanDeadline = NSProcessInfo.processInfo.systemUptime + scanTimeout;
            void (^expire)(void) = ^{
                if (finished) return;
                finished = YES;
                completion(Failure(@"native_link_scan_timeout",NO));
            };
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(scanTimeout*NSEC_PER_SEC)),dispatch_get_main_queue(),expire);
            void (^scanned)(NSInteger,BOOL,id) = ^(NSInteger status, BOOL success, id result) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (finished) return;
                    if (NSProcessInfo.processInfo.systemUptime >= scanDeadline) { expire(); return; }
                    finished = YES;
                    @try {
                        Invoke(chat,@"sendMessage:onService:",@[message,service]);
                        id guid = Invoke(message,@"guid",@[]);
                        completion(UUIDText(guid) ? @{@"ok":@YES,@"guid":guid,@"confirmation":@"native-call"} : Failure(@"native_guid_unconfirmed",YES));
                    } @catch (NSException *exception) { completion(Failure(@"native_send_unconfirmed",YES)); }
                });
            };
            @try {
                Invoke(detector,@"scanMessage:outgoing:waitUntilDone:completionBlock:",@[message,@YES,@YES,[scanned copy]]);
            } @catch (NSException *exception) {
                // A scanner may queue its callback before throwing. Cancel
                // that queued send before returning a not-dispatched failure.
                if (!finished) {
                    finished = YES;
                    completion(Failure(@"native_link_scan_failed",NO));
                }
            }
            return;
        }
        attempted = YES;
        Invoke(chat,@"sendMessage:onService:",@[message,service]);
        id guid = Invoke(message,@"guid",@[]);
        completion(UUIDText(guid) ? @{@"ok":@YES,@"guid":guid,@"confirmation":@"native-call"} : Failure(@"native_guid_unconfirmed",YES));
    } @catch (NSException *exception) {
        completion(Failure([exception.name isEqual:@"BBCUnsupported"] ? @"native_selector_unavailable" : @"native_exception",attempted));
    }
}

void BBCNativePerform(NSDictionary *request, BBCNativeClassResolver resolver, BBCNativeCompletion completion) {
    BBCNativePerformWithScanTimeout(request,resolver,10,completion);
}

void BBCNativePerformWithScanTimeout(NSDictionary *request, BBCNativeClassResolver resolver, double scanTimeout, BBCNativeCompletion completion) {
    if (!isfinite(scanTimeout) || scanTimeout <= 0 || scanTimeout > 10) { completion(Failure(@"native_invalid_scan_timeout",NO)); return; }
    PerformWithMessageLoad(request,resolver,NO,0,scanTimeout,completion);
}

static BOOL Address(id value) {
    if (!Text(value,254) || strlen([value UTF8String]) != [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) return NO;
    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"^(\\+[1-9][0-9]{6,14}|[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+)$" options:0 error:nil];
    return [pattern numberOfMatchesInString:value options:0 range:NSMakeRange(0,[value length])] == 1;
}
static BOOL ChatIdentity(id value) {
    return Text(value,512) && ([value hasPrefix:@"any;-;"] || [value hasPrefix:@"iMessage;-;"] || [value hasPrefix:@"any;+;"] || [value hasPrefix:@"iMessage;+;"]);
}
static BOOL InstanceHas(Class cls, NSString *selector) { return [cls instancesRespondToSelector:NSSelectorFromString(selector)]; }
static NSString *NativeAttribute(NSString *symbol, BBCNativeClassResolver resolver) {
    // Synthetic fixtures use their own attribute namespace without loading
    // IMCore. Production uses the exported NSString value, not the symbol name.
    if (resolver) return [@"__k" stringByAppendingString:symbol];
    NSString * __unsafe_unretained *value = (NSString * __unsafe_unretained *)dlsym(RTLD_DEFAULT,symbol.UTF8String);
    return value && [*value isKindOfClass:NSString.class] && [*value length] > 0 ? *value : nil;
}
static NSString *const EditSelector = @"editMessageItem:atPartIndex:withNewPartText:newPartTranslation:backwardCompatabilityText:";
static NSString *const NewGroupSelector = @"chatWithHandles:displayName:joinedChatsOnly:findMatchingNamedGroups:lastAddressedHandle:lastAddressedSIMID:needsFreshGroupCreation:";
static NSArray<NSString *> *AdvancedCapabilities(BBCNativeClassResolver resolver) {
    Class chat = Resolve(@"IMChat",resolver), registry = Resolve(@"IMChatRegistry",resolver), account = Resolve(@"IMAccountController",resolver);
    Class center = Resolve(@"IMFileTransferCenter",resolver);
    NSMutableArray *features = [NSMutableArray array];
    BOOL handles = Has(account,@"sharedInstance") && InstanceHas(account,@"activeIMessageAccount");
    if (handles && InstanceHas(registry,NewGroupSelector)) [features addObject:@"groups.create"];
    if (handles && InstanceHas(chat,@"canAddParticipants:") && InstanceHas(chat,@"inviteParticipants:reason:")) [features addObject:@"groups.add"];
    if (handles && InstanceHas(chat,@"canRemoveParticipants:") && InstanceHas(chat,@"removeParticipants:reason:")) [features addObject:@"groups.remove"];
    if (InstanceHas(chat,@"_setDisplayName:")) [features addObject:@"groups.name"];
    if (Has(center,@"sharedInstance") && InstanceHas(center,@"createNewOutgoingGroupPhotoTransferWithLocalFileURL:") && InstanceHas(chat,@"sendGroupPhotoUpdate:")) [features addObject:@"groups.photo"];
    if (InstanceHas(chat,@"canLeaveChat") && InstanceHas(chat,@"hasLeftGroup") && InstanceHas(chat,@"leave")) [features addObject:@"groups.leave"];
    if (InstanceHas(chat,EditSelector)) [features addObject:@"messages.edit"];
    if (InstanceHas(chat,@"retractMessagePart:")) [features addObject:@"messages.unsend"];
    if (Has(center,@"sharedInstance") && InstanceHas(center,@"createNewOutgoingTransferWithLocalFileURL:") && InstanceHas(Resolve(@"IMMessage",resolver),MessageInitializer) && InstanceHas(chat,@"sendMessage:onService:") && Has(Resolve(@"IMService",resolver),@"iMessageService") &&
        NativeAttribute(@"IMMessagePartAttributeName",resolver) && NativeAttribute(@"IMFileTransferGUIDAttributeName",resolver) && NativeAttribute(@"IMFilenameAttributeName",resolver)) [features addObject:@"messages.multipart"];
    Class query = Resolve(@"IDSIDQueryController",resolver);
    if (Has(query,@"sharedInstance") && InstanceHas(query,@"forceRefreshIDStatusForDestinations:service:listenerID:queue:completionBlock:")) [features addObject:@"availability"];
    return features;
}

static NSArray *Handles(NSArray *addresses, BBCNativeClassResolver resolver) {
    if (![addresses isKindOfClass:NSArray.class] || addresses.count == 0 || addresses.count > 32 || [NSSet setWithArray:addresses].count != addresses.count) return nil;
    id account = Invoke(Invoke(Resolve(@"IMAccountController",resolver),@"sharedInstance",@[]),@"activeIMessageAccount",@[]);
    NSMutableArray *handles = [NSMutableArray array];
    for (id address in addresses) {
        if (!Address(address)) return nil;
        id handle = Invoke(account,@"imHandleWithID:",@[address]);
        if (!handle) return nil;
        [handles addObject:handle];
    }
    return handles;
}
static id MessageInChat(id chat, NSString *guid) {
    id message = Invoke(chat,@"messageForGUID:",@[guid]);
    if (!message) {
        Invoke(chat,@"loadMessagesBeforeAndAfterGUID:numberOfMessagesToLoadBeforeGUID:numberOfMessagesToLoadAfterGUID:loadImmediately:threadIdentifier:",@[guid,@0,@0,@YES,NSNull.null]);
        message = Invoke(chat,@"messageForGUID:",@[guid]);
    }
    return message && [Invoke(message,@"guid",@[]) isEqual:guid] ? message : nil;
}
static id PartAtIndex(id message, NSInteger index) {
    id raw = Invoke(Invoke(message,@"_imMessageItem",@[]),@"_newChatItems",@[]);
    NSMutableArray *remaining = [NSMutableArray arrayWithArray:[raw isKindOfClass:NSArray.class] ? raw : (raw ? @[raw] : @[])];
    id selected = nil;
    for (NSUInteger cursor = 0; cursor < remaining.count && cursor < 64; cursor++) {
        id part = remaining[cursor];
        if (Has(part,@"aggregateAttachmentParts")) {
            id children = Invoke(part,@"aggregateAttachmentParts",@[]);
            if (![children isKindOfClass:NSArray.class] || remaining.count + [children count] > 64) return nil;
            [remaining addObjectsFromArray:children];
            continue;
        }
        if (Has(part,@"index") && [Invoke(part,@"index",@[]) integerValue] == index) {
            if (selected) return nil;
            selected = part;
        }
    }
    return selected;
}
static id Transfer(NSString *path, BOOL groupPhoto, BBCNativeClassResolver resolver) {
    // The authenticated BBC worker supplies only a validated private handoff.
    // Public API requests cannot supply paths or a native transfer GUID.
    if (!Text(path,4096) || ![path isAbsolutePath] || ![path.lastPathComponent containsString:@"."]) return nil;
    id center = Invoke(Resolve(@"IMFileTransferCenter",resolver),@"sharedInstance",@[]);
    id transfer = Invoke(center,groupPhoto ? @"createNewOutgoingGroupPhotoTransferWithLocalFileURL:" : @"createNewOutgoingTransferWithLocalFileURL:",@[[NSURL fileURLWithPath:path]]);
    return transfer && Text(Invoke(transfer,@"guid",@[]),256) ? transfer : nil;
}

static void PerformAdvanced(NSDictionary *request, BBCNativeClassResolver resolver, BBCNativeCompletion completion) {
    __block BOOL attempted = NO;
    @try {
        NSString *method = request[@"method"];
        if (![AdvancedCapabilities(resolver) containsObject:method]) { completion(Failure(@"native_capability_unavailable",NO)); return; }
        if ([method isEqual:@"availability"]) {
            NSString *address = request[@"address"];
            if (!Address(address)) { completion(Failure(@"native_invalid_address",NO)); return; }
            CFTypeRef (*makeDestination)(CFStringRef) = dlsym(RTLD_DEFAULT,[address hasPrefix:@"+"] ? "IDSCopyIDForPhoneNumber" : "IDSCopyIDForEmailAddress");
            NSString * __unsafe_unretained *serviceName = (NSString * __unsafe_unretained *)dlsym(RTLD_DEFAULT,"IDSServiceNameiMessage");
            if (!makeDestination || !serviceName || !*serviceName || resolver) { completion(Failure(@"native_availability_unavailable",NO)); return; }
            id destination = CFBridgingRelease(makeDestination((__bridge CFStringRef)address));
            if (!destination) { completion(Failure(@"native_availability_unavailable",NO)); return; }
            __block BOOL finished = NO;
            void (^callback)(NSDictionary *) = ^(NSDictionary *statuses) {
                dispatch_async(dispatch_get_main_queue(),^{
                    if (finished) return; finished = YES;
                    id status = [statuses isKindOfClass:NSDictionary.class] && statuses.count == 1 ? statuses.allValues.firstObject : nil;
                    if (![status isKindOfClass:NSNumber.class]) { completion(Failure(@"native_availability_unknown",NO)); return; }
                    NSInteger code = [status integerValue];
                    completion(@{@"ok":@YES,@"available":code == 1 ? @YES : (code == 2 ? @NO : NSNull.null),@"status":code == 1 ? @"available" : (code == 2 ? @"unavailable" : @"unknown"),@"confirmation":@"native-query"});
                });
            };
            id query = Invoke(Resolve(@"IDSIDQueryController",resolver),@"sharedInstance",@[]);
            BOOL accepted = [Invoke(query,@"forceRefreshIDStatusForDestinations:service:listenerID:queue:completionBlock:",@[@[destination],*serviceName,@"club.bluebubble.availability",dispatch_get_main_queue(),[callback copy]]) boolValue];
            if (!accepted) { finished = YES; completion(Failure(@"native_availability_unavailable",NO)); }
            return;
        }
        id registry = Invoke(Resolve(@"IMChatRegistry",resolver),@"sharedInstance",@[]);
        if ([method isEqual:@"groups.create"]) {
            NSArray *handles = Handles(request[@"participants"],resolver);
            if (handles.count < 2) { completion(Failure(@"native_invalid_participants",NO)); return; }
            id name = request[@"name"] ?: NSNull.null;
            if (name != NSNull.null && !Text(name,256)) { completion(Failure(@"native_invalid_group_name",NO)); return; }
            attempted = YES;
            id chat = Invoke(registry,NewGroupSelector,@[handles,name,@NO,@NO,NSNull.null,NSNull.null,@YES]);
            id guid = Invoke(chat,@"guid",@[]);
            if (!ChatIdentity(guid) || ![guid containsString:@";+;"]) { completion(Failure(@"native_group_unconfirmed",YES)); return; }
            Observe(^BOOL{
                id raw = Invoke(chat,@"participantHandleIDs",@[]);
                NSSet *actual = [raw isKindOfClass:NSArray.class] ? [NSSet setWithArray:raw] : raw;
                return [actual isKindOfClass:NSSet.class] && [actual isEqual:[NSSet setWithArray:request[@"participants"]]] && [Invoke(chat,@"_isiMessageService",@[]) boolValue];
            },@{@"chat_guid":guid},NSDate.date.timeIntervalSince1970+3,completion); return;
        }
        NSString *chatID = request[@"chat_guid"];
        if (!ChatIdentity(chatID)) { completion(Failure(@"native_invalid_chat",NO)); return; }
        id chat = Invoke(registry,@"existingChatWithGUID:",@[chatID]);
        if (!chat || ![Invoke(chat,@"guid",@[]) isEqual:chatID] || ![Invoke(chat,@"_isiMessageService",@[]) boolValue]) { completion(Failure(@"native_chat_missing",NO)); return; }
        if ([method hasPrefix:@"groups."]) {
            if (![chatID containsString:@";+;"]) { completion(Failure(@"native_group_required",NO)); return; }
            if ([method isEqual:@"groups.add"] || [method isEqual:@"groups.remove"]) {
                NSArray *handles = Handles(request[@"participants"],resolver);
                BOOL add = [method isEqual:@"groups.add"];
                if (!handles || ![Invoke(chat,add ? @"canAddParticipants:" : @"canRemoveParticipants:",@[handles]) boolValue]) { completion(Failure(@"native_participant_change_unavailable",NO)); return; }
                attempted = YES; Invoke(chat,add ? @"inviteParticipants:reason:" : @"removeParticipants:reason:",@[handles,NSNull.null]);
                Observe(^BOOL{
                    id raw = Invoke(chat,@"participantHandleIDs",@[]);
                    NSSet *actual = [raw isKindOfClass:NSArray.class] ? [NSSet setWithArray:raw] : raw;
                    if (![actual isKindOfClass:NSSet.class]) return NO;
                    NSSet *desired = [NSSet setWithArray:request[@"participants"]];
                    return add ? [desired isSubsetOfSet:actual] : ![desired intersectsSet:actual];
                },@{@"chat_guid":chatID},NSDate.date.timeIntervalSince1970+3,completion); return;
            } else if ([method isEqual:@"groups.name"]) {
                if (!Text(request[@"name"],256)) { completion(Failure(@"native_invalid_group_name",NO)); return; }
                attempted = YES; Invoke(chat,@"_setDisplayName:",@[request[@"name"]]);
                Observe(^BOOL{ return [Invoke(chat,@"displayName",@[]) isEqual:request[@"name"]]; },@{@"chat_guid":chatID},NSDate.date.timeIntervalSince1970+3,completion); return;
            } else if ([method isEqual:@"groups.photo"]) {
                id transfer = Transfer(request[@"file_path"],YES,resolver);
                if (!transfer) { completion(Failure(@"native_transfer_unavailable",NO)); return; }
                attempted = YES; Invoke(chat,@"sendGroupPhotoUpdate:",@[Invoke(transfer,@"guid",@[])]);
                completion(Pending(@{@"chat_guid":chatID})); return;
            } else if ([method isEqual:@"groups.leave"]) {
                if (![Invoke(chat,@"canLeaveChat",@[]) boolValue]) { completion(Failure(@"native_leave_unavailable",NO)); return; }
                attempted = YES; Invoke(chat,@"leave",@[]);
                Observe(^BOOL{ return [Invoke(chat,@"hasLeftGroup",@[]) boolValue]; },@{@"chat_guid":chatID},NSDate.date.timeIntervalSince1970+3,completion); return;
            }
            completion(@{@"ok":@YES,@"chat_guid":chatID,@"confirmation":@"native-call"}); return;
        }
        if ([method isEqual:@"messages.edit"] || [method isEqual:@"messages.unsend"]) {
            NSString *guid = request[@"message_guid"];
            NSNumber *rawIndex = request[@"part_index"] ?: @0;
            if (!UUIDText(guid) || ![rawIndex isKindOfClass:NSNumber.class] || rawIndex.doubleValue != rawIndex.integerValue || rawIndex.integerValue < 0 || rawIndex.integerValue > 63) { completion(Failure(@"native_invalid_message",NO)); return; }
            id message = MessageInChat(chat,guid), part = message ? PartAtIndex(message,rawIndex.integerValue) : nil;
            id time = message ? Invoke(message,@"time",@[]) : nil;
            BOOL edit = [method isEqual:@"messages.edit"];
            double age = [time isKindOfClass:NSDate.class] ? -[time timeIntervalSinceNow] : INFINITY;
            if (!message || !part || ![Invoke(message,@"isFromMe",@[]) boolValue] || ![Invoke(message,@"isSent",@[]) boolValue] || age < 0 || age > (edit ? 900 : 120) ||
                ![Invoke(part,edit ? @"canEditMessageText" : @"canRetract",@[]) boolValue]) { completion(Failure(@"native_message_change_not_allowed",NO)); return; }
            if (edit) {
                if (!Text(request[@"text"],64000)) { completion(Failure(@"native_invalid_text",NO)); return; }
                NSAttributedString *body = [[NSAttributedString alloc] initWithString:request[@"text"]];
                attempted = YES;
                Invoke(chat,EditSelector,@[Invoke(message,@"_imMessageItem",@[]),rawIndex,body,NSNull.null,body]);
            } else { attempted = YES; Invoke(chat,@"retractMessagePart:",@[part]); }
            Observe(^BOOL{
                id current = MessageInChat(chat,guid);
                if (!current) return NO;
                id currentPart = PartAtIndex(current,rawIndex.integerValue);
                if (!edit) return (currentPart && [Invoke(currentPart,@"isRetractedMessagePart",@[]) boolValue]) || [Invoke(Invoke(current,@"_imMessageItem",@[]),@"isFullyRetracted",@[]) boolValue];
                if (!currentPart || ![Invoke(currentPart,@"isEditedMessagePart",@[]) boolValue]) return NO;
                id content = Invoke(currentPart,@"text",@[]);
                NSString *plain = [content isKindOfClass:NSAttributedString.class] ? [content string] : content;
                return [plain isKindOfClass:NSString.class] && [plain isEqual:request[@"text"]];
            },@{@"chat_guid":chatID,@"message_guid":guid,@"part_index":rawIndex},NSDate.date.timeIntervalSince1970+3,completion); return;
        }
        // One IMMessage contains all ordered parts; transfer preparation never
        // dispatches a standalone attachment message.
        NSArray *files = request[@"files"] ?: @[];
        NSString *text = request[@"text"];
        if (![files isKindOfClass:NSArray.class] || files.count > 8 || (text && !Text(text,64000)) || (!text && files.count == 0)) { completion(Failure(@"native_invalid_parts",NO)); return; }
        NSString *effect = request[@"effect"];
        Class messageClass = Resolve(@"IMMessage",resolver);
        if (effect) {
            if (!Text(effect,160) || !([effect hasPrefix:@"com.apple.messages.effect."] || [effect hasPrefix:@"com.apple.MobileSMS.expressivesend."])) { completion(Failure(@"native_invalid_effect",NO)); return; }
            if (!InstanceHas(messageClass,@"setExpressiveSendStyleID:") || !InstanceHas(messageClass,@"expressiveSendStyleID")) { completion(Failure(@"native_effect_unavailable",NO)); return; }
        }
        NSMutableAttributedString *body = [[NSMutableAttributedString alloc] initWithString:text ?: @""];
        NSMutableArray *transfers = [NSMutableArray array];
        NSString *partKey = NativeAttribute(@"IMMessagePartAttributeName",resolver), *transferKey = NativeAttribute(@"IMFileTransferGUIDAttributeName",resolver), *filenameKey = NativeAttribute(@"IMFilenameAttributeName",resolver);
        if (!partKey || !transferKey || !filenameKey) { completion(Failure(@"native_attributes_unavailable",NO)); return; }
        NSUInteger partIndex = 0;
        if (body.length) { [body addAttribute:partKey value:@(partIndex++) range:NSMakeRange(0,body.length)]; }
        for (NSDictionary *file in files) {
            if (![file isKindOfClass:NSDictionary.class]) { completion(Failure(@"native_invalid_parts",NO)); return; }
            id transfer = Transfer(file[@"file_path"],NO,resolver);
            if (!transfer) { completion(Failure(@"native_transfer_unavailable",NO)); return; }
            NSString *guid = Invoke(transfer,@"guid",@[]);
            [transfers addObject:guid];
            NSAttributedString *attachment = [[NSAttributedString alloc] initWithString:@"\ufffc" attributes:@{partKey:@(partIndex++),transferKey:guid,filenameKey:[file[@"file_path"] lastPathComponent]}];
            [body appendAttributedString:attachment];
        }
        id service = Invoke(Resolve(@"IMService",resolver),@"iMessageService",@[]);
        if (!service) { completion(Failure(@"native_imessage_unavailable",NO)); return; }
        id message = Invoke([Resolve(@"IMMessage",resolver) alloc],MessageInitializer,@[NSNull.null,NSNull.null,body,NSNull.null,transfers,@(0x100005),NSNull.null,NSUUID.UUID.UUIDString,NSNull.null,NSNull.null]);
        if (effect) {
            Invoke(message,@"setExpressiveSendStyleID:",@[effect]);
            if (![Invoke(message,@"expressiveSendStyleID",@[]) isEqual:effect]) { completion(Failure(@"native_effect_unavailable",NO)); return; }
        }
        attempted = YES; Invoke(chat,@"sendMessage:onService:",@[message,service]);
        id guid = Invoke(message,@"guid",@[]);
        completion(UUIDText(guid) ? @{@"ok":@YES,@"guid":guid,@"chat_guid":chatID,@"confirmation":@"native-call"} : Failure(@"native_guid_unconfirmed",YES));
    } @catch (NSException *exception) {
        completion(Failure([exception.name isEqual:@"BBCUnsupported"] ? @"native_selector_unavailable" : @"native_exception",attempted));
    }
}
