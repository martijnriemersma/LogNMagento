//
//  HDHaulerDealsService.m
//  Hauler Deals
//
//  Created by Rex Sheng on 9/5/12.
//  Copyright (c) 2012 Log(n) LLC. All rights reserved.
//

#import "Magento.h"
#import "MagentoClient.h"
#import "SoapRequestOperation.h"

NSString * const kUserDefaultsCartKey = @"magento.cart";
NSString * const kUserDefaultsStoresKey = @"magento.stores";
NSString * const kUserDefaultsCustomerKey = @"magento.customer_id";
NSString * const kUserDefaultsCustomerNameKey = @"magento.customer_name";
NSString * const FAILED_SESSION = @"NULL";
NSString * const KEY_SEPERATOR = @"::";

@implementation Magento
{
	dispatch_group_t session_group;
	NSArray *countries;
	dispatch_queue_t session_queue;
	NSMutableDictionary *_cache;
}

@synthesize customerID, cartID, storeID, cacheInterval, customerName;

+ (Magento *)service
{
	static Magento *instance;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		instance = [[Magento alloc] init];
	});
	return instance;
}

- (id)init
{
	if (self = [super init]) {
		session_group = dispatch_group_create();
		session_queue = dispatch_queue_create("com.lognllc.Magento.session_queue", DISPATCH_QUEUE_SERIAL);
		
		client = [[MagentoClient alloc] initWithBaseURL:[NSURL URLWithString:MAGENTO_BASE_URL]];
		[client setDefaultHeader:@"SOAPAction" value:@"urn:Mage_Api_Model_Server_HandlerAction"];
		[client registerHTTPOperationClass:[SoapRequestOperation class]];
		[SoapRequestOperation addAcceptableStatusCodes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(200, 301)]];
		[client setDefaultHeader:@"Content-Type" value:@"text/xml; charset=utf-8"];
#if TARGET_OS_IPHONE
		[[NSNotificationCenter defaultCenter] addObserver:self
												 selector:@selector(clearCache)
													 name:UIApplicationDidReceiveMemoryWarningNotification
												   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
												 selector:@selector(clearCache)
													 name:UIApplicationWillResignActiveNotification
												   object:nil];
#endif
        cacheInterval = 3600.f;
	}
	return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
	dispatch_release(session_queue);
	dispatch_release(session_group);
}

#pragma mark - Cache
- (void)clearCache
{
	[_cache removeAllObjects];
	_cache = nil;
}

- (void)cacheResponse:(id)value forCall:(NSArray *)key
{
    if (!_cache) {
        _cache = [[NSMutableDictionary alloc] init];
    }
    [_cache setValue:value forKey:[key componentsJoinedByString:KEY_SEPERATOR]];
    [NSObject cancelPreviousPerformRequestsWithTarget:_cache selector:@selector(removeObjectForKey:) object:key];
    [_cache performSelector:@selector(removeObjectForKey:) withObject:key afterDelay:cacheInterval];
}

- (id)cachedResponseForCall:(NSArray *)call
{
	return [_cache objectForKey:[call componentsJoinedByString:KEY_SEPERATOR]];
}

#pragma mark - Cart And Customer
- (void)setCustomerID:(id)_customerID
{
	customerID = _customerID;
	if (!_customerID) {
		[[NSUserDefaults standardUserDefaults] removeObjectForKey:kUserDefaultsCustomerKey];
	} else {
		[[NSUserDefaults standardUserDefaults] setObject:customerID forKey:kUserDefaultsCustomerKey];
	}
	[[NSUserDefaults standardUserDefaults] synchronize];
}

- (id)customerID
{
	if (!customerID) {
		customerID = [[NSUserDefaults standardUserDefaults] objectForKey:kUserDefaultsCustomerKey];
	}
	return customerID;
}

- (void)setCustomerName:(id)_customerName
{
	customerName = _customerName;
	if (!_customerName) {
		[[NSUserDefaults standardUserDefaults] removeObjectForKey:kUserDefaultsCustomerNameKey];
	} else {
		[[NSUserDefaults standardUserDefaults] setObject:customerName forKey:kUserDefaultsCustomerNameKey];
	}
	[[NSUserDefaults standardUserDefaults] synchronize];
}

- (id)customerName
{
	if (!customerName) {
		customerName = [[NSUserDefaults standardUserDefaults] objectForKey:kUserDefaultsCustomerNameKey];
	}
	return customerName;
}

- (void)setCartID:(id)_cartID
{
	cartID = _cartID;
	if (!_cartID) {
		[[NSUserDefaults standardUserDefaults] removeObjectForKey:kUserDefaultsCartKey];
	} else {
		[[NSUserDefaults standardUserDefaults] setObject:cartID forKey:kUserDefaultsCartKey];
	}
	[[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)createCart:(void (^)(NSNumber *cart))block
{
	if (!cartID)
		cartID = [[NSUserDefaults standardUserDefaults] objectForKey:kUserDefaultsCartKey];
	if (!cartID) {
		[self call:@[@"cart.create", storeID] success:^(__unused AFHTTPRequestOperation *o, id responseObject) {
			NSLog(@"create cart %@", responseObject);
			NSNumber *_cardID = responseObject;
			[self call:@[@"cart_customer.set", responseObject, @{@"entity_id": customerID, @"mode": @"customer"}, storeID] success:^(AFHTTPRequestOperation *operation, id succeeded) {
				if ([succeeded boolValue]) {
					self.cartID = _cardID;
					NSLog(@"set cart customer %@", customerID);
					if (block) block(cartID);
				} else {
					NSLog(@"failed to set cart customer %@", customerID);
					if (block) block(nil);
				}
			} failure:^(AFHTTPRequestOperation *operation, NSError *error) {
				NSLog(@"failed to set cart customer %@ %@", customerID, error.localizedDescription);
			}];
		} failure:nil];
	} else {
		if (block) block(cartID);
	}
}

#pragma mark - Product Info
+ (void)getImageAndPrice:(NSMutableDictionary *)item completion:(void (^)(BOOL immediate))completion
{
	NSString *url = item[@"image"];
	NSString *price = item[@"price"];
	NSString *basePrice = item[@"msrp"];
	BOOL hasURLCall = NO;
	BOOL hasPriceCall = NO;
	if (!url || (!price && !basePrice)) {
		NSMutableArray *calls = [NSMutableArray array];
		if (!url) {
			[calls addObject:@[@"catalog_product_attribute_media.list", item[@"product_id"]]];
			hasURLCall = YES;
		}
		if (!price && !basePrice) {
			[calls addObject:@[@"catalog_product.info", item[@"product_id"], self.service.storeID, @[@"msrp", @"price"]]];
			hasPriceCall = YES;
		}
		[self multiCall:calls success:^(AFHTTPRequestOperation *operation, NSArray *responseObject) {
			if (hasURLCall) {
				NSDictionary *image = [responseObject[0] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"exclude == '0'"]].lastObject;
				if (image) {
					item[@"image"] = image[@"url"];
				}
			}
			if (hasPriceCall) {
				[item setValuesForKeysWithDictionary:[responseObject lastObject]];
			}
			if (completion) completion(NO);
		} failure:nil];
	} else {
		if (completion) completion(YES);
	}
}

+ (void)getImage:(NSMutableDictionary *)item completion:(void (^)(NSString *imageURL, BOOL immediate))completion
{
	NSString *url = item[@"image"];
	if (!url) {
		item[@"image"] = @"";
		[self call:@[@"catalog_product_attribute_media.list", item[@"product_id"]] success:^(AFHTTPRequestOperation *operation, id responseObject) {
			NSDictionary *image = [responseObject filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"exclude == '0'"]].lastObject;
			if (image) {
				item[@"image"] = image[@"url"];
				if (completion) completion(image[@"url"], NO);
			}
		} failure:nil];
	} else if (url.length) {
		if (completion) completion(url, YES);
	}
}

#pragma mark - Session
- (void)startSession
{
	NSString *_sessionID;
	@synchronized(self) {
		_sessionID = sessionID;
	}
	if (_sessionID != FAILED_SESSION)
		dispatch_group_enter(session_group);
	[client postPath:@"login" parameters:@{@"username": MAGENTO_USERNAME, @"apiKey": MAGENTO_API_KEY} success:^(AFHTTPRequestOperation *operation, id responseObject) {
		sessionID = responseObject;
		dispatch_group_leave(session_group);
		NSLog(@"got session %@", sessionID);
	} failure:^(AFHTTPRequestOperation *operation, NSError *error) {
		sessionID = FAILED_SESSION;
	}];
}

- (void)inSession:(dispatch_block_t)block
{
	dispatch_async(session_queue, ^{
		if (!sessionID || sessionID == FAILED_SESSION) {
			if (sessionID == FAILED_SESSION) {
				dispatch_async(dispatch_get_main_queue(), ^{
					[self startSession];
				});
			}
			if (![NSThread isMainThread]) {
				dispatch_group_wait(session_group, DISPATCH_TIME_FOREVER);
			}
		}
		if (block) block();
	});
}

- (void)renewSession
{
	dispatch_async(session_queue, ^{
		@synchronized(self) {
			sessionID = nil;
		}
		[self startSession];
	});
}

#pragma mark - Basic call
+ (void)call:(NSArray *)args success:(void (^)(AFHTTPRequestOperation *operation, id responseObject))success failure:(void (^)(AFHTTPRequestOperation *operation, NSError *error))failure
{
	[self.service call:args success:success failure:failure];
}

- (void)call:(NSArray *)params success:(void (^)(AFHTTPRequestOperation *operation, id responseObject))success failure:(void (^)(AFHTTPRequestOperation *operation, NSError *error))failure
{
	NSAssert(params.count > 0, @"call method does not provided");
	[self inSession:^{
		NSString *resourcePath = [params objectAtIndex:0];
		NSArray *args = [params subarrayWithRange:NSMakeRange(1, params.count - 1)];
		[client postPath:@"call" parameters:@{@"sessionId": sessionID, @"resourcePath": resourcePath, @"args": args} success:success failure:failure];
	}];
}

+ (void)multiCall:(NSArray *)args success:(void (^)(AFHTTPRequestOperation *operation, id responseObject))success failure:(void (^)(AFHTTPRequestOperation *operation, NSError *error))failure
{
	[self.service multiCall:args success:success failure:failure];
}

- (void)multiCall:(NSArray *)args success:(void (^)(AFHTTPRequestOperation *operation, id responseObject))success failure:(void (^)(AFHTTPRequestOperation *operation, NSError *error))failure
{
	[self inSession:^{
		[client postPath:@"multiCall" parameters:@{@"sessionId": sessionID, @"calls": args} success:success failure:failure];
	}];
}

@end
