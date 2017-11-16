#import "CameraPlugin.h"
#import <AVFoundation/AVFoundation.h>
#import <libkern/OSAtomic.h>

@interface SavePhotoDelegate : NSObject <AVCapturePhotoCaptureDelegate>
@property(readonly, nonatomic) NSString *filename;
@property(readonly, nonatomic) FlutterResult result;
@property(readonly, nonatomic) id selfProperty;

- initWithFilename:(NSString *)filename result:(FlutterResult)result;
@end

@implementation SavePhotoDelegate
- initWithFilename:(NSString *)filename result:(FlutterResult)result
{
  self = [super init];
  _filename = filename;
  _result = result;
  _selfProperty = self;
  return self;
}

- (NSString *)writeData:(NSData *)data
{
  NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
  NSString *documentsDirectory = [paths objectAtIndex:0];
  NSString *filePath = [NSString stringWithFormat:@"%@/%@.jpeg", documentsDirectory, _filename];
  // TODO(sigurdm): Consider writing file asynchronously.
  [data writeToFile:filePath atomically:YES];
  return filePath;
}

- (void)captureOutput:(AVCapturePhotoOutput *)output
    didFinishProcessingPhotoSampleBuffer:(CMSampleBufferRef)photoSampleBuffer
                previewPhotoSampleBuffer:(CMSampleBufferRef)previewPhotoSampleBuffer
                        resolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings
                         bracketSettings:(AVCaptureBracketedStillImageSettings *)bracketSettings
                                   error:(NSError *)error
{
  _selfProperty = nil;
  _result([self
      writeData:[AVCapturePhotoOutput
                    JPEGPhotoDataRepresentationForJPEGSampleBuffer:photoSampleBuffer
                                          previewPhotoSampleBuffer:previewPhotoSampleBuffer]]);
}
@end

@interface Cam : NSObject <FlutterTexture, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureMetadataOutputObjectsDelegate>
@property(readonly, nonatomic) int64_t textureId;
@property(nonatomic, copy) void (^onFrameAvailable)();
@property(readonly, nonatomic) AVCaptureSession *captureSession;
@property(readonly, nonatomic) AVCaptureDevice *captureDevice;
@property(readonly, nonatomic) AVCapturePhotoOutput *capturePhotoOutput;
@property(readonly, nonatomic) AVCaptureMetadataOutput *captureMetadataOutput;
@property(readonly, nonatomic) dispatch_queue_t queue;
@property(readonly, nonatomic) dispatch_semaphore_t closingSemaphore;
@property(readonly) CVPixelBufferRef volatile latestPixelBuffer;

- (instancetype)initWithCameraName:(NSString *)cameraName result:(FlutterResult)result;
- (void)start;
- (void)stop;
- (void)captureToFile:(NSString *)filename result:(FlutterResult)result;
@end

@implementation Cam
- (instancetype)initWithCameraName:(NSString *)cameraName result:(FlutterResult)result
{
  self = [super init];
  NSAssert(self, @"super init cannot be nil");
  _captureSession = [[AVCaptureSession alloc] init];
  _captureSession.sessionPreset = AVCaptureSessionPresetHigh;
  _captureDevice = [AVCaptureDevice deviceWithUniqueID:cameraName];
  NSError *error = nil;
  AVCaptureInput *input = [AVCaptureDeviceInput deviceInputWithDevice:_captureDevice error:&error];
  if (!input)
  {
    result([FlutterError errorWithCode:@"device error"
                               message:@"Not able to access camera"
                               details:nil]);
    return nil;
  }

  AVCaptureVideoDataOutput *output = [AVCaptureVideoDataOutput new];
  output.videoSettings =
      @{(NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) };
  [output setAlwaysDiscardsLateVideoFrames:YES];
  [output setSampleBufferDelegate:self queue:dispatch_get_main_queue()];

  AVCaptureConnection *connection =
      [AVCaptureConnection connectionWithInputPorts:input.ports output:output];
  if ([_captureDevice position] == AVCaptureDevicePositionFront)
  {
    connection.videoMirrored = YES;
  }
  connection.videoOrientation = AVCaptureVideoOrientationPortrait;
  [_captureSession addInputWithNoConnections:input];
  [_captureSession addOutputWithNoConnections:output];
  [_captureSession addConnection:connection];

  _capturePhotoOutput = [AVCapturePhotoOutput new];
  [_captureSession addOutput:_capturePhotoOutput];

  _captureMetadataOutput = [AVCaptureMetadataOutput new];
  [_captureMetadataOutput setMetadataObjectsDelegate:self queue:dispatch_get_main_queue()];
  [_captureSession addOutput:_captureMetadataOutput];
  _captureMetadataOutput.metadataObjectTypes = @[AVMetadataObjectTypeQRCode];

  return self;
}

- (void)start
{
  [_captureSession startRunning];
}

- (void)stop
{
  [_captureSession stopRunning];
}

- (void)captureToFile:(NSString *)filename result:(FlutterResult)result
{
  AVCapturePhotoSettings *settings = [AVCapturePhotoSettings photoSettings];
  [_capturePhotoOutput
      capturePhotoWithSettings:settings
                      delegate:[[SavePhotoDelegate alloc] initWithFilename:filename result:result]];
}

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection
{
  CVPixelBufferRef newBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  CFRetain(newBuffer);
  CVPixelBufferRef old = _latestPixelBuffer;
  while (!OSAtomicCompareAndSwapPtrBarrier(old, newBuffer, (void **)&_latestPixelBuffer))
  {
    old = _latestPixelBuffer;
  }
  if (old != nil)
  {
    CFRelease(old);
  }
  if (_onFrameAvailable)
  {
    _onFrameAvailable();
  }
}

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputMetadataObjects:(NSArray<AVMetadataObject *> *)metadataObjects
              fromConnection:(AVCaptureConnection *)connection
{
  for (AVMetadataObject *metadata in metadataObjects)
  {
    NSString *detectionString = [(AVMetadataMachineReadableCodeObject *)metadata stringValue];
    NSLog(@"%@", detectionString);
  }
}

- (void)close
{
  [_captureSession stopRunning];
  for (AVCaptureInput *input in [_captureSession inputs])
  {
    [_captureSession removeInput:input];
  }
  for (AVCaptureOutput *output in [_captureSession outputs])
  {
    [_captureSession removeOutput:output];
  }
}

- (void)dealloc
{
  if (_latestPixelBuffer)
  {
    CFRelease(_latestPixelBuffer);
  }
}

- (CVPixelBufferRef)copyPixelBuffer
{
  CVPixelBufferRef pixelBuffer = _latestPixelBuffer;
  while (!OSAtomicCompareAndSwapPtrBarrier(pixelBuffer, nil, (void **)&_latestPixelBuffer))
  {
    pixelBuffer = _latestPixelBuffer;
  }
  return pixelBuffer;
}
@end

@interface CameraPlugin ()
@property(readonly, nonatomic) NSObject<FlutterTextureRegistry> *registry;
@property(readonly, nonatomic) NSMutableDictionary *cams;
@end

@implementation CameraPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar
{
  FlutterMethodChannel *channel =
      [FlutterMethodChannel methodChannelWithName:@"camera" binaryMessenger:[registrar messenger]];
  CameraPlugin *instance = [[CameraPlugin alloc] initWithRegistry:[registrar textures]];
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (instancetype)initWithRegistry:(NSObject<FlutterTextureRegistry> *)registry
{
  self = [super init];
  NSAssert(self, @"super init cannot be nil");
  _registry = registry;
  _cams = [NSMutableDictionary dictionaryWithCapacity:1];
  return self;
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result
{
  if ([@"list" isEqualToString:call.method])
  {
    AVCaptureDeviceDiscoverySession *discoverySession = [AVCaptureDeviceDiscoverySession
        discoverySessionWithDeviceTypes:@[ AVCaptureDeviceTypeBuiltInWideAngleCamera ]
                              mediaType:AVMediaTypeVideo
                               position:AVCaptureDevicePositionUnspecified];
    NSArray<AVCaptureDevice *> *devices = discoverySession.devices;
    NSMutableArray<NSDictionary<NSString *, NSObject *> *> *reply =
        [[NSMutableArray alloc] initWithCapacity:devices.count];
    for (AVCaptureDevice *device in devices)
    {
      NSString *lensFacing;
      switch ([device position])
      {
        case AVCaptureDevicePositionBack:
          lensFacing = @"back";
          break;
        case AVCaptureDevicePositionFront:
          lensFacing = @"front";
          break;
        case AVCaptureDevicePositionUnspecified:
          lensFacing = @"external";
          break;
      }
      NSMutableArray<NSDictionary<NSString *, NSObject *> *> *previewFormats =
          [[NSMutableArray alloc] init];
      NSMutableArray<NSDictionary<NSString *, NSObject *> *> *captureFormats =
          [[NSMutableArray alloc] init];
      // TODO(sigurdm): Replace these placeholders with real world values from:
      // https://developer.apple.com/library/content/documentation/DeviceInformation/Reference/iOSDeviceCompatibility/Cameras/Cameras.html
      [previewFormats addObject:@{
        @"width" : @(640),
        @"height" : @(480),
        @"frameDuration" : @(3333)
      }];
      [captureFormats addObject:@{
        @"width" : @(640),
        @"height" : @(480),
        @"frameDuration" : @(3333)
      }];
      [reply addObject:@{
        @"name" : [device uniqueID],
        @"lensFacing" : lensFacing,
        @"previewFormats" : previewFormats,
        @"captureFormats" : captureFormats
      }];
    }
    result(reply);
  }
  else if ([@"create" isEqualToString:call.method])
  {
    NSString *cameraName = call.arguments[@"cameraName"];
    Cam *cam = [[Cam alloc] initWithCameraName:cameraName result:result];
    if (cam != nil)
    {
      int64_t textureId = [_registry registerTexture:cam];
      _cams[@(textureId)] = cam;
      NSLog(@"Got texture id %@", @(textureId));
      cam.onFrameAvailable = ^{
        [_registry textureFrameAvailable:textureId];
      };
      result(@(textureId));
    }
  }
  else
  {
    NSDictionary *argsMap = call.arguments;
    NSUInteger textureId = ((NSNumber *)argsMap[@"textureId"]).unsignedIntegerValue;
    Cam *cam = _cams[@(textureId)];
    if ([@"start" isEqualToString:call.method])
    {
      [cam start];
      result(@YES);
    }
    else if ([@"stop" isEqualToString:call.method])
    {
      [cam stop];
      result(@YES);
    }
    else if ([@"capture" isEqualToString:call.method])
    {
      [cam captureToFile:call.arguments[@"filename"] result:result];
    }
    else if ([@"dispose" isEqualToString:call.method])
    {
      [cam close];
      // TODO(sigurdm): Realize why we get a double release here.
      // [_registry unregisterTexture:textureId];
      [_cams removeObjectForKey:@(textureId)];

      result(@YES);
    }
    else
    {
      result(FlutterMethodNotImplemented);
    }
  }
}

@end
