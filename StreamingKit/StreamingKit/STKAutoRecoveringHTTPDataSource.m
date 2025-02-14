/**********************************************************************************
 AudioPlayer.m
 
 Created by Thong Nguyen on 16/10/2012.
 https://github.com/tumtumtum/audjustable
 
 Copyright (c) 2012-2014 Thong Nguyen (tumtumtum@gmail.com). All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 1. Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 2. Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 3. All advertising materials mentioning features or use of this software
 must display the following acknowledgement:
 This product includes software developed by Thong Nguyen (tumtumtum@gmail.com)
 4. Neither the name of Thong Nguyen nor the
 names of its contributors may be used to endorse or promote products
 derived from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY Thong Nguyen''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL <COPYRIGHT HOLDER> BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **********************************************************************************/

#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet6/in6.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <netdb.h>
#import "mach/mach_time.h"
#import <Foundation/Foundation.h>
#if TARGET_OS_IOS
#import <SystemConfiguration/SystemConfiguration.h>
#endif
#import "STKAutoRecoveringHTTPDataSource.h"

#define DEFAULT_WATCHDOG_PERIOD_SECONDS (8)
#define DEFAULT_INACTIVE_PERIOD_BEFORE_RECONNECT_SECONDS (15)

static uint64_t GetTickCount(void)
{
    static mach_timebase_info_data_t sTimebaseInfo;
    uint64_t machTime = mach_absolute_time();
    
    if (sTimebaseInfo.denom == 0 )
    {
        (void) mach_timebase_info(&sTimebaseInfo);
    }
    
    uint64_t millis = ((machTime / 1000000) * sTimebaseInfo.numer) / sTimebaseInfo.denom;
    
    return millis;
}

@interface STKAutoRecoveringHTTPDataSource()
{
    int serial;
	int waitSeconds;
    NSTimer* timeoutTimer;
    BOOL waitingForNetwork;
    uint64_t ticksWhenLastDataReceived;
#if TARGET_OS_IOS
    SCNetworkReachabilityRef reachabilityRef;
    STKAutoRecoveringHTTPDataSourceOptions options;
#endif
}

-(void) reachabilityChanged;

@end

#if TARGET_OS_IOS
static void ReachabilityCallback(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void* info)
{
    @autoreleasepool
    {
        STKAutoRecoveringHTTPDataSource* dataSource = (__bridge STKAutoRecoveringHTTPDataSource*)info;
        
        [dataSource reachabilityChanged];
    }
}
#endif

static void PopulateOptionsWithDefault(STKAutoRecoveringHTTPDataSourceOptions* options)
{
    if (options->watchdogPeriodSeconds == 0)
    {
        options->watchdogPeriodSeconds = DEFAULT_WATCHDOG_PERIOD_SECONDS;
    }
    
    if (options->inactivePeriodBeforeReconnectSeconds == 0)
    {
        options->inactivePeriodBeforeReconnectSeconds = DEFAULT_INACTIVE_PERIOD_BEFORE_RECONNECT_SECONDS;
    }
}

@implementation STKAutoRecoveringHTTPDataSource

@dynamic innerDataSource;

-(STKHTTPDataSource*) innerHTTPDataSource
{
    return (STKHTTPDataSource*)self.innerDataSource;
}

-(instancetype) initWithDataSource:(STKDataSource *)innerDataSource
{
    return [self initWithHTTPDataSource:(STKHTTPDataSource*)innerDataSource];
}

#if TARGET_OS_IOS
-(instancetype) initWithHTTPDataSource:(STKHTTPDataSource*)innerDataSourceIn
{
    return [self initWithHTTPDataSource:innerDataSourceIn andOptions:(STKAutoRecoveringHTTPDataSourceOptions){}];
}
#endif

#if TARGET_OS_IOS
-(instancetype) initWithHTTPDataSource:(STKHTTPDataSource*)innerDataSourceIn andOptions:(STKAutoRecoveringHTTPDataSourceOptions)optionsIn
{
    if (self = [super initWithDataSource:innerDataSourceIn]) {
        self.innerDataSource.delegate = self;
        PopulateOptionsWithDefault(&optionsIn);
        self->options = optionsIn;
        NSString* hostname = innerDataSourceIn.url.host;
        if (hostname.length) {
            reachabilityRef = SCNetworkReachabilityCreateWithName(NULL, [hostname UTF8String]);
        }
    }
    
    return self;
}
#endif

#if TARGET_OS_IOS
-(BOOL) startNotifierOnRunLoop:(NSRunLoop*)runLoop
{
    if (reachabilityRef) {
        SCNetworkReachabilityContext context = { 0, (__bridge void*)self, NULL, NULL, NULL };
        if (SCNetworkReachabilitySetCallback(reachabilityRef, ReachabilityCallback, &context)) {
            if(SCNetworkReachabilityScheduleWithRunLoop(reachabilityRef, runLoop.getCFRunLoop, kCFRunLoopDefaultMode))
            {
                return YES;
            }
        }
    }
    return NO;
}
#endif

-(BOOL) registerForEvents:(NSRunLoop*)runLoop
{
    [super registerForEvents:runLoop];
#if TARGET_OS_IOS
    [self startNotifierOnRunLoop:runLoop];
#endif
    
    if (timeoutTimer)
    {
        [timeoutTimer invalidate];
        timeoutTimer = nil;
    }
    
	ticksWhenLastDataReceived = GetTickCount();
	
#if TARGET_OS_IOS
    [self createTimeoutTimer];
#endif
    
    return YES;
}

-(void) unregisterForEvents
{
    [super unregisterForEvents];
    [self stopNotifier];
    
    [self destroyTimeoutTimer];
}

-(void) timeoutTimerTick:(NSTimer*)timer
{
    if (![self hasBytesAvailable])
    {
        if ([self hasGotNetworkConnection])
        {
            uint64_t currentTicks = GetTickCount();
            
#if TARGET_OS_IOS
            if (((currentTicks - ticksWhenLastDataReceived) / 1000) >= options.inactivePeriodBeforeReconnectSeconds)
            {
                serial++;
                
                NSLog(@"timeoutTimerTick %lld/%lld", self.position, self.length);
                
                [self attemptReconnectWithSerial:@(serial)];
            }
#endif
        }
    }
}

#if TARGET_OS_IOS
-(void) createTimeoutTimer
{
    [self destroyTimeoutTimer];
    
    NSRunLoop* runLoop = self.innerDataSource.eventsRunLoop;
    
    if (runLoop == nil)
    {
        return;
    }
    
    timeoutTimer = [NSTimer timerWithTimeInterval:options.watchdogPeriodSeconds target:self selector:@selector(timeoutTimerTick:) userInfo:@(serial) repeats:YES];
    
    [runLoop addTimer:timeoutTimer forMode:NSRunLoopCommonModes];
}
#endif

-(void) destroyTimeoutTimer
{
    if (timeoutTimer)
    {
        [timeoutTimer invalidate];
        timeoutTimer = nil;
    }
}

-(void) stopNotifier
{
#if TARGET_OS_IOS
    if (reachabilityRef != NULL)
    {
        SCNetworkReachabilitySetCallback(reachabilityRef, NULL, NULL);
        SCNetworkReachabilityUnscheduleFromRunLoop(reachabilityRef, [self.innerDataSource.eventsRunLoop getCFRunLoop], kCFRunLoopDefaultMode);
    }
#endif
}

-(BOOL) hasGotNetworkConnection
{
#if TARGET_OS_IOS
    SCNetworkReachabilityFlags flags;
    
    if (! reachabilityRef) return YES; // Assume reachability, if unknown
    
    if (SCNetworkReachabilityGetFlags(reachabilityRef, &flags))
    {
        return ((flags & kSCNetworkReachabilityFlagsReachable) != 0);
    }
#endif
    
    return NO;
}

-(void) seekToOffset:(int64_t)offset
{
	ticksWhenLastDataReceived = GetTickCount();
	
	[super seekToOffset:offset];
}

-(void) close
{
    [self destroyTimeoutTimer];
    [super close];
}

-(void) dealloc
{
    NSLog(@"STKAutoRecoveringHTTPDataSource dealloc");
    
    self.innerDataSource.delegate = nil;
    
    [self stopNotifier];
    [self destroyTimeoutTimer];
    
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    
#if TARGET_OS_IOS
    if (reachabilityRef!= NULL)
    {
        CFRelease(reachabilityRef);
    }
#endif
}

-(void) reachabilityChanged
{
    if (waitingForNetwork)
    {
        waitingForNetwork = NO;
        
        NSLog(@"reachabilityChanged %lld/%lld", self.position, self.length);
        
        serial++;
        
        [self attemptReconnectWithSerial:@(serial)];
    }
}

-(void) dataSourceDataAvailable:(STKDataSource*)dataSource
{
    if (![self.innerDataSource hasBytesAvailable])
    {
        return;
    }
    
    serial++;
    waitSeconds = 1;
    ticksWhenLastDataReceived = GetTickCount();
    
    [super dataSourceDataAvailable:dataSource];
}

-(void) attemptReconnectWithSerial:(NSNumber*)serialIn
{
    if (serialIn.intValue != self->serial)
    {
        return;
    }
    
    NSLog(@"attemptReconnect %lld/%lld", self.position, self.length);
    
	if (self.innerDataSource.eventsRunLoop)
	{
		[self.innerDataSource reconnect];
	}
}

-(void) attemptReconnectWithTimer:(NSTimer*)timer
{
    [self attemptReconnectWithSerial:(NSNumber*)timer.userInfo];
}

-(void) processRetryOnError
{
    if (![self hasGotNetworkConnection])
    {
        waitingForNetwork = YES;
        
        return;
    }
    
	waitingForNetwork = NO;
	
    NSRunLoop* runLoop = self.innerDataSource.eventsRunLoop;
    
    if (runLoop == nil)
    {
        // DataSource no longer used
        
        return;
    }
    else
    {
        serial++;
        
        NSTimer* timer = [NSTimer timerWithTimeInterval:waitSeconds target:self selector:@selector(attemptReconnectWithTimer:) userInfo:@(serial) repeats:NO];
        
        [runLoop addTimer:timer forMode:NSRunLoopCommonModes];
    }
    
    waitSeconds = MIN(waitSeconds + 1, 5);
}

-(void) dataSourceEof:(STKDataSource*)dataSource
{
	NSLog(@"dataSourceEof");
	
    if ([self position] < [self length])
    {
        [self processRetryOnError];
        
        return;
    }
    
    [self.delegate dataSourceEof:self];
}

-(void) dataSourceErrorOccured:(STKDataSource*)dataSource
{
    NSLog(@"dataSourceErrorOccured");
    
    if (self.innerDataSource.httpStatusCode == 416 /* Range out of bounds */)
    {
        [super dataSourceEof:dataSource];
    }
    else
    {
        [self processRetryOnError];
    }
}

-(NSString*) description
{
    return [NSString stringWithFormat:@"HTTP data source with file length: %lld and position: %lld", self.length, self.position];
}

@end
