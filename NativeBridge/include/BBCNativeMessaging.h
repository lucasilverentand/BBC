#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
typedef Class _Nullable (^BBCNativeClassResolver)(NSString *name);
typedef void (^BBCNativeCompletion)(NSDictionary<NSString *, id> *result);

/// Original BBC adapter. The resolver permits synthetic runtime fixtures;
/// production always resolves Apple's classes inside the Messages process.
FOUNDATION_EXPORT NSArray<NSString *> *BBCNativeCapabilities(BBCNativeClassResolver _Nullable resolver);
FOUNDATION_EXPORT void BBCNativePerform(NSDictionary<NSString *, id> *request,
                                       BBCNativeClassResolver _Nullable resolver,
                                       BBCNativeCompletion completion);
/// The timeout can be shortened by synthetic fixtures, but cannot exceed the
/// production ten-second bound. It is never accepted from an IPC request.
FOUNDATION_EXPORT void BBCNativePerformWithScanTimeout(NSDictionary<NSString *, id> *request,
                                                      BBCNativeClassResolver _Nullable resolver,
                                                      double scanTimeout,
                                                      BBCNativeCompletion completion);
/// Production bounds. Synthetic fixtures may shorten, never extend, either one.
FOUNDATION_EXPORT const double BBCNativeDefaultLoadTimeout;
FOUNDATION_EXPORT const double BBCNativeDefaultScanTimeout;
FOUNDATION_EXPORT void BBCNativePerformWithTimeouts(NSDictionary<NSString *, id> *request,
                                                   BBCNativeClassResolver _Nullable resolver,
                                                   double loadTimeout,
                                                   double scanTimeout,
                                                   BBCNativeCompletion completion);
NS_ASSUME_NONNULL_END
