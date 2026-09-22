#import <Cocoa/Cocoa.h>

#import <freerdp/client.h>
#import <freerdp/client/cmdline.h>
#import <openssl/provider.h>
#import <openssl/crypto.h>
#import <winpr/crt.h>

#import "MRDPView.h"
#import "mf_client.h"
#import "mfreerdp.h"

typedef struct
{
	rdpContext *context;
	MRDPView *view;
	int argc;
	char **argv;
} NethrivaRDPSession;

static OSSL_PROVIDER *NethrivaDefaultProvider = NULL;
static OSSL_PROVIDER *NethrivaLegacyProvider = NULL;

__attribute__((visibility("default"))) int NethrivaRDPConfigureOpenSSL(
    const char *providerDirectory)
{
    if (!providerDirectory)
        return 0;
    if (OSSL_PROVIDER_set_default_search_path(NULL, providerDirectory) != 1)
        return 0;
    if (!NethrivaDefaultProvider)
        NethrivaDefaultProvider = OSSL_PROVIDER_load(NULL, "default");
    if (!NethrivaLegacyProvider)
        NethrivaLegacyProvider = OSSL_PROVIDER_load(NULL, "legacy");
    return (NethrivaDefaultProvider && NethrivaLegacyProvider) ? 1 : 0;
}

__attribute__((visibility("default"))) void *NethrivaRDPCreateView(double width, double height)
{
	NethrivaRDPSession *session = calloc(1, sizeof(NethrivaRDPSession));
	if (!session)
		return NULL;

	session->view = [[MRDPView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
	[session->view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
	return session;
}

__attribute__((visibility("default"))) void *NethrivaRDPGetView(void *opaqueSession)
{
	NethrivaRDPSession *session = opaqueSession;
	return session ? session->view : NULL;
}

static void NethrivaRDPFreeArguments(NethrivaRDPSession *session)
{
	if (!session || !session->argv)
		return;

	for (int index = 0; index < session->argc; index++)
		free(session->argv[index]);
	free(session->argv);
	session->argv = NULL;
	session->argc = 0;
}

__attribute__((visibility("default"))) int NethrivaRDPStart(
	void *opaqueSession, int argumentCount, const char *const *arguments)
{
	NethrivaRDPSession *session = opaqueSession;
	if (!session || !session->view || argumentCount < 0)
		return -1;

	RDP_CLIENT_ENTRY_POINTS entryPoints = WINPR_C_ARRAY_INIT;
	entryPoints.Size = sizeof(RDP_CLIENT_ENTRY_POINTS);
	entryPoints.Version = RDP_CLIENT_INTERFACE_VERSION;
	if (RdpClientEntry(&entryPoints) != 0)
		return -2;

	session->context = freerdp_client_context_new(&entryPoints);
	if (!session->context)
		return -3;

	mfContext *macContext = (mfContext *)session->context;
	macContext->view = session->view;
	macContext->view_ownership = FALSE;

	session->argc = argumentCount + 1;
	session->argv = calloc((size_t)session->argc, sizeof(char *));
	if (!session->argv)
		return -4;
	session->argv[0] = _strdup("Nethriva");
	for (int index = 0; index < argumentCount; index++)
		session->argv[index + 1] = _strdup(arguments[index]);

	session->context->argc = session->argc;
	session->context->argv = session->argv;
	const int parseStatus = freerdp_client_settings_parse_command_line(
		session->context->settings, session->argc, session->argv, FALSE);
	if (parseStatus < 0)
		return parseStatus;

	return freerdp_client_start(session->context);
}

__attribute__((visibility("default"))) int NethrivaRDPIsConnected(void *opaqueSession)
{
	NethrivaRDPSession *session = opaqueSession;
	return session && session->view ? session->view.is_connected : 0;
}

// Transfers an opt-in credential candidate to the Swift host exactly once.
// Call only after the session reaches the connected state. The caller owns
// the returned C strings and must clear/free them after saving to Keychain.
__attribute__((visibility("default"))) int NethrivaRDPTakeSavedCredentials(
	void *opaqueSession, char **username, char **password, char **domain)
{
	NethrivaRDPSession *session = opaqueSession;
	if (!session || !session->view || !username || !password || !domain)
		return 0;
	*username = NULL;
	*password = NULL;
	*domain = NULL;
	@synchronized(session->view)
	{
		if (!session->view->pendingSavedUsername || !session->view->pendingSavedPassword)
			return 0;
		*username = session->view->pendingSavedUsername;
		*password = session->view->pendingSavedPassword;
		*domain = session->view->pendingSavedDomain;
		session->view->pendingSavedUsername = NULL;
		session->view->pendingSavedPassword = NULL;
		session->view->pendingSavedDomain = NULL;
	}
	return 1;
}

__attribute__((visibility("default"))) void NethrivaRDPFreeCredentialString(char *value,
                                                                              int isPassword)
{
	if (!value)
		return;
	if (isPassword)
		OPENSSL_cleanse(value, strlen(value));
	free(value);
}

__attribute__((visibility("default"))) int NethrivaRDPConnectionState(void *opaqueSession)
{
	NethrivaRDPSession *session = opaqueSession;
	if (!session || !session->context)
		return 0;
	if (session->view.is_connected)
		return 2;

	mfContext *macContext = (mfContext *)session->context;
	if (!macContext->common.thread)
		return -1;
	return WaitForSingleObject(macContext->common.thread, 0) == WAIT_OBJECT_0 ? -1 : 1;
}

__attribute__((visibility("default"))) unsigned int NethrivaRDPLastError(void *opaqueSession)
{
	NethrivaRDPSession *session = opaqueSession;
	if (!session || !session->context)
		return 0;
	return freerdp_get_last_error(session->context);
}

static UINT32 NethrivaRDPDimension(double value)
{
	UINT32 dimension = (UINT32)MAX(200.0, MIN(8192.0, value));
	return dimension & ~1U;
}

static UINT32 NethrivaRDPScale(double value)
{
	const UINT32 scale = (UINT32)value;
	return (scale == 100 || scale == 140 || scale == 180) ? scale : 100;
}

__attribute__((visibility("default"))) void NethrivaRDPResize(
	void *opaqueSession, double width, double height, double desktopWidth, double desktopHeight,
	double desktopScale)
{
	NethrivaRDPSession *session = opaqueSession;
	if (!session || !session->view || width < 1 || height < 1)
		return;

	[session->view setFrameSize:NSMakeSize(width, height)];
	[session->view setNeedsDisplay:YES];

	if (!session->context)
		return;
	mfContext *macContext = (mfContext *)session->context;
	[session->view setScrollOffset:0 y:0 w:(int)width h:(int)height];
	const UINT32 targetWidth = NethrivaRDPDimension(desktopWidth);
	const UINT32 targetHeight = NethrivaRDPDimension(desktopHeight);
	const UINT32 targetScale = NethrivaRDPScale(desktopScale);
	if (!macContext->displayControlReady || !macContext->disp ||
	    !macContext->disp->SendMonitorLayout ||
	    (macContext->lastDesktopWidth == targetWidth &&
	     macContext->lastDesktopHeight == targetHeight &&
	     macContext->lastDesktopScale == targetScale))
		return;

	DISPLAY_CONTROL_MONITOR_LAYOUT layout = WINPR_C_ARRAY_INIT;
	layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
	layout.Width = targetWidth;
	layout.Height = targetHeight;
	layout.PhysicalWidth = MAX(10U, targetWidth * 254U / 960U);
	layout.PhysicalHeight = MAX(10U, targetHeight * 254U / 960U);
	layout.Orientation = 0;
	layout.DesktopScaleFactor = targetScale;
	layout.DeviceScaleFactor = targetScale;
	if (macContext->disp->SendMonitorLayout(macContext->disp, 1, &layout) == CHANNEL_RC_OK)
	{
		macContext->lastDesktopWidth = targetWidth;
		macContext->lastDesktopHeight = targetHeight;
		macContext->lastDesktopScale = targetScale;
	}
}

__attribute__((visibility("default"))) void NethrivaRDPFocus(void *opaqueSession)
{
	NethrivaRDPSession *session = opaqueSession;
	if (session && session->view.window)
		[session->view claimKeyboardFocus];
}

__attribute__((visibility("default"))) void NethrivaRDPPaste(void *opaqueSession)
{
	NethrivaRDPSession *session = opaqueSession;
	if (session && session->view)
		[session->view pasteFromMacClipboard];
}

__attribute__((visibility("default"))) int NethrivaRDPPasteFiles(
	void *opaqueSession, int pathCount, const char *const *paths)
{
	NethrivaRDPSession *session = opaqueSession;
	if (!session || !session->view || pathCount < 1 || !paths)
		return 0;

	NSMutableArray<NSString *> *filePaths = [NSMutableArray arrayWithCapacity:(NSUInteger)pathCount];
	for (int index = 0; index < pathCount; index++)
	{
		if (!paths[index])
			continue;
		NSString *path = [NSString stringWithUTF8String:paths[index]];
		if (path.length > 0)
			[filePaths addObject:path];
	}
	return [session->view pasteFilesAtPaths:filePaths] ? 1 : 0;
}

__attribute__((visibility("default"))) int NethrivaRDPPasteFilesAtPoint(
	void *opaqueSession, int pathCount, const char *const *paths, double x, double y)
{
	NethrivaRDPSession *session = opaqueSession;
	if (!session || !session->view || pathCount < 1 || !paths)
		return 0;

	NSMutableArray<NSString *> *filePaths = [NSMutableArray arrayWithCapacity:(NSUInteger)pathCount];
	for (int index = 0; index < pathCount; index++)
	{
		if (!paths[index])
			continue;
		NSString *path = [NSString stringWithUTF8String:paths[index]];
		if (path.length > 0)
			[filePaths addObject:path];
	}
	return [session->view pasteFilesAtPaths:filePaths activateX:x y:y] ? 1 : 0;
}

__attribute__((visibility("default"))) void NethrivaRDPDestroy(void *opaqueSession)
{
	NethrivaRDPSession *session = opaqueSession;
	if (!session)
		return;

	if (session->context)
	{
		freerdp_client_stop(session->context);
		[session->view releaseResources];
		freerdp_client_context_free(session->context);
		session->context = NULL;
	}
	[session->view removeFromSuperview];
	[session->view release];
	NethrivaRDPFreeArguments(session);
	free(session);
}
