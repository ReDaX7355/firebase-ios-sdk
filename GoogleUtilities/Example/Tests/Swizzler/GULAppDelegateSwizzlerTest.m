// Copyright 2018 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#import <GoogleUtilities/GULAppDelegateSwizzler.h>
#import "GULAppDelegateSwizzler_Private.h"

#import <OCMock/OCMock.h>
#import <XCTest/XCTest.h>
#import <objc/runtime.h>

#if (defined(__IPHONE_9_0) && (__IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_9_0))
#define SDK_HAS_USERACTIVITY 1
#endif

/** Plist key that allows Firebase developers to disable App Delegate Proxying.  Source of truth is
 *  the GULAppDelegateSwizzler class.
 */
static NSString *const kGULFirebaseAppDelegateProxyEnabledPlistKey =
    @"FirebaseAppDelegateProxyEnabled";

/** Plist key that allows non-Firebase developers to disable App Delegate Proxying.  Source of truth
 *  is the GULAppDelegateSwizzler class.
 */
static NSString *const kGULGoogleAppDelegateProxyEnabledPlistKey =
    @"GoogleUtilitiesAppDelegateProxyEnabled";

#pragma mark - GULTestAppDelegate

/** This class conforms to the UIApplicationDelegate protocol and is there to be able to test the
 *  App Delegate Swizzler's behavior.
 */
@interface GULTestAppDelegate : UIResponder <UIApplicationDelegate> {
 @public  // Because we want to access the ivars from outside the class like obj->ivar for testing.
  /** YES if the application:openURL:options: was called on an instance, NO otherwise. */
  BOOL _isOpenURLOptionsMethodCalled;

  /** Contains the backgroundSessionID that was passed to the
   *  application:handleEventsForBackgroundURLSession:completionHandler: method.
   */
  NSString *_backgroundSessionID;

  /** YES if init was called. Used for memory layout testing after isa swizzling. */
  BOOL _isInitialized;

  /** An arbitrary number. Used for memory layout testing after isa swizzling. */
  int _arbitraryNumber;
}

/** A URL property that is set by the app delegate methods, which is then used to verify if the app
 *  delegate methods were properly called.
 */
@property(nonatomic, copy) NSString *url;

@end

@implementation GULTestAppDelegate

// TODO: The static BOOLs below being accurate is dependent on the runtime loading
// GULTestAppDelegate before GULAppDelegateSwizzlerTest. It works, but it might be a good idea to
// figure a way to make this more deterministic.

/** YES if GULTestAppDelegate responds to application:openURL:sourceApplication:annotation:, NO
 *  otherwise.
 */
static BOOL gRespondsToOpenURLHandler_iOS8;

/** YES if GULTestAppDelegate responds to application:openURL:options:, NO otherwise. */
static BOOL gRespondsToOpenURLHandler_iOS9;

/** YES if GULTestAppDelegate responds to application:continueUserActivity:restorationHandler:, NO
 *  otherwise.
 */
static BOOL gRespondsToContinueUserActivity;

/** YES if GULTestAppDelegate responds to
 *  application:handleEventsForBackgroundURLSession:completionHandler:, NO otherwise.
 */
static BOOL gRespondsToHandleBackgroundSession;

+ (void)load {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  // Before being proxied, it should be only be able to respond to
  // application:openURL:sourceApplication:annotation:.
  gRespondsToOpenURLHandler_iOS8 = [self
      instancesRespondToSelector:@selector(application:openURL:sourceApplication:annotation:)];
  gRespondsToOpenURLHandler_iOS9 =
      [self instancesRespondToSelector:@selector(application:openURL:options:)];
  gRespondsToHandleBackgroundSession =
      [self instancesRespondToSelector:@selector
            (application:handleEventsForBackgroundURLSession:completionHandler:)];
  gRespondsToContinueUserActivity = [self
      instancesRespondToSelector:@selector(application:continueUserActivity:restorationHandler:)];
#pragma clang diagnostic pop
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _isOpenURLOptionsMethodCalled = NO;
    _isInitialized = YES;
    _arbitraryNumber = 123456789;
    _backgroundSessionID = @"randomSessionID";
    _url = nil;
  }
  return self;
}

- (BOOL)application:(UIApplication *)app
            openURL:(NSURL *)url
            options:(NSDictionary<NSString *, id> *)options {
  _url = [url copy];
  _isOpenURLOptionsMethodCalled = YES;
  return NO;
}

- (void)application:(UIApplication *)application
    handleEventsForBackgroundURLSession:(nonnull NSString *)identifier
                      completionHandler:(nonnull void (^)(void))completionHandler {
  _backgroundSessionID = [identifier copy];
}

// These are methods to test whether changing the class still maintains behavior that the app
// delegate proxy shouldn't have modified.

- (NSString *)someArbitraryMethod {
  return @"blabla";
}

+ (int)someNumber {
  return 890;
}

@end

#pragma mark - Interceptor class

/** This is a class used to test whether interceptors work with the App Delegate Swizzler. */
@interface GULTestInterceptorAppDelegate : UIResponder <UIApplicationDelegate>

/** URL sent to application:openURL:options:. */
@property(nonatomic, copy) NSURL *URLForIOS9;

/** URL sent to application:openURL:sourceApplication:annotation:. */
@property(nonatomic, copy) NSURL *URLForIOS8;

/** The NSUserActivity sent to application:continueUserActivity:restorationHandler:. */
@property(nonatomic, copy) NSUserActivity *userActivity;

@end

@implementation GULTestInterceptorAppDelegate

- (BOOL)application:(UIApplication *)app
            openURL:(NSURL *)url
            options:(NSDictionary<NSString *, id> *)options {
  _URLForIOS9 = [url copy];
  return YES;
}

- (BOOL)application:(UIApplication *)application
              openURL:(nonnull NSURL *)url
    sourceApplication:(nullable NSString *)sourceApplication
           annotation:(nonnull id)annotation {
  _URLForIOS8 = [url copy];
  return YES;
}

#if SDK_HAS_USERACTIVITY

- (BOOL)application:(UIApplication *)application
    continueUserActivity:(NSUserActivity *)userActivity
      restorationHandler:(void (^)(NSArray *__nullable restorableObjects))restorationHandler {
  _userActivity = userActivity;
  return YES;
}

#endif  // SDK_HAS_USERACTIVITY

@end

@interface GULAppDelegateSwizzlerTest : XCTestCase

@end

@implementation GULAppDelegateSwizzlerTest

- (void)tearDown {
  [GULAppDelegateSwizzler clearInterceptors];
}

/** Tests proxying an object that responds to UIApplicationDelegate protocol and makes sure that
 *  it is isa swizzled and that the object after proxying responds to the expected methods
 *  and doesn't have its ivars modified.
 */
- (void)testProxyAppDelegate {
  GULTestAppDelegate *realAppDelegate = [[GULTestAppDelegate alloc] init];
  size_t sizeBefore = class_getInstanceSize([GULTestAppDelegate class]);

  // These asserts only work if the class GULTestAppDelegate is loaded before GULAppDelegateProxy
  // class is loaded.
  XCTAssertTrue(gRespondsToOpenURLHandler_iOS9);
  XCTAssertFalse(gRespondsToOpenURLHandler_iOS8);
  XCTAssertFalse(gRespondsToContinueUserActivity);
  XCTAssertTrue(gRespondsToHandleBackgroundSession);

  Class realAppDelegateClassBefore = [realAppDelegate class];

  // Create the proxy.
  [GULAppDelegateSwizzler proxyAppDelegate:realAppDelegate];

  XCTAssertTrue([realAppDelegate isKindOfClass:[GULTestAppDelegate class]]);

  NSString *newClassName = NSStringFromClass([realAppDelegate class]);
  XCTAssertTrue([newClassName hasPrefix:@"GUL_"]);
  // It is no longer GULTestAppDelegate class instance.
  XCTAssertFalse([realAppDelegate isMemberOfClass:[GULTestAppDelegate class]]);

  size_t sizeAfter = class_getInstanceSize([realAppDelegate class]);

  // Class size must stay the same.
  XCTAssertEqual(sizeBefore, sizeAfter);

  // After being proxied, it should be able to respond to the required method selector.
  XCTAssertTrue([realAppDelegate
      respondsToSelector:@selector(application:openURL:sourceApplication:annotation:)]);
  XCTAssertTrue([realAppDelegate
      respondsToSelector:@selector(application:continueUserActivity:restorationHandler:)]);
  XCTAssertTrue([realAppDelegate respondsToSelector:@selector(application:openURL:options:)]);
  XCTAssertTrue(
      [realAppDelegate respondsToSelector:@selector
                       (application:handleEventsForBackgroundURLSession:completionHandler:)]);
  // Make sure that the class has changed.
  XCTAssertNotEqualObjects([realAppDelegate class], realAppDelegateClassBefore);

  // Make sure that the ivars are not changed in memory as the subclass is created. Directly
  // accessing the ivars should not crash.
  XCTAssertEqual(realAppDelegate->_arbitraryNumber, 123456789);
  XCTAssertEqual(realAppDelegate->_isInitialized, 1);
  XCTAssertEqual(realAppDelegate->_isOpenURLOptionsMethodCalled, 0);
  XCTAssertEqualObjects(realAppDelegate->_backgroundSessionID, @"randomSessionID");
}

#if SDK_HAS_USERACTIVITY
- (void)testHandleBackgroundSessionMethod {
  GULTestAppDelegate *realAppDelegate = [[GULTestAppDelegate alloc] init];

  // Create the proxy.
  [GULAppDelegateSwizzler proxyAppDelegate:realAppDelegate];

  UIApplication *currentApplication = [UIApplication sharedApplication];
  NSString *sessionID = @"123";
  void (^nilHandler)() = nil;
  [realAppDelegate application:currentApplication
      handleEventsForBackgroundURLSession:sessionID
                        completionHandler:nilHandler];

  // Intentionally access the ivars directly. It should be set to the session ID as the real method
  // is called.
  XCTAssertEqualObjects(realAppDelegate->_backgroundSessionID, sessionID);
}
#endif  // SDK_HAS_USERACTIVITY

/** Tests registering and unregistering invalid interceptors. */
- (void)testInvalidInterceptor {
  XCTAssertThrows([GULAppDelegateSwizzler registerAppDelegateInterceptor:nil],
                  @"Should not register nil interceptor");
  XCTAssertEqual([GULAppDelegateSwizzler interceptors].count, 0);

  // Try to register some random object that does not conform to UIApplicationDelegate.
  NSObject *randomObject = [[NSObject alloc] init];

  XCTAssertThrows(
      [GULAppDelegateSwizzler
          registerAppDelegateInterceptor:(id<UIApplicationDelegate>)randomObject],
      @"Should not register interceptor that does not conform to UIApplicationDelegate");
  XCTAssertEqual([GULAppDelegateSwizzler interceptors].count, 0);

  GULTestInterceptorAppDelegate *interceptorAppDelegate =
      [[GULTestInterceptorAppDelegate alloc] init];
  GULAppDelegateInterceptorID interceptorID =
      [GULAppDelegateSwizzler registerAppDelegateInterceptor:interceptorAppDelegate];
  XCTAssertNotNil(interceptorID);
  XCTAssertEqual([GULAppDelegateSwizzler interceptors].count, 1);

  // Register the same object. Should not change the number of objects.
  XCTAssertNotNil([GULAppDelegateSwizzler registerAppDelegateInterceptor:interceptorAppDelegate]);
  XCTAssertEqual([GULAppDelegateSwizzler interceptors].count, 1);

  XCTAssertThrows([GULAppDelegateSwizzler unregisterAppDelegateInterceptorWithID:@""],
                  @"Should not unregister empty interceptor ID");
  XCTAssertEqual([GULAppDelegateSwizzler interceptors].count, 1);

  // Try to unregister an empty string. Should not remove anything.
  XCTAssertThrows([GULAppDelegateSwizzler unregisterAppDelegateInterceptorWithID:nil],
                  @"Should not unregister nil interceptorID");
  XCTAssertEqual([GULAppDelegateSwizzler interceptors].count, 1);

  // Try to unregister a random string. Should not remove anything.
  [GULAppDelegateSwizzler unregisterAppDelegateInterceptorWithID:@"random ID"];
  XCTAssertEqual([GULAppDelegateSwizzler interceptors].count, 1);

  // Unregister the right one.
  [GULAppDelegateSwizzler unregisterAppDelegateInterceptorWithID:interceptorID];
  XCTAssertEqual([GULAppDelegateSwizzler interceptors].count, 0);
}

/** Tests that the description of appDelegate object doesn't change even after proxying it. */
- (void)testDescription {
  GULTestAppDelegate *realAppDelegate = [[GULTestAppDelegate alloc] init];
  Class classBefore = [realAppDelegate class];
  NSString *descriptionBefore = [realAppDelegate description];

  [GULAppDelegateSwizzler proxyAppDelegate:realAppDelegate];

  Class classAfter = [realAppDelegate class];
  NSString *descriptionAfter = [realAppDelegate description];

  NSString *descriptionString =
      [NSString stringWithFormat:@"<GULTestAppDelegate: %p>", realAppDelegate];

  // The description must be the same even though the class has changed.
  XCTAssertEqualObjects(descriptionBefore, descriptionAfter);
  XCTAssertNotEqualObjects(classAfter, classBefore);
  XCTAssertEqualObjects(descriptionAfter, descriptionString);
}

/** Tests that methods that are not overriden by the App Delegate Proxy still work as expected. */
- (void)testNotOverriddenMethods {
  GULTestAppDelegate *realAppDelegate = [[GULTestAppDelegate alloc] init];

  // Create the proxy.
  [GULAppDelegateSwizzler proxyAppDelegate:realAppDelegate];

  // Make sure that original class instance method still works.
  XCTAssertEqualObjects([realAppDelegate someArbitraryMethod], @"blabla");

  // Make sure that the new subclass inherits the original class method.
  XCTAssertEqual([[realAppDelegate class] someNumber], 890);

  // Make sure that the original class still works.
  XCTAssertEqual([GULTestAppDelegate someNumber], 890);
}

/** Tests that if the app delegate changes after it has been proxied, the App Delegate Swizzler
 *  handles it correctly.
 */
- (void)skipped_testAppDelegateInstance {
  id originalDelegate = [UIApplication sharedApplication].delegate;

  GULTestAppDelegate *realAppDelegate = [[GULTestAppDelegate alloc] init];

  [UIApplication sharedApplication].delegate = realAppDelegate;
  [GULAppDelegateSwizzler proxyAppDelegate:realAppDelegate];

  XCTAssertEqualObjects([GULAppDelegateSwizzler originalDelegate], realAppDelegate);

  GULTestInterceptorAppDelegate *anotherAppDelegate = [[GULTestInterceptorAppDelegate alloc] init];
  XCTAssertNotEqualObjects(realAppDelegate, anotherAppDelegate);

  [UIApplication sharedApplication].delegate = anotherAppDelegate;
  // Make sure that the new delegate is swizzled out and set correctly.
  XCTAssertNil([GULAppDelegateSwizzler originalDelegate]);

  [GULAppDelegateSwizzler proxyAppDelegate:anotherAppDelegate];
  XCTAssertEqualObjects([GULAppDelegateSwizzler originalDelegate], anotherAppDelegate);

  // Make sure that it is set to nil correctly.
  [UIApplication sharedApplication].delegate = nil;
  XCTAssertNil([UIApplication sharedApplication].delegate);
  XCTAssertNil([GULAppDelegateSwizzler originalDelegate]);

  [UIApplication sharedApplication].delegate = originalDelegate;
  XCTAssertEqualObjects([UIApplication sharedApplication].delegate, originalDelegate);
  XCTAssertNil([GULAppDelegateSwizzler originalDelegate]);
}

#pragma mark - Tests the behaviour with interceptors

/** Tests that application:openURL:options: is invoked on the interceptor if it exists. */
- (void)testApplicationOpenURLOptionsIsInvokedOnInterceptors {
  id interceptor = OCMProtocolMock(@protocol(UIApplicationDelegate));
  OCMExpect([interceptor application:OCMOCK_ANY openURL:OCMOCK_ANY options:OCMOCK_ANY])
      .andReturn(NO);

  id interceptor2 = OCMProtocolMock(@protocol(UIApplicationDelegate));
  OCMExpect([interceptor2 application:OCMOCK_ANY openURL:OCMOCK_ANY options:OCMOCK_ANY])
      .andReturn(NO);

  NSURL *testURL = [[NSURL alloc] initWithString:@"https://www.google.com"];
  NSDictionary *testOpenURLOptions = @{UIApplicationOpenURLOptionUniversalLinksOnly : @"test"};

  GULTestAppDelegate *testAppDelegate = [[GULTestAppDelegate alloc] init];
  [GULAppDelegateSwizzler proxyAppDelegate:testAppDelegate];
  [GULAppDelegateSwizzler registerAppDelegateInterceptor:interceptor];
  [GULAppDelegateSwizzler registerAppDelegateInterceptor:interceptor2];

  [testAppDelegate application:[UIApplication sharedApplication]
                       openURL:testURL
                       options:testOpenURLOptions];
  OCMVerifyAll(interceptor);
  OCMVerifyAll(interceptor2);
}

/** Tests that the result of application:openURL:options: from all interceptors is ORed. */
- (void)testResultOfApplicationOpenURLOptionsIsORed {
  NSURL *testURL = [[NSURL alloc] initWithString:@"https://www.google.com"];
  NSDictionary *testOpenURLOptions = @{UIApplicationOpenURLOptionUniversalLinksOnly : @"test"};

  GULTestAppDelegate *testAppDelegate = [[GULTestAppDelegate alloc] init];
  [GULAppDelegateSwizzler proxyAppDelegate:testAppDelegate];

  BOOL shouldOpen = [testAppDelegate application:[UIApplication sharedApplication]
                                         openURL:testURL
                                         options:testOpenURLOptions];
  // Verify that the original app delegate returns NO.
  XCTAssertFalse(shouldOpen);

  id interceptor = OCMProtocolMock(@protocol(UIApplicationDelegate));
  OCMExpect([interceptor application:OCMOCK_ANY openURL:OCMOCK_ANY options:OCMOCK_ANY])
      .andReturn(NO);
  [GULAppDelegateSwizzler registerAppDelegateInterceptor:interceptor];
  shouldOpen = [testAppDelegate application:[UIApplication sharedApplication]
                                    openURL:testURL
                                    options:testOpenURLOptions];
  // Verify that if the only interceptor returns NO, the value is still NO.
  XCTAssertFalse(shouldOpen);

  id interceptor2 = OCMProtocolMock(@protocol(UIApplicationDelegate));
  OCMExpect([interceptor2 application:OCMOCK_ANY openURL:OCMOCK_ANY options:OCMOCK_ANY])
      .andReturn(YES);
  [GULAppDelegateSwizzler registerAppDelegateInterceptor:interceptor2];

  OCMExpect([interceptor application:OCMOCK_ANY openURL:OCMOCK_ANY options:OCMOCK_ANY])
      .andReturn(NO);
  shouldOpen = [testAppDelegate application:[UIApplication sharedApplication]
                                    openURL:testURL
                                    options:testOpenURLOptions];
  // Verify that if one of the two interceptors returns YES, the value is YES.
  XCTAssertTrue(shouldOpen);
}

/** Tests that application:openURL:sourceApplication:annotation: is invoked on the interceptors if
 *  it exists.
 */
- (void)testApplicationOpenURLSourceApplicationAnnotationIsInvokedOnInterceptors {
  id interceptor = OCMProtocolMock(@protocol(UIApplicationDelegate));
  OCMExpect([interceptor application:OCMOCK_ANY
                             openURL:OCMOCK_ANY
                   sourceApplication:OCMOCK_ANY
                          annotation:OCMOCK_ANY])
      .andReturn(NO);

  id interceptor2 = OCMProtocolMock(@protocol(UIApplicationDelegate));
  OCMExpect([interceptor2 application:OCMOCK_ANY
                              openURL:OCMOCK_ANY
                    sourceApplication:OCMOCK_ANY
                           annotation:OCMOCK_ANY])
      .andReturn(NO);

  NSURL *testURL = [[NSURL alloc] initWithString:@"https://www.google.com"];

  GULTestAppDelegate *testAppDelegate = [[GULTestAppDelegate alloc] init];
  [GULAppDelegateSwizzler proxyAppDelegate:testAppDelegate];
  [GULAppDelegateSwizzler registerAppDelegateInterceptor:interceptor];
  [GULAppDelegateSwizzler registerAppDelegateInterceptor:interceptor2];

  [testAppDelegate application:[UIApplication sharedApplication]
                       openURL:testURL
             sourceApplication:@"test"
                    annotation:@"test"];

  OCMVerifyAll(interceptor);
  OCMVerifyAll(interceptor2);
}

/** Tests that the result of application:openURL:sourceApplication:annotation: from all interceptors
 *  is ORed.
 */
- (void)testApplicationOpenURLSourceApplicationAnnotationResultIsORed {
  GULTestAppDelegate *testAppDelegate = [[GULTestAppDelegate alloc] init];
  NSURL *testURL = [[NSURL alloc] initWithString:@"https://www.google.com"];
  [GULAppDelegateSwizzler proxyAppDelegate:testAppDelegate];

  BOOL shouldOpen = [testAppDelegate application:[UIApplication sharedApplication]
                                         openURL:testURL
                               sourceApplication:@"test"
                                      annotation:@"test"];
  // Verify that without interceptors the result is NO.
  XCTAssertFalse(shouldOpen);

  id interceptor = OCMProtocolMock(@protocol(UIApplicationDelegate));
  OCMExpect([interceptor application:OCMOCK_ANY
                             openURL:OCMOCK_ANY
                   sourceApplication:OCMOCK_ANY
                          annotation:OCMOCK_ANY])
      .andReturn(NO);
  [GULAppDelegateSwizzler registerAppDelegateInterceptor:interceptor];
  shouldOpen = [testAppDelegate application:[UIApplication sharedApplication]
                                    openURL:testURL
                          sourceApplication:@"test"
                                 annotation:@"test"];
  // The result is still NO if the only interceptor returns NO.
  XCTAssertFalse(shouldOpen);

  id interceptor2 = OCMProtocolMock(@protocol(UIApplicationDelegate));
  OCMExpect([interceptor2 application:OCMOCK_ANY
                              openURL:OCMOCK_ANY
                    sourceApplication:OCMOCK_ANY
                           annotation:OCMOCK_ANY])
      .andReturn(YES);
  OCMExpect([interceptor application:OCMOCK_ANY
                             openURL:OCMOCK_ANY
                   sourceApplication:OCMOCK_ANY
                          annotation:OCMOCK_ANY])
      .andReturn(NO);
  [GULAppDelegateSwizzler registerAppDelegateInterceptor:interceptor2];
  shouldOpen = [testAppDelegate application:[UIApplication sharedApplication]
                                    openURL:testURL
                          sourceApplication:@"test"
                                 annotation:@"test"];
  // The result is YES if one of the interceptors returns YES.
  XCTAssertTrue(shouldOpen);
}

/** Tests that application:handleEventsForBackgroundURLSession:completionHandler: is invoked on the
 *  interceptors if it exists.
 */
- (void)testApplicationHandleEventsForBackgroundURLSessionIsInvokedOnInterceptors {
  id interceptor = OCMProtocolMock(@protocol(UIApplicationDelegate));
  OCMExpect([interceptor application:OCMOCK_ANY
      handleEventsForBackgroundURLSession:OCMOCK_ANY
                        completionHandler:OCMOCK_ANY]);

  id interceptor2 = OCMProtocolMock(@protocol(UIApplicationDelegate));
  OCMExpect([interceptor2 application:OCMOCK_ANY
      handleEventsForBackgroundURLSession:OCMOCK_ANY
                        completionHandler:OCMOCK_ANY]);

  GULTestAppDelegate *testAppDelegate = [[GULTestAppDelegate alloc] init];
  [GULAppDelegateSwizzler proxyAppDelegate:testAppDelegate];
  [GULAppDelegateSwizzler registerAppDelegateInterceptor:interceptor];
  [GULAppDelegateSwizzler registerAppDelegateInterceptor:interceptor2];

  [testAppDelegate application:[UIApplication sharedApplication]
      handleEventsForBackgroundURLSession:@"test"
                        completionHandler:^{
                        }];

  OCMVerifyAll(interceptor);
  OCMVerifyAll(interceptor2);
}

/** Tests that application:continueUserActivity:restorationHandler: is invoked on the interceptors
 *  if it exists.
 */
- (void)testApplicationContinueUserActivityRestorationHandlerIsInvokedOnInterceptors {
  id interceptor = OCMProtocolMock(@protocol(UIApplicationDelegate));
  OCMExpect([interceptor application:OCMOCK_ANY
                continueUserActivity:OCMOCK_ANY
                  restorationHandler:OCMOCK_ANY])
      .andReturn(NO);

  id interceptor2 = OCMProtocolMock(@protocol(UIApplicationDelegate));
  OCMExpect([interceptor2 application:OCMOCK_ANY
                 continueUserActivity:OCMOCK_ANY
                   restorationHandler:OCMOCK_ANY])
      .andReturn(NO);

  NSUserActivity *testUserActivity = [[NSUserActivity alloc] initWithActivityType:@"test"];

  GULTestAppDelegate *testAppDelegate = [[GULTestAppDelegate alloc] init];
  [GULAppDelegateSwizzler proxyAppDelegate:testAppDelegate];
  [GULAppDelegateSwizzler registerAppDelegateInterceptor:interceptor];
  [GULAppDelegateSwizzler registerAppDelegateInterceptor:interceptor2];

  [testAppDelegate application:[UIApplication sharedApplication]
          continueUserActivity:testUserActivity
            restorationHandler:^(NSArray *restorableObjects){
            }];
  OCMVerifyAll(interceptor);
  OCMVerifyAll(interceptor2);
}

/** Tests that the results of application:continueUserActivity:restorationHandler: from the
 *  interceptors are ORed.
 */
- (void)testApplicationContinueUserActivityRestorationHandlerResultsAreORed {
  GULTestAppDelegate *testAppDelegate = [[GULTestAppDelegate alloc] init];
  [GULAppDelegateSwizzler proxyAppDelegate:testAppDelegate];
  NSUserActivity *testUserActivity = [[NSUserActivity alloc] initWithActivityType:@"test"];

  BOOL shouldContinueUserActvitiy = [testAppDelegate application:[UIApplication sharedApplication]
                                            continueUserActivity:testUserActivity
                                              restorationHandler:^(NSArray *restorableObjects){
                                              }];
  // Verify that it is NO when there are no interceptors.
  XCTAssertFalse(shouldContinueUserActvitiy);

  id interceptor = OCMProtocolMock(@protocol(UIApplicationDelegate));
  OCMExpect([interceptor application:OCMOCK_ANY
                continueUserActivity:OCMOCK_ANY
                  restorationHandler:OCMOCK_ANY])
      .andReturn(NO);
  [GULAppDelegateSwizzler registerAppDelegateInterceptor:interceptor];
  shouldContinueUserActvitiy = [testAppDelegate application:[UIApplication sharedApplication]
                                       continueUserActivity:testUserActivity
                                         restorationHandler:^(NSArray *restorableObjects){
                                         }];
  // Verify that it is NO when the only interceptor returns a NO.
  XCTAssertFalse(shouldContinueUserActvitiy);

  id interceptor2 = OCMProtocolMock(@protocol(UIApplicationDelegate));
  OCMExpect([interceptor2 application:OCMOCK_ANY
                 continueUserActivity:OCMOCK_ANY
                   restorationHandler:OCMOCK_ANY])
      .andReturn(YES);
  [GULAppDelegateSwizzler registerAppDelegateInterceptor:interceptor2];

  OCMExpect([interceptor application:OCMOCK_ANY
                continueUserActivity:OCMOCK_ANY
                  restorationHandler:OCMOCK_ANY])
      .andReturn(NO);
  shouldContinueUserActvitiy = [testAppDelegate application:[UIApplication sharedApplication]
                                       continueUserActivity:testUserActivity
                                         restorationHandler:^(NSArray *restorableObjects){
                                         }];

  // The result is YES if one of the interceptors returns YES.
  XCTAssertTrue(shouldContinueUserActvitiy);
}

#pragma mark - Tests to test that Plist flag is honored

/** Tests that app delegate proxy is enabled when there is no Info.plist dictionary. */
- (void)testAppProxyPlistFlag_NoFlag {
  // No keys anywhere. If there is no key, the default should be enabled.
  NSDictionary *mainDictionary = nil;
  id mainBundleMock = OCMPartialMock([NSBundle mainBundle]);
  [[[mainBundleMock expect] andReturn:mainDictionary] infoDictionary];

  XCTAssertTrue([GULAppDelegateSwizzler isAppDelegateProxyEnabled]);
  [mainBundleMock stopMocking];
}

/** Tests that app delegate proxy is enabled when there is neither the Firebase nor the non-Firebase
 *  Info.plist key present.
 */
- (void)testAppProxyPlistFlag_NoAppDelegateProxyKey {
  // No app delegate disable key. If there is no key, the default should be enabled.
  NSDictionary *mainDictionary = @{@"randomKey" : @"randomValue"};
  id mainBundleMock = OCMPartialMock([NSBundle mainBundle]);
  [[[mainBundleMock expect] andReturn:mainDictionary] infoDictionary];

  XCTAssertTrue([GULAppDelegateSwizzler isAppDelegateProxyEnabled]);
  [mainBundleMock stopMocking];
}

/** Tests that app delegate proxy is enabled when the Firebase plist is explicitly set to YES and
 * the Google flag is not present. */
- (void)testAppProxyPlistFlag_FirebaseEnabled {
  // Set proxy enabled to YES.
  NSDictionary *mainDictionary = @{kGULFirebaseAppDelegateProxyEnabledPlistKey : @(YES)};
  id mainBundleMock = OCMPartialMock([NSBundle mainBundle]);
  [[[mainBundleMock expect] andReturn:mainDictionary] infoDictionary];

  XCTAssertTrue([GULAppDelegateSwizzler isAppDelegateProxyEnabled]);
  [mainBundleMock stopMocking];
}

/** Tests that app delegate proxy is enabled when the Google plist is explicitly set to YES and the
 * Firebase flag is not present. */
- (void)testAppProxyPlistFlag_GoogleEnabled {
  // Set proxy enabled to YES.
  NSDictionary *mainDictionary = @{kGULGoogleAppDelegateProxyEnabledPlistKey : @(YES)};
  id mainBundleMock = OCMPartialMock([NSBundle mainBundle]);
  [[[mainBundleMock expect] andReturn:mainDictionary] infoDictionary];

  XCTAssertTrue([GULAppDelegateSwizzler isAppDelegateProxyEnabled]);
  [mainBundleMock stopMocking];
}

/** Tests that the App Delegate proxy is enabled when the Firebase flag has the wrong type of value
 * and the Google flag is not present. */
- (void)testAppProxyPlist_WrongFirebaseDisableFlagValueType {
  // Set proxy enabled to "NO" - a string.
  NSDictionary *mainDictionary = @{kGULFirebaseAppDelegateProxyEnabledPlistKey : @"NO"};
  id mainBundleMock = OCMPartialMock([NSBundle mainBundle]);
  [[[mainBundleMock expect] andReturn:mainDictionary] infoDictionary];

  XCTAssertTrue([GULAppDelegateSwizzler isAppDelegateProxyEnabled]);
  [mainBundleMock stopMocking];
}

/** Tests that the App Delegate proxy is enabled when the Google flag has the wrong type of value
 * and the Firebase flag is not present. */
- (void)testAppProxyPlist_WrongGoogleDisableFlagValueType {
  // Set proxy enabled to "NO" - a string.
  NSDictionary *mainDictionary = @{kGULGoogleAppDelegateProxyEnabledPlistKey : @"NO"};
  id mainBundleMock = OCMPartialMock([NSBundle mainBundle]);
  [[[mainBundleMock expect] andReturn:mainDictionary] infoDictionary];

  XCTAssertTrue([GULAppDelegateSwizzler isAppDelegateProxyEnabled]);
  [mainBundleMock stopMocking];
}

/** Tests that the App Delegate proxy is disabled when the Firebase flag is set to NO and the Google
 * flag is not present. */
- (void)testAppProxyPlist_FirebaseDisableFlag {
  // Set proxy enabled to NO.
  NSDictionary *mainDictionary = @{kGULFirebaseAppDelegateProxyEnabledPlistKey : @(NO)};
  id mainBundleMock = OCMPartialMock([NSBundle mainBundle]);
  [[[mainBundleMock expect] andReturn:mainDictionary] infoDictionary];

  XCTAssertFalse([GULAppDelegateSwizzler isAppDelegateProxyEnabled]);
  [mainBundleMock stopMocking];
}

/** Tests that the App Delegate proxy is disabled when the Google flag is set to NO and the Firebase
 * flag is not present. */
- (void)testAppProxyPlist_GoogleDisableFlag {
  // Set proxy enabled to NO.
  NSDictionary *mainDictionary = @{kGULGoogleAppDelegateProxyEnabledPlistKey : @(NO)};
  id mainBundleMock = OCMPartialMock([NSBundle mainBundle]);
  [[[mainBundleMock expect] andReturn:mainDictionary] infoDictionary];

  XCTAssertFalse([GULAppDelegateSwizzler isAppDelegateProxyEnabled]);
  [mainBundleMock stopMocking];
}

/** Tests that the App Delegate proxy is disabled when the Google flag is set to NO and the Firebase
 * flag is set to YES. */
- (void)testAppProxyPlist_GoogleDisableFlagFirebaseEnableFlag {
  // Set proxy enabled to NO.
  NSDictionary *mainDictionary = @{
    kGULGoogleAppDelegateProxyEnabledPlistKey : @(NO),
    kGULFirebaseAppDelegateProxyEnabledPlistKey : @(YES)
  };
  id mainBundleMock = OCMPartialMock([NSBundle mainBundle]);
  [[[mainBundleMock expect] andReturn:mainDictionary] infoDictionary];

  XCTAssertFalse([GULAppDelegateSwizzler isAppDelegateProxyEnabled]);
  [mainBundleMock stopMocking];
}

/** Tests that the App Delegate proxy is disabled when the Google flag is set to NO and the Firebase
 * flag is set to YES. */
- (void)testAppProxyPlist_FirebaseDisableFlagGoogleEnableFlag {
  // Set proxy enabled to NO.
  NSDictionary *mainDictionary = @{
    kGULGoogleAppDelegateProxyEnabledPlistKey : @(YES),
    kGULFirebaseAppDelegateProxyEnabledPlistKey : @(NO)
  };
  id mainBundleMock = OCMPartialMock([NSBundle mainBundle]);
  [[[mainBundleMock expect] andReturn:mainDictionary] infoDictionary];

  XCTAssertFalse([GULAppDelegateSwizzler isAppDelegateProxyEnabled]);
  [mainBundleMock stopMocking];
}

/** Tests that the App Delegate proxy is disabled when the Google flag is set to NO and the Firebase
 * flag is set to NO. */
- (void)testAppProxyPlist_FirebaseDisableFlagGoogleDisableFlag {
  // Set proxy enabled to NO.
  NSDictionary *mainDictionary = @{
    kGULGoogleAppDelegateProxyEnabledPlistKey : @(NO),
    kGULFirebaseAppDelegateProxyEnabledPlistKey : @(NO)
  };
  id mainBundleMock = OCMPartialMock([NSBundle mainBundle]);
  [[[mainBundleMock expect] andReturn:mainDictionary] infoDictionary];

  XCTAssertFalse([GULAppDelegateSwizzler isAppDelegateProxyEnabled]);
  [mainBundleMock stopMocking];
}

/** Tests that the App Delegate is not proxied when it is disabled. */
- (void)testAppDelegateIsNotProxiedWhenDisabled {
  // Set proxy enabled to NO.
  NSDictionary *mainDictionary = @{kGULFirebaseAppDelegateProxyEnabledPlistKey : @(NO)};
  id mainBundleMock = OCMPartialMock([NSBundle mainBundle]);
  [[[mainBundleMock stub] andReturn:mainDictionary] infoDictionary];
  XCTAssertFalse([GULAppDelegateSwizzler isAppDelegateProxyEnabled]);

  id originalAppDelegate = OCMProtocolMock(@protocol(UIApplicationDelegate));
  Class originalAppDelegateClass = [originalAppDelegate class];
  XCTAssertNotNil(originalAppDelegate);

  [GULAppDelegateSwizzler proxyAppDelegate:originalAppDelegate];
  XCTAssertEqualObjects([originalAppDelegate class], originalAppDelegateClass);

  [mainBundleMock stopMocking];
}

// TODO(tejasd): There is some weirdness that happens (at least when running this locally on Xcode)
// where the actual app delegate is nilled out in one of these tests, causing the tests to fail.
// Disabling this test seems to fix the problem.

/** Tests that the App Delegate is proxied when it is enabled. */
- (void)testAppDelegateIsProxiedWhenEnabled {
  // App Delegate Proxying is enabled by default.
  XCTAssertTrue([GULAppDelegateSwizzler isAppDelegateProxyEnabled]);

  id originalAppDelegate = [[GULTestAppDelegate alloc] init];
  Class originalAppDelegateClass = [originalAppDelegate class];
  XCTAssertNotNil(originalAppDelegate);

  [GULAppDelegateSwizzler proxyAppDelegate:originalAppDelegate];
  XCTAssertNotEqualObjects([originalAppDelegate class], originalAppDelegateClass);
}

@end
