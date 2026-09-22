/**
 * FreeRDP: A Remote Desktop Protocol Implementation
 * MacFreeRDP
 *
 * Copyright 2013 Christian Hofstaedtler
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "PasswordDialog.h"
#import <freerdp/client/cmdline.h>

#import <CoreGraphics/CoreGraphics.h>

@interface PasswordDialog ()

@property BOOL modalCode;
@property BOOL saveCredentials;

@end

@implementation PasswordDialog

@synthesize usernameText;
@synthesize passwordText;
@synthesize messageLabel;
@synthesize serverHostname;
@synthesize username;
@synthesize password;
@synthesize domain;
@synthesize modalCode;
@synthesize saveCredentials;
@synthesize allowsSaving;

- (id)init
{
	return [super initWithWindow:nil];
}

- (void)captureCredentials
{
	char *submittedUser = nullptr;
	char *submittedDomain = nullptr;

	if (freerdp_parse_username(
	        [self.usernameText.stringValue cStringUsingEncoding:NSUTF8StringEncoding],
	        &submittedUser, &submittedDomain))
	{
		if (submittedUser)
			self.username = [NSString stringWithCString:submittedUser
			                                   encoding:NSUTF8StringEncoding];
		if (submittedDomain)
			self.domain = [NSString stringWithCString:submittedDomain
			                                 encoding:NSUTF8StringEncoding];
	}
	else
	{
		self.username = self.usernameText.stringValue;
	}

	self.password = self.passwordText.stringValue;
	free(submittedUser);
	free(submittedDomain);
}

- (IBAction)onOK:(NSObject *)sender
{
	[self captureCredentials];
	[NSApp stopModalWithCode:TRUE];
}

- (IBAction)onCancel:(NSObject *)sender
{
	[NSApp stopModalWithCode:FALSE];
}

- (BOOL)runModal:(NSWindow *)mainWindow
{
	(void)mainWindow;
	// The bridge is hosted in Nethriva, not MacFreeRDP.app, so its original
	// PasswordDialog.nib is unavailable. A nib-backed sheet has a nil window
	// here and raises "cannot run nil sheetWindow" during authentication.
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = @"Remote Desktop Authentication";
	alert.informativeText = [NSString stringWithFormat:@"Enter credentials for %@.",
	                         self.serverHostname ?: @"this server"];
	[alert addButtonWithTitle:@"Connect"];
	[alert addButtonWithTitle:@"Cancel"];

	const CGFloat saveRowHeight = self.allowsSaving ? 32 : 0;
	NSView *fields = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 360, 92 + saveRowHeight)];
	NSTextField *userLabel =
	    [[NSTextField alloc] initWithFrame:NSMakeRect(0, 60 + saveRowHeight, 85, 22)];
	userLabel.stringValue = @"Username:";
	userLabel.bezeled = NO;
	userLabel.drawsBackground = NO;
	userLabel.editable = NO;
	userLabel.selectable = NO;
	[fields addSubview:userLabel];
	[userLabel release];

	NSTextField *userField =
	    [[NSTextField alloc] initWithFrame:NSMakeRect(88, 58 + saveRowHeight, 272, 26)];
	if (self.domain.length > 0)
		userField.stringValue = [NSString stringWithFormat:@"%@\\%@", self.domain,
		                         self.username ?: @""];
	else
		userField.stringValue = self.username ?: @"";
	[fields addSubview:userField];
	self.usernameText = userField;
	[userField release];

	NSTextField *passwordLabel =
	    [[NSTextField alloc] initWithFrame:NSMakeRect(0, 22 + saveRowHeight, 85, 22)];
	passwordLabel.stringValue = @"Password:";
	passwordLabel.bezeled = NO;
	passwordLabel.drawsBackground = NO;
	passwordLabel.editable = NO;
	passwordLabel.selectable = NO;
	[fields addSubview:passwordLabel];
	[passwordLabel release];

	NSSecureTextField *passwordField =
	    [[NSSecureTextField alloc] initWithFrame:NSMakeRect(88, 20 + saveRowHeight, 272, 26)];
	passwordField.stringValue = self.password ?: @"";
	[fields addSubview:passwordField];
	self.passwordText = passwordField;
	[passwordField release];
	NSButton *saveCheckbox = nil;
	if (self.allowsSaving)
	{
		saveCheckbox = [NSButton checkboxWithTitle:@"Save credentials in Keychain"
		                                        target:nil action:nil];
		saveCheckbox.frame = NSMakeRect(88, 8, 272, 26);
		saveCheckbox.state = NSControlStateValueOff;
		[fields addSubview:saveCheckbox];
	}
	alert.accessoryView = fields;
	[fields release];
	[alert.window makeFirstResponder:self.username.length > 0 ? passwordField : userField];

	self.modalCode = [alert runModal] == NSAlertFirstButtonReturn;
	if (self.modalCode)
	{
		self.saveCredentials = saveCheckbox && saveCheckbox.state == NSControlStateValueOn;
		[self captureCredentials];
	}
	[alert release];
	return self.modalCode;
}

- (void)dealloc
{
	[usernameText release];
	[passwordText release];
	[messageLabel release];
	[serverHostname release];
	[username release];
	[password release];
	[domain release];
	[super dealloc];
}

@end
