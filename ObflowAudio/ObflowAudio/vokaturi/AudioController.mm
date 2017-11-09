/*
 * AudioController.mm
 *
 * Copyright (C) 2016 Vokaturi
 * version 2016-07-06
 *
 * This code is part of the Vokamono demo app.
 * It uses modified parts of Apple's aurioTouch demo software.
 *
 * You can freely adapt this code for your own software.
 * It comes with no warranty of any kind.
 */

#import "AudioController.h"

// Framework includes
#import <AVFoundation/AVAudioSession.h>


#import "SharedBuffer.h"

struct CallbackData {
    AudioUnit               rioUnit;
    BOOL*                   audioChainIsBeingReconstructed;
    
    CallbackData(): rioUnit(NULL), audioChainIsBeingReconstructed(NULL) {}
} cd;

// Render callback function
static OSStatus	performRender (void                         *inRefCon,
                               AudioUnitRenderActionFlags 	*ioActionFlags,
                               const AudioTimeStamp 		*inTimeStamp,
                               UInt32 						inBusNumber,
                               UInt32 						inNumberFrames,
                               AudioBufferList              *ioData)
{
//static long numberOfCalls = 0;
//fprintf (stderr, "%ld %d\n", ++ numberOfCalls, (int) inNumberFrames);
    OSStatus err = noErr;
    if (*cd.audioChainIsBeingReconstructed == NO)
    {
        // we are calling AudioUnitRender on the input bus of AURemoteIO
        // this will store the audio data captured by the microphone in ioData
        err = AudioUnitRender (cd.rioUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames, ioData);
        
		float *source = (float *) ioData -> mBuffers [0]. mData;
		int64_t sampleCount = OSAtomicAdd64Barrier (0, & theSharedBuffer. numberOfReceivedSamples);
		int32_t samplePointer = sampleCount % SHARED_BUFFER_SIZE;

		for (int32_t i = 0; i < inNumberFrames; i ++) {
			if (samplePointer >= SHARED_BUFFER_SIZE)
				samplePointer -= SHARED_BUFFER_SIZE;
			theSharedBuffer. samples [samplePointer] = source [i];   // this converts a float to a double
			samplePointer += 1;
		}
		OSAtomicAdd64Barrier (inNumberFrames, & theSharedBuffer. numberOfReceivedSamples);

		/*
			The audio unit is a bidirectional one: it does both input and output.
			Silence the output sound.
		*/
		for (int i = 0; i < ioData -> mNumberBuffers; ++ i)
			memset (ioData -> mBuffers [i]. mData, 0, ioData -> mBuffers [i]. mDataByteSize);
    }
    
    return err;
}


@interface AudioController()

- (void)setupAudioSession;
- (void)setupIOUnit;
- (void)setupAudioChain;

@end

@implementation AudioController

- (id)init
{
    if (self = [super init]) {
        [self setupAudioChain];
    }
    return self;
}


- (void)handleInterruption:(NSNotification *)notification
{
	UInt8 theInterruptionType = [[notification.userInfo valueForKey:AVAudioSessionInterruptionTypeKey] intValue];
	NSLog(@"Session interrupted > --- %s ---\n", theInterruptionType == AVAudioSessionInterruptionTypeBegan ? "Begin Interruption" : "End Interruption");
	
	if (theInterruptionType == AVAudioSessionInterruptionTypeBegan) {
		[self stopIOUnit];
	}
	
	if (theInterruptionType == AVAudioSessionInterruptionTypeEnded) {
		// make sure to activate the session
		NSError *error = nil;
		[[AVAudioSession sharedInstance] setActive:YES error:&error];
		if (nil != error) NSLog(@"AVAudioSession set active failed with error: %@", error);
		
		[self startIOUnit];
	}
}


- (void)handleRouteChange:(NSNotification *)notification
{
    UInt8 reasonValue = [[notification.userInfo valueForKey:AVAudioSessionRouteChangeReasonKey] intValue];
    AVAudioSessionRouteDescription *routeDescription = [notification.userInfo valueForKey:AVAudioSessionRouteChangePreviousRouteKey];
    
    NSLog(@"Route change:");
    switch (reasonValue) {
        case AVAudioSessionRouteChangeReasonNewDeviceAvailable:
            NSLog(@"     NewDeviceAvailable");
            break;
        case AVAudioSessionRouteChangeReasonOldDeviceUnavailable:
            NSLog(@"     OldDeviceUnavailable");
            break;
        case AVAudioSessionRouteChangeReasonCategoryChange:
            NSLog(@"     CategoryChange");
            NSLog(@" New Category: %@", [[AVAudioSession sharedInstance] category]);
            break;
        case AVAudioSessionRouteChangeReasonOverride:
            NSLog(@"     Override");
            break;
        case AVAudioSessionRouteChangeReasonWakeFromSleep:
            NSLog(@"     WakeFromSleep");
            break;
        case AVAudioSessionRouteChangeReasonNoSuitableRouteForCategory:
            NSLog(@"     NoSuitableRouteForCategory");
            break;
        default:
            NSLog(@"     ReasonUnknown");
    }
    
    NSLog(@"Previous route:\n");
    NSLog(@"%@", routeDescription);
}

- (void)handleMediaServerReset:(NSNotification *)notification
{
    NSLog(@"Media server has reset");
    _audioChainIsBeingReconstructed = YES;
    
    usleep(25000); //wait here for some time to ensure that we don't delete these objects while they are being accessed elsewhere
    
    // rebuild the audio chain
    _audioPlayer = nil;
    
    [self setupAudioChain];
    [self startIOUnit];
    
    _audioChainIsBeingReconstructed = NO;
}

- (void)setupAudioSession
{
	// Configure the audio session
	AVAudioSession *sessionInstance = [AVAudioSession sharedInstance];
	
	// we are going to play and record so we pick that category
	NSError *error = nil;
	[sessionInstance setCategory:AVAudioSessionCategoryPlayAndRecord error:&error];
	//[sessionInstance setCategory:AVAudioSessionCategoryRecord error:&error];
	//XThrowIfError((OSStatus)error.code, "couldn't set session's audio category");
	
	// set the buffer duration to 5 ms
	NSTimeInterval bufferDuration = .005;
	[sessionInstance setPreferredIOBufferDuration:bufferDuration error:&error];
	//XThrowIfError((OSStatus)error.code, "couldn't set session's I/O buffer duration");
	
	// set the session's sample rate
	[sessionInstance setPreferredSampleRate:44100 error:&error];
	//XThrowIfError((OSStatus)error.code, "couldn't set session's preferred sample rate");
	
	// add interruption handler
	[[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(handleInterruption:)
												 name:AVAudioSessionInterruptionNotification
											   object:sessionInstance];
	
	// we don't do anything special in the route change notification
	[[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(handleRouteChange:)
												 name:AVAudioSessionRouteChangeNotification
											   object:sessionInstance];
	
	// if media services are reset, we need to rebuild our audio chain
	[[NSNotificationCenter defaultCenter]	addObserver:	self
											 selector:	@selector(handleMediaServerReset:)
												 name:	AVAudioSessionMediaServicesWereResetNotification
											   object:	sessionInstance];
	
	// activate the audio session
	[[AVAudioSession sharedInstance] setActive:YES error:&error];
	//XThrowIfError((OSStatus)error.code, "couldn't set session active");
}


- (void)setupIOUnit
{
	// Create a new instance of AURemoteIO
	
	AudioComponentDescription desc;
	desc.componentType = kAudioUnitType_Output;
	desc.componentSubType = kAudioUnitSubType_RemoteIO;
	desc.componentManufacturer = kAudioUnitManufacturer_Apple;
	desc.componentFlags = 0;
	desc.componentFlagsMask = 0;
	
	AudioComponent comp = AudioComponentFindNext (NULL, & desc);
	AudioComponentInstanceNew (comp, & _rioUnit);
	
	//  Enable input and output on AURemoteIO
	//  Input is enabled on the input scope of the input element
	//  Output is enabled on the output scope of the output element
	
	UInt32 one = 1;
	AudioUnitSetProperty (_rioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, & one, sizeof (one));
	AudioUnitSetProperty (_rioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, & one, sizeof (one));
	
	// Explicitly set the input and output client formats
	// sample rate = 44100, num channels = 1, format = 32 bit floating point
	
	AudioStreamBasicDescription ioFormat;
	int numberOfChannels = 1;   // set to 1 for mono, or 2 for stereo
	bool channelsAreInterleaved = false;   // true = left[0], right[0], left [1], right [1]...; false = separate buffers for left and right
	ioFormat. mSampleRate = 44100;
    ioFormat. mFormatID = kAudioFormatLinearPCM;
    ioFormat. mFormatFlags =
		kAudioFormatFlagsNativeEndian |
		kAudioFormatFlagIsPacked |
		kAudioFormatFlagIsFloat |
		( channelsAreInterleaved ? 0 : kAudioFormatFlagIsNonInterleaved );
    ioFormat. mBytesPerPacket = sizeof (float) * ( channelsAreInterleaved ? numberOfChannels : 1);
    ioFormat. mFramesPerPacket = 1;
    ioFormat. mBytesPerFrame = ioFormat. mBytesPerPacket;
    ioFormat. mChannelsPerFrame = numberOfChannels;
    ioFormat. mBitsPerChannel = sizeof (float) * 8;
    ioFormat. mReserved = 0;

	AudioUnitSetProperty (_rioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, & ioFormat, sizeof (ioFormat));
	AudioUnitSetProperty (_rioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, & ioFormat, sizeof (ioFormat));
	
	// Set the MaximumFramesPerSlice property. This property is used to describe to an audio unit the maximum number
	// of samples it will be asked to produce on any single given call to AudioUnitRender
	UInt32 maxFramesPerSlice = 4096;
	AudioUnitSetProperty (_rioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, & maxFramesPerSlice, sizeof (UInt32));
	
	// Get the property value back from AURemoteIO. We are going to use this value to allocate buffers accordingly
	UInt32 propSize = sizeof (UInt32);
	AudioUnitGetProperty (_rioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, & maxFramesPerSlice, & propSize);
	
	// We need references to certain data in the render callback
	// This simple struct is used to hold that information
	
	cd.rioUnit = _rioUnit;
	cd.audioChainIsBeingReconstructed = &_audioChainIsBeingReconstructed;
	
	// Set the render callback on AURemoteIO
	AURenderCallbackStruct renderCallback;
	renderCallback.inputProc = performRender;
	renderCallback.inputProcRefCon = NULL;
	AudioUnitSetProperty (_rioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, & renderCallback, sizeof (renderCallback));
	
	// Initialize the AURemoteIO instance
	AudioUnitInitialize (_rioUnit);
}

- (void)setupAudioChain
{
    //[self setupAudioSession];
    [self setupIOUnit];
}

- (OSStatus)startIOUnit
{
    OSStatus err = AudioOutputUnitStart(_rioUnit);
    if (err) NSLog(@"couldn't start AURemoteIO: %d", (int)err);
    return err;
}

- (OSStatus)stopIOUnit
{
    OSStatus err = AudioOutputUnitStop(_rioUnit);
    if (err) NSLog(@"couldn't stop AURemoteIO: %d", (int)err);
    return err;
}

- (double)sessionSampleRate
{
    return [[AVAudioSession sharedInstance] sampleRate];
}

- (BOOL)audioChainIsBeingReconstructed
{
    return _audioChainIsBeingReconstructed;
}

- (void)dealloc
{
    _audioPlayer = nil;
}

@end