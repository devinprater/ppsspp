#import "ios/AccessibilityBridge.h"

#import <GameController/GameController.h>

#include <cstdint>
#include <vector>

#include "Common/Input/InputState.h"
#include "Common/Log.h"
#include "Common/System/Display.h"
#include "Common/System/NativeApp.h"
#include "Common/UI/Accessibility.h"
#include "Core/System.h"

@class PPSSPPAccessibilityBridge;

typedef NS_ENUM(NSInteger, PPSSPPAccessibilityAction) {
	PPSSPPAccessibilityActionNone,
	PPSSPPAccessibilityActionActivateUI,
	PPSSPPAccessibilityActionDPad,
	PPSSPPAccessibilityActionLeftStick,
	PPSSPPAccessibilityActionRightStick,
	PPSSPPAccessibilityActionFaceButtons,
	PPSSPPAccessibilityActionShoulders,
	PPSSPPAccessibilityActionSelect,
	PPSSPPAccessibilityActionEmulatorMenu,
};

@interface PPSSPPAccessibilityElement : UIAccessibilityElement
@property(nonatomic, weak) PPSSPPAccessibilityBridge *bridge;
@property(nonatomic) PPSSPPAccessibilityAction action;
@property(nonatomic) int accessibilityId;
@property(nonatomic) CGRect dpFrame;
@end

@interface PPSSPPAccessibilityBridge () {
	__weak UIView *_view;
	NSMutableArray *_elements;
	NSTimer *_refreshTimer;
	NSString *_lastSignature;
	uint64_t _lastSnapshotVersion;
	uint64_t _lastScreenVersion;
	int _lastUIState;
	CGRect _lastViewBounds;
	float _lastDPXRes;
	float _lastDPYRes;
	InputKeyCode _lastShoulderKey;
	InputKeyCode _heldShoulderKey;
	BOOL _refreshQueued;
	BOOL _hasBuiltElements;
	BOOL _gameViewportFocused;
	BOOL _lastExternalControllerConnected;
	NSTimeInterval _lastGameViewportDescriptionRefresh;
}
- (BOOL)activateElement:(PPSSPPAccessibilityElement *)element;
- (BOOL)scrollElement:(PPSSPPAccessibilityElement *)element direction:(UIAccessibilityScrollDirection)direction;
- (void)adjustElement:(PPSSPPAccessibilityElement *)element increment:(BOOL)increment;
- (void)gameViewportFocusChanged:(BOOL)focused;
- (void)refreshFocusedGameViewportDescription;
- (void)logRefreshWithReason:(NSString *)reason elementCount:(NSUInteger)elementCount snapshotVersion:(uint64_t)snapshotVersion;
@end

@implementation PPSSPPAccessibilityElement

- (BOOL)accessibilityActivate {
	return [self.bridge activateElement:self];
}

- (BOOL)accessibilityScroll:(UIAccessibilityScrollDirection)direction {
	return [self.bridge scrollElement:self direction:direction];
}

- (void)accessibilityIncrement {
	[self.bridge adjustElement:self increment:YES];
}

- (void)accessibilityDecrement {
	[self.bridge adjustElement:self increment:NO];
}

- (void)accessibilityElementDidBecomeFocused {
	if (self.action == PPSSPPAccessibilityActionNone) {
		[self.bridge gameViewportFocusChanged:YES];
	}
}

- (void)accessibilityElementDidLoseFocus {
	if (self.action == PPSSPPAccessibilityActionNone) {
		[self.bridge gameViewportFocusChanged:NO];
	}
}

@end

static void SendKey(InputKeyCode keyCode, bool down, InputDeviceID deviceId = DEVICE_ID_TOUCH) {
	KeyInput key{};
	key.deviceId = deviceId;
	key.keyCode = keyCode;
	key.flags = down ? KeyInputFlags::DOWN : KeyInputFlags::UP;
	NativeKey(key);
}

static void TapKey(InputKeyCode keyCode, InputDeviceID deviceId = DEVICE_ID_TOUCH) {
	SendKey(keyCode, true, deviceId);
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(80 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
		SendKey(keyCode, false, deviceId);
	});
}

static void SendAxis(InputAxis axisId, float value) {
	AxisInput axis{};
	axis.deviceId = DEVICE_ID_PAD_0;
	axis.axisId = axisId;
	axis.value = value;
	NativeAxis(&axis, 1);
}

static void TapAxis(InputAxis axisId, float value) {
	SendAxis(axisId, value);
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(80 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
		SendAxis(axisId, 0.0f);
	});
}

static const char *AccessibilityScrollDirectionName(UIAccessibilityScrollDirection direction) {
	switch (direction) {
	case UIAccessibilityScrollDirectionRight: return "Right";
	case UIAccessibilityScrollDirectionLeft: return "Left";
	case UIAccessibilityScrollDirectionUp: return "Up";
	case UIAccessibilityScrollDirectionDown: return "Down";
	case UIAccessibilityScrollDirectionNext: return "Next";
	case UIAccessibilityScrollDirectionPrevious: return "Previous";
	default: return "Unknown";
	}
}

static UIAccessibilityScrollDirection FingerDirectionFromAccessibilityScrollDirection(UIAccessibilityScrollDirection direction) {
	switch (direction) {
	case UIAccessibilityScrollDirectionRight: return UIAccessibilityScrollDirectionLeft;
	case UIAccessibilityScrollDirectionLeft: return UIAccessibilityScrollDirectionRight;
	case UIAccessibilityScrollDirectionUp: return UIAccessibilityScrollDirectionDown;
	case UIAccessibilityScrollDirectionDown: return UIAccessibilityScrollDirectionUp;
	default: return direction;
	}
}

static void TapAccessibilityFaceButton(UIAccessibilityScrollDirection direction, InputKeyCode keyCode, const char *pspButton) {
	NSLog(@"PPSSPPAccessibility action Face buttons direction=%s key=%d psp=%s",
		AccessibilityScrollDirectionName(direction), (int)keyCode, pspButton);
	NOTICE_LOG(Log::UI, "PPSSPPAccessibility action Face buttons direction=%s key=%d psp=%s",
		AccessibilityScrollDirectionName(direction), (int)keyCode, pspButton);
	TapKey(keyCode, DEVICE_ID_PAD_0);
}

static UIAccessibilityTraits TraitsForRole(UI::AccessibilityRole role) {
	switch (role) {
	case UI::AccessibilityRole::Button:
	case UI::AccessibilityRole::Choice:
	case UI::AccessibilityRole::GamepadControl:
		return UIAccessibilityTraitButton;
	case UI::AccessibilityRole::Tab:
		return UIAccessibilityTraitButton | UIAccessibilityTraitTabBar;
	case UI::AccessibilityRole::Checkbox:
	case UI::AccessibilityRole::Radio:
		return UIAccessibilityTraitButton;
	case UI::AccessibilityRole::Slider:
		return UIAccessibilityTraitAdjustable;
	case UI::AccessibilityRole::TextField:
		return UIAccessibilityTraitNone;
	case UI::AccessibilityRole::Progress:
		return UIAccessibilityTraitUpdatesFrequently;
	case UI::AccessibilityRole::Heading:
		return UIAccessibilityTraitHeader;
	case UI::AccessibilityRole::Image:
		return UIAccessibilityTraitImage;
	case UI::AccessibilityRole::StaticText:
	default:
		return UIAccessibilityTraitStaticText;
	}
}

static UIAccessibilityTraits TraitsForInfo(const UI::AccessibilityElementInfo &info) {
	UIAccessibilityTraits traits = TraitsForRole(info.role);
	if (!info.enabled) {
		traits |= UIAccessibilityTraitNotEnabled;
	}
	if (info.checked || info.selected) {
		traits |= UIAccessibilityTraitSelected;
	}
	return traits;
}

static BOOL HasExternalGameController() {
	return [GCController controllers].count > 0;
}

@implementation PPSSPPAccessibilityBridge

- (instancetype)initWithView:(UIView *)view {
	self = [super init];
	if (self) {
		_view = view;
		_elements = [[NSMutableArray alloc] init];
		_lastSnapshotVersion = 0;
		_lastScreenVersion = 0;
		_lastUIState = -1;
		_lastViewBounds = CGRectNull;
		_lastDPXRes = 0.0f;
		_lastDPYRes = 0.0f;
		_lastShoulderKey = NKCODE_UNKNOWN;
		_heldShoulderKey = NKCODE_UNKNOWN;
		_gameViewportFocused = NO;
		_lastExternalControllerConnected = NO;
		_lastGameViewportDescriptionRefresh = 0.0;
		view.isAccessibilityElement = NO;
		view.accessibilityElements = _elements;
		UI::SetAccessibilityEnabled(UIAccessibilityIsVoiceOverRunning());
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(voiceOverStatusChanged:) name:UIAccessibilityVoiceOverStatusDidChangeNotification object:nil];
		_refreshTimer = [NSTimer timerWithTimeInterval:0.05 target:self selector:@selector(periodicRefresh:) userInfo:nil repeats:YES];
		[[NSRunLoop mainRunLoop] addTimer:_refreshTimer forMode:NSRunLoopCommonModes];
	}
	return self;
}

- (void)dealloc {
	[_refreshTimer invalidate];
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[self releaseHeldShoulder];
	UI::SetAccessibilityEnabled(false);
}

- (void)voiceOverStatusChanged:(NSNotification *)notification {
	UI::SetAccessibilityEnabled(UIAccessibilityIsVoiceOverRunning());
	[self scheduleRefresh];
}

- (void)periodicRefresh:(NSTimer *)timer {
	if (UIAccessibilityIsVoiceOverRunning()) {
		[self scheduleRefresh];
		[self refreshFocusedGameViewportDescription];
	}
}

- (void)scheduleRefresh {
	if (_refreshQueued) {
		return;
	}
	_refreshQueued = YES;
	dispatch_async(dispatch_get_main_queue(), ^{
		self->_refreshQueued = NO;
		[self refresh];
	});
}

- (CGRect)uiFrameFromDPBounds:(const Bounds &)bounds {
	UIView *view = _view;
	if (!view || g_display.dp_xres <= 0 || g_display.dp_yres <= 0) {
		return CGRectZero;
	}
	const CGFloat xScale = view.bounds.size.width / (CGFloat)g_display.dp_xres;
	const CGFloat yScale = view.bounds.size.height / (CGFloat)g_display.dp_yres;
	CGRect local = CGRectMake(bounds.x * xScale, bounds.y * yScale, bounds.w * xScale, bounds.h * yScale);
	return [view.window convertRect:local fromView:view];
}

- (PPSSPPAccessibilityElement *)makeElementWithLabel:(NSString *)label
											 frame:(CGRect)frame
										  dpFrame:(CGRect)dpFrame
										   action:(PPSSPPAccessibilityAction)action
										   traits:(UIAccessibilityTraits)traits {
	PPSSPPAccessibilityElement *element = [[PPSSPPAccessibilityElement alloc] initWithAccessibilityContainer:_view];
	element.bridge = self;
	element.action = action;
	element.accessibilityLabel = label;
	element.accessibilityFrame = frame;
	element.dpFrame = dpFrame;
	element.accessibilityTraits = traits;
	return element;
}

- (void)addInGameControls {
	UIView *view = _view;
	if (!view || g_display.dp_xres <= 0 || g_display.dp_yres <= 0) {
		return;
	}

	struct ControlArea {
		__unsafe_unretained NSString *label;
		PPSSPPAccessibilityAction action;
		CGRect dpFrame;
	};
	const CGFloat w = (CGFloat)g_display.dp_xres;
	const CGFloat h = (CGFloat)g_display.dp_yres;
	const CGFloat thirdW = w / 3.0f;
	const CGFloat viewportH = h * 0.62f;
	const CGFloat controlTop = viewportH;
	const CGFloat controlH = h - controlTop;
	const CGFloat rowH = controlH / 3.0f;
	const BOOL externalControllerConnected = HasExternalGameController();

	if (!externalControllerConnected) {
		const ControlArea controls[] = {
			{ @"D-pad", PPSSPPAccessibilityActionDPad, CGRectMake(0.0f, controlTop, thirdW, rowH * 2.0f) },
			{ @"Left stick", PPSSPPAccessibilityActionLeftStick, CGRectMake(0.0f, controlTop + rowH * 2.0f, thirdW, rowH) },
			{ @"Shoulder buttons", PPSSPPAccessibilityActionShoulders, CGRectMake(thirdW, controlTop, thirdW, rowH) },
			{ @"Select", PPSSPPAccessibilityActionSelect, CGRectMake(thirdW, controlTop + rowH, thirdW * 0.5f, rowH) },
			{ @"Emulator menu", PPSSPPAccessibilityActionEmulatorMenu, CGRectMake(thirdW * 1.5f, controlTop + rowH, thirdW * 0.5f, rowH) },
			{ @"Right stick", PPSSPPAccessibilityActionRightStick, CGRectMake(thirdW, controlTop + rowH * 2.0f, thirdW, rowH) },
			{ @"Face buttons", PPSSPPAccessibilityActionFaceButtons, CGRectMake(thirdW * 2.0f, controlTop, thirdW, controlH) },
		};

		for (const ControlArea &control : controls) {
			Bounds bounds(control.dpFrame.origin.x, control.dpFrame.origin.y, control.dpFrame.size.width, control.dpFrame.size.height);
			PPSSPPAccessibilityElement *element = [self makeElementWithLabel:control.label
																		frame:[self uiFrameFromDPBounds:bounds]
																	  dpFrame:control.dpFrame
																	   action:control.action
																	   traits:UIAccessibilityTraitButton];
			if (control.action == PPSSPPAccessibilityActionDPad ||
				control.action == PPSSPPAccessibilityActionLeftStick ||
				control.action == PPSSPPAccessibilityActionRightStick ||
				control.action == PPSSPPAccessibilityActionFaceButtons ||
				control.action == PPSSPPAccessibilityActionShoulders) {
				element.accessibilityHint = @"Swipe up, down, left, or right.";
			}
			[_elements addObject:element];
		}
	}

	const CGRect viewportFrame = externalControllerConnected ?
		CGRectMake(0.0f, 0.0f, w, h) :
		CGRectMake(0.0f, 0.0f, w, viewportH);
	Bounds viewportBounds(viewportFrame.origin.x, viewportFrame.origin.y, viewportFrame.size.width, viewportFrame.size.height);
	PPSSPPAccessibilityElement *viewport = [self makeElementWithLabel:@"Game viewport"
																frame:[self uiFrameFromDPBounds:viewportBounds]
															  dpFrame:viewportFrame
															   action:PPSSPPAccessibilityActionNone
															   traits:UIAccessibilityTraitImage | UIAccessibilityTraitUpdatesFrequently];
	[_elements addObject:viewport];
	NSLog(@"PPSSPPAccessibility ingame externalController=%d viewport=%@ elements=%lu",
		externalControllerConnected, NSStringFromCGRect(viewportFrame), (unsigned long)_elements.count);
}

- (void)gameViewportFocusChanged:(BOOL)focused {
	_gameViewportFocused = focused;
	if (focused) {
		_lastGameViewportDescriptionRefresh = 0.0;
	}
}

- (void)refreshFocusedGameViewportDescription {
	if (!_gameViewportFocused || GetUIState() != UISTATE_INGAME) {
		return;
	}
	const NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
	if (now - _lastGameViewportDescriptionRefresh < 3.0) {
		return;
	}
	for (PPSSPPAccessibilityElement *element in _elements) {
		if (element.action == PPSSPPAccessibilityActionNone) {
			_lastGameViewportDescriptionRefresh = now;
			UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, element);
			return;
		}
	}
}

- (void)refresh {
	UIView *view = _view;
	if (!view) {
		return;
	}
	if (!UIAccessibilityIsVoiceOverRunning()) {
		[_elements removeAllObjects];
		_lastSignature = nil;
		_hasBuiltElements = NO;
		view.accessibilityElements = _elements;
		return;
	}
	const int uiState = (int)GetUIState();
	const CGRect viewBounds = view.bounds;
	const bool geometryChanged = !CGRectEqualToRect(_lastViewBounds, viewBounds) ||
		_lastDPXRes != g_display.dp_xres || _lastDPYRes != g_display.dp_yres;
	const BOOL externalControllerConnected = HasExternalGameController();
	const BOOL controllerChanged = _hasBuiltElements && _lastExternalControllerConnected != externalControllerConnected;

	if (uiState == UISTATE_INGAME) {
		if (_hasBuiltElements && _lastUIState == uiState && !geometryChanged && !controllerChanged) {
			return;
		}
		NSMutableArray *newElements = [[NSMutableArray alloc] init];
		NSMutableString *signature = [[NSMutableString alloc] init];
		NSMutableArray *oldElements = _elements;
		_gameViewportFocused = NO;
		_elements = newElements;
		[self addInGameControls];
		[signature appendString:@"ingame"];
		for (PPSSPPAccessibilityElement *element in _elements) {
			[signature appendFormat:@"|%@:%@", element.accessibilityLabel, NSStringFromCGRect(element.accessibilityFrame)];
		}
		if (![_lastSignature isEqualToString:signature]) {
			_lastSignature = [signature copy];
			view.accessibilityElements = _elements;
			UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, nil);
			[self logRefreshWithReason:@"ingame" elementCount:_elements.count snapshotVersion:_lastSnapshotVersion];
		} else {
			_elements = oldElements;
		}
		_hasBuiltElements = YES;
		_lastUIState = uiState;
		_lastViewBounds = viewBounds;
		_lastDPXRes = g_display.dp_xres;
		_lastDPYRes = g_display.dp_yres;
		_lastExternalControllerConnected = externalControllerConnected;
		return;
	}

	[self releaseHeldShoulder];
	const uint64_t snapshotVersion = UI::GetCachedAccessibilitySnapshotVersion();
	const uint64_t screenVersion = UI::GetCachedAccessibilityScreenVersion();
	const BOOL screenChanged = _hasBuiltElements && _lastScreenVersion != screenVersion;
	if (_hasBuiltElements && _lastUIState == uiState && !geometryChanged && _lastSnapshotVersion == snapshotVersion && !screenChanged) {
		return;
	}
	std::vector<UI::AccessibilityElementInfo> snapshot;
	if (g_display.dp_xres > 0 && g_display.dp_yres > 0) {
		snapshot = UI::GetCachedAccessibilitySnapshot();
	}
	const BOOL canReuseElements = _hasBuiltElements && _lastUIState == uiState && _elements.count == snapshot.size();
	if (canReuseElements) {
		for (NSUInteger i = 0; i < snapshot.size(); ++i) {
			const UI::AccessibilityElementInfo &info = snapshot[i];
			NSString *label = [NSString stringWithUTF8String:info.label.c_str()];
			CGRect frame = [self uiFrameFromDPBounds:info.bounds];
			CGRect dpFrame = CGRectMake(info.bounds.x, info.bounds.y, info.bounds.w, info.bounds.h);
			PPSSPPAccessibilityElement *element = [_elements objectAtIndex:i];
			element.accessibilityId = info.id;
			element.accessibilityLabel = label;
			element.accessibilityValue = [NSString stringWithUTF8String:info.value.c_str()];
			element.accessibilityFrame = frame;
			element.dpFrame = dpFrame;
			element.accessibilityTraits = TraitsForInfo(info);
		}
	} else {
		NSMutableArray *newElements = [[NSMutableArray alloc] initWithCapacity:snapshot.size()];
		for (const UI::AccessibilityElementInfo &info : snapshot) {
			NSString *label = [NSString stringWithUTF8String:info.label.c_str()];
			CGRect frame = [self uiFrameFromDPBounds:info.bounds];
			CGRect dpFrame = CGRectMake(info.bounds.x, info.bounds.y, info.bounds.w, info.bounds.h);
			PPSSPPAccessibilityElement *element = [self makeElementWithLabel:label
																		frame:frame
																	  dpFrame:dpFrame
																	   action:PPSSPPAccessibilityActionActivateUI
																	   traits:TraitsForInfo(info)];
			element.accessibilityId = info.id;
			element.accessibilityValue = [NSString stringWithUTF8String:info.value.c_str()];
			[newElements addObject:element];
		}
		_elements = newElements;
		view.accessibilityElements = _elements;
		if (!screenChanged) {
			UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, nil);
		}
		[self logRefreshWithReason:@"ui" elementCount:_elements.count snapshotVersion:snapshotVersion];
	}
	if (screenChanged) {
		UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, [_elements firstObject]);
	}
	_lastSignature = nil;
	_hasBuiltElements = YES;
	_lastSnapshotVersion = snapshotVersion;
	_lastScreenVersion = screenVersion;
	_lastUIState = uiState;
	_lastViewBounds = viewBounds;
	_lastDPXRes = g_display.dp_xres;
	_lastDPYRes = g_display.dp_yres;
	_lastExternalControllerConnected = externalControllerConnected;
}

- (void)logRefreshWithReason:(NSString *)reason elementCount:(NSUInteger)elementCount snapshotVersion:(uint64_t)snapshotVersion {
	NSMutableString *labels = [[NSMutableString alloc] init];
	const NSUInteger limit = MIN(elementCount, (NSUInteger)20);
	for (NSUInteger i = 0; i < limit; ++i) {
		PPSSPPAccessibilityElement *element = [_elements objectAtIndex:i];
		NSString *label = element.accessibilityLabel ?: @"<nil>";
		if (label.length == 0) {
			label = @"<empty>";
		}
		[labels appendFormat:@"%@%@",
			i == 0 ? @"" : @", ",
			label];
	}
	NSLog(@"PPSSPPAccessibility refresh reason=%@ state=%d version=%llu count=%lu labels=[%@]",
		reason, _lastUIState, (unsigned long long)snapshotVersion, (unsigned long)elementCount, labels);
	NOTICE_LOG(Log::UI, "PPSSPPAccessibility refresh reason=%s state=%d version=%llu count=%lu",
		[reason UTF8String], _lastUIState, (unsigned long long)snapshotVersion, (unsigned long)elementCount);
}

- (void)releaseHeldShoulder {
	if (_heldShoulderKey != NKCODE_UNKNOWN) {
		SendKey(_heldShoulderKey, false, DEVICE_ID_PAD_0);
		_heldShoulderKey = NKCODE_UNKNOWN;
	}
}

- (void)reset {
	[self releaseHeldShoulder];
	_lastShoulderKey = NKCODE_UNKNOWN;
	[_elements removeAllObjects];
	_lastSignature = nil;
	_hasBuiltElements = NO;
	if (_view) {
		_view.accessibilityElements = _elements;
	}
}

- (void)uiStateChanged {
	if (GetUIState() != UISTATE_INGAME) {
		[self releaseHeldShoulder];
	}
	[self scheduleRefresh];
}

- (void)willResignActive {
	[self releaseHeldShoulder];
}

- (BOOL)activateElement:(PPSSPPAccessibilityElement *)element {
	switch (element.action) {
	case PPSSPPAccessibilityActionActivateUI: {
		return UI::PerformAccessibilityClick(element.accessibilityId, false);
	}
	case PPSSPPAccessibilityActionShoulders:
		if (_lastShoulderKey == NKCODE_UNKNOWN) {
			return NO;
		}
		if (_heldShoulderKey == _lastShoulderKey) {
			[self releaseHeldShoulder];
		} else {
			[self releaseHeldShoulder];
			SendKey(_lastShoulderKey, true, DEVICE_ID_PAD_0);
			_heldShoulderKey = _lastShoulderKey;
		}
		return YES;
	case PPSSPPAccessibilityActionSelect:
		TapKey(NKCODE_BUTTON_SELECT, DEVICE_ID_PAD_0);
		return YES;
	case PPSSPPAccessibilityActionEmulatorMenu:
		TapKey(NKCODE_BACK);
		return YES;
	default:
		return NO;
	}
}

- (void)adjustElement:(PPSSPPAccessibilityElement *)element increment:(BOOL)increment {
	if (element.action != PPSSPPAccessibilityActionActivateUI) {
		return;
	}
	if (!NativeAccessibilityFocus(element.accessibilityId)) {
		return;
	}
	TapKey(increment ? NKCODE_DPAD_RIGHT : NKCODE_DPAD_LEFT);
}

- (BOOL)scrollElement:(PPSSPPAccessibilityElement *)element direction:(UIAccessibilityScrollDirection)direction {
	const UIAccessibilityScrollDirection fingerDirection = FingerDirectionFromAccessibilityScrollDirection(direction);
	switch (element.action) {
	case PPSSPPAccessibilityActionDPad:
		switch (fingerDirection) {
		case UIAccessibilityScrollDirectionLeft: TapKey(NKCODE_DPAD_LEFT, DEVICE_ID_PAD_0); return YES;
		case UIAccessibilityScrollDirectionRight: TapKey(NKCODE_DPAD_RIGHT, DEVICE_ID_PAD_0); return YES;
		case UIAccessibilityScrollDirectionUp: TapKey(NKCODE_DPAD_UP, DEVICE_ID_PAD_0); return YES;
		case UIAccessibilityScrollDirectionDown: TapKey(NKCODE_DPAD_DOWN, DEVICE_ID_PAD_0); return YES;
		default: return NO;
		}
	case PPSSPPAccessibilityActionLeftStick:
		switch (fingerDirection) {
		case UIAccessibilityScrollDirectionLeft: TapAxis(JOYSTICK_AXIS_X, -1.0f); return YES;
		case UIAccessibilityScrollDirectionRight: TapAxis(JOYSTICK_AXIS_X, 1.0f); return YES;
		case UIAccessibilityScrollDirectionUp: TapAxis(JOYSTICK_AXIS_Y, -1.0f); return YES;
		case UIAccessibilityScrollDirectionDown: TapAxis(JOYSTICK_AXIS_Y, 1.0f); return YES;
		default: return NO;
		}
	case PPSSPPAccessibilityActionRightStick:
		switch (fingerDirection) {
		case UIAccessibilityScrollDirectionLeft: TapAxis(JOYSTICK_AXIS_Z, -1.0f); return YES;
		case UIAccessibilityScrollDirectionRight: TapAxis(JOYSTICK_AXIS_Z, 1.0f); return YES;
		case UIAccessibilityScrollDirectionUp: TapAxis(JOYSTICK_AXIS_RZ, -1.0f); return YES;
		case UIAccessibilityScrollDirectionDown: TapAxis(JOYSTICK_AXIS_RZ, 1.0f); return YES;
		default: return NO;
		}
	case PPSSPPAccessibilityActionFaceButtons:
		switch (fingerDirection) {
		case UIAccessibilityScrollDirectionLeft: TapAccessibilityFaceButton(fingerDirection, NKCODE_BUTTON_4, "Square"); return YES;
		case UIAccessibilityScrollDirectionRight: TapAccessibilityFaceButton(fingerDirection, NKCODE_BUTTON_3, "Circle"); return YES;
		case UIAccessibilityScrollDirectionUp: TapAccessibilityFaceButton(fingerDirection, NKCODE_BUTTON_1, "Triangle"); return YES;
		case UIAccessibilityScrollDirectionDown: TapAccessibilityFaceButton(fingerDirection, NKCODE_BUTTON_2, "Cross"); return YES;
		default: return NO;
		}
	case PPSSPPAccessibilityActionShoulders:
		switch (fingerDirection) {
		case UIAccessibilityScrollDirectionLeft:
			_lastShoulderKey = NKCODE_BUTTON_L1;
			if (_heldShoulderKey != NKCODE_BUTTON_L1) {
				TapKey(NKCODE_BUTTON_L1, DEVICE_ID_PAD_0);
			}
			return YES;
		case UIAccessibilityScrollDirectionRight:
			_lastShoulderKey = NKCODE_BUTTON_R1;
			if (_heldShoulderKey != NKCODE_BUTTON_R1) {
				TapKey(NKCODE_BUTTON_R1, DEVICE_ID_PAD_0);
			}
			return YES;
		default:
			return NO;
		}
	default:
		return NO;
	}
}

- (BOOL)accessibilityPerformEscape {
	TapKey(NKCODE_BACK);
	return YES;
}

- (BOOL)accessibilityPerformMagicTap {
	if (GetUIState() != UISTATE_INGAME) {
		return NO;
	}
	TapKey(NKCODE_BUTTON_START, DEVICE_ID_PAD_0);
	return YES;
}

@end
