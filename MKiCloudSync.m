//
//  MKiCloudSync.m
//
//  Created by Mugunth Kumar on 11/20//11.
//  Modified by Alexsander Akers on 1/4/12.
//  
//  Copyright (C) 2011-2020 by Steinlogic
//  
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//  
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//  
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

NSString *MKiCloudSyncDidUpdateNotification = @"MKiCloudSyncDidUpdateNotification";

#import "MKiCloudSync.h"

@interface MKiCloudSync ()

+ (void) pullFromICloud: (NSNotification *) note;
+ (void) pushToICloud;

+ (BOOL)tryToStartSync;

@end

@implementation MKiCloudSync

static dispatch_queue_t _queue;
static BOOL _isSyncing;

+ (void)initialize
{
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		_queue = dispatch_queue_create("com.mugunthkumar.MKiCloudSync", DISPATCH_QUEUE_SERIAL);
		_isSyncing = NO;
	});
}

+ (BOOL) isSyncing
{
	__block BOOL isSyncing = NO;
	dispatch_sync(_queue, ^{
		isSyncing = _isSyncing;
	});
	return isSyncing;
}

+ (BOOL)tryToStartSync
{
	__block BOOL didSucceed = NO;
	dispatch_sync(_queue, ^{
		if (!_isSyncing) {
			_isSyncing = YES;
			didSucceed = YES;
		}
	});
	return didSucceed;
}

+ (BOOL) start
{
	if ([NSUbiquitousKeyValueStore class] && [NSUbiquitousKeyValueStore defaultStore])
	{
		if ([self tryToStartSync]) {
#if MKiCloudSyncDebug
			NSLog(@"MKiCloudSync: Will start sync");
#endif
			// Force pull
			NSUbiquitousKeyValueStore *store = [NSUbiquitousKeyValueStore defaultStore];
			NSDictionary *dict = [store dictionaryRepresentation];
			
			NSMutableSet *syncedKeys = [NSMutableSet setWithArray: [dict allKeys]];
			if ([[self whitelistedKeys] count] > 0) {
				[syncedKeys intersectSet: [self whitelistedKeys]];
			}
			[syncedKeys minusSet: [self ignoredKeys]];
			
			NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
			for (id key in syncedKeys) {
				id obj = [store objectForKey: key];
				[userDefaults setObject: obj forKey:key];
			}
			[userDefaults synchronize];
			
			// Force push
			[MKiCloudSync pushToICloud];
			
			// Post notification
			NSNotificationCenter *dnc = [NSNotificationCenter defaultCenter];
			[dnc postNotificationName: MKiCloudSyncDidUpdateNotification object: self];
			
			// Add self as observer
			[dnc addObserver: self selector: @selector(pullFromICloud:) name: NSUbiquitousKeyValueStoreDidChangeExternallyNotification object: store];
			[dnc addObserver: self selector: @selector(pushToICloud) name: NSUserDefaultsDidChangeNotification object: nil];
			
#if MKiCloudSyncDebug
			NSLog(@"MKiCloudSync: Did start sync");
			NSLog(@"MKiCloudSync: Updating from iCloud");
#endif		
			return YES;
		}
	}
	
	return NO;
}

+ (NSMutableSet *) ignoredKeys
{
	static NSMutableSet *ignoredKeys = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		ignoredKeys = [NSMutableSet new];
	});
	
	return ignoredKeys;
}

+ (NSMutableSet *) whitelistedKeys
{
	static NSMutableSet *whitelistedKeys = nil;
	static dispatch_once_t whitelistedKeysOnceToken;
	dispatch_once(&whitelistedKeysOnceToken, ^{
		whitelistedKeys = [NSMutableSet new];
	});
	
	return whitelistedKeys;
}

+ (void) cleanUbiquitousStore
{
	[self stop];
	
	NSUbiquitousKeyValueStore *store = [NSUbiquitousKeyValueStore defaultStore];
	NSDictionary *dict = [store dictionaryRepresentation];
	
	NSMutableSet *syncedKeys = [NSMutableSet setWithArray: [dict allKeys]];
	if ([[self whitelistedKeys] count] > 0) {
		[syncedKeys intersectSet: [self whitelistedKeys]];
	}
	[syncedKeys minusSet: [self ignoredKeys]];
	
	for (id key in syncedKeys) {
		[store removeObjectForKey: key];
	}
	[store synchronize];
	
#if MKiCloudSyncDebug
		NSLog(@"MKiCloudSync: Cleaned ubiquitous store");
#endif
}

+ (void) pullFromICloud: (NSNotification *) note
{
	NSNotificationCenter *dnc = [NSNotificationCenter defaultCenter];
	[dnc removeObserver: self name: NSUserDefaultsDidChangeNotification object: nil];
	
	NSUbiquitousKeyValueStore *store = note.object;
	NSMutableSet *changedKeys = [NSMutableSet setWithArray:[note.userInfo objectForKey: NSUbiquitousKeyValueStoreChangedKeysKey]];

#if MKiCloudSyncDebug
		NSLog(@"MKiCloudSync: Pulled from iCloud");
#endif
	
	if ([[self whitelistedKeys] count] > 0) {
		[changedKeys intersectSet: [self whitelistedKeys]];
	}
	[changedKeys minusSet: [self ignoredKeys]];
	
	NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
	for (id key in changedKeys) {
		id obj = [store objectForKey: key];
		[userDefaults setObject: obj forKey: key];
	}
	[userDefaults synchronize];
	
	[dnc addObserver: self selector: @selector(pushToICloud) name: NSUserDefaultsDidChangeNotification object: nil];
	[dnc postNotificationName: MKiCloudSyncDidUpdateNotification object: nil];
}

+ (void) pushToICloud
{
	NSString *identifier = [[NSBundle mainBundle] bundleIdentifier];
	NSDictionary *persistentDomain = [[[NSUserDefaults standardUserDefaults] persistentDomainForName: identifier] copy];
	
	NSMutableSet *syncedKeys = [NSMutableSet setWithArray: [persistentDomain allKeys]];
	if ([[self whitelistedKeys] count] > 0) {
		[syncedKeys intersectSet: [self whitelistedKeys]];
	}
	[syncedKeys minusSet: [self ignoredKeys]];
	DLog(@"syncedKeys = %@", syncedKeys);
	
	NSUbiquitousKeyValueStore *store = [NSUbiquitousKeyValueStore defaultStore];
	for (id key in syncedKeys) {
		id obj = [persistentDomain objectForKey: key];
		[store setObject: obj forKey: key];
	}
	[store synchronize];
	
#if MKiCloudSyncDebug
	NSLog(@"MKiCloudSync: Pushed to iCloud");
#endif
}

+ (void) stop
{
#if MKiCloudSyncDebug
	NSLog(@"MKiCloudSync: Stop syncining with iCloud");
#endif
	dispatch_sync(_queue, ^{
		_isSyncing = NO;
		[[NSNotificationCenter defaultCenter] removeObserver: self];
	});
}

@end
