/**
 * FreeRDP: A Remote Desktop Protocol Implementation
 * MacFreeRDP
 *
 * Copyright 2018 Armin Novak <armin.novak@thincast.com>
 * Copyright 2018 Thicast Technologies GmbH
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

#import "CertificateDialog.h"
#import <freerdp/client/cmdline.h>

#import <CoreGraphics/CoreGraphics.h>

@interface CertificateDialog ()

@property int result;

@end

@implementation CertificateDialog

@synthesize textCommonName;
@synthesize textFingerprint;
@synthesize textIssuer;
@synthesize textSubject;
@synthesize textMismatch;
@synthesize messageLabel;
@synthesize serverHostname;
@synthesize commonName;
@synthesize fingerprint;
@synthesize issuer;
@synthesize subject;
@synthesize hostMismatch;
@synthesize changed;
@synthesize result;

- (id)init
{
	return [super initWithWindow:nil];
}

- (IBAction)onAccept:(NSObject *)sender
{
	[NSApp stopModalWithCode:1];
}

- (IBAction)onTemporary:(NSObject *)sender
{
	[NSApp stopModalWithCode:2];
}

- (IBAction)onCancel:(NSObject *)sender
{
	[NSApp stopModalWithCode:0];
}

- (int)runModal:(NSWindow *)mainWindow
{
	(void)mainWindow;
	// This bridge runs inside Nethriva; the upstream certificate nib is not
	// part of its bundle. Use an app-modal alert so a missing parent window or
	// nib can never produce a nil-sheet crash.
	NSAlert *alert = [[NSAlert alloc] init];
	alert.alertStyle = self.changed || self.hostMismatch ? NSAlertStyleWarning :
	                                                    NSAlertStyleInformational;
	alert.messageText = self.changed ? @"Remote desktop certificate changed" :
	                                  @"Verify remote desktop certificate";
	alert.informativeText = [NSString stringWithFormat:
	    @"Server: %@\nCommon name: %@\nSubject: %@\nIssuer: %@\nFingerprint: %@%@",
	    self.serverHostname ?: @"Unknown", self.commonName ?: @"Unknown",
	    self.subject ?: @"Unknown", self.issuer ?: @"Unknown",
	    self.fingerprint ?: @"Unknown",
	    self.hostMismatch ? @"\n\nWarning: the certificate name does not match the server." : @""];
	[alert addButtonWithTitle:@"Cancel"];
	[alert addButtonWithTitle:@"Trust Once"];
	[alert addButtonWithTitle:@"Trust and Save"];
	NSInteger response = [alert runModal];
	self.result = response == NSAlertSecondButtonReturn ? 2 :
	              response == NSAlertThirdButtonReturn ? 1 : 0;
	[alert release];
	return self.result;
}

- (void)dealloc
{
	[textCommonName release];
	[textFingerprint release];
	[textIssuer release];
	[textSubject release];
	[messageLabel release];
	[serverHostname release];
	[commonName release];
	[fingerprint release];
	[issuer release];
	[subject release];
	[super dealloc];
}

@end
