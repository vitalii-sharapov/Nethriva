/**
 * FreeRDP: A Remote Desktop Protocol Implementation
 *
 * Copyright 2014 Marc-Andre Moreau <marcandre.moreau@gmail.com>
 * Copyright 2015 Thincast Technologies GmbH
 * Copyright 2015 DI (FH) Martin Haimberger <martin.haimberger@thincast.com>
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

#import "Clipboard.h"
#import "MRDPView.h"

#include <freerdp/client/client_cliprdr_file.h>
#include <freerdp/utils/cliprdr_utils.h>

static mfContext *mac_cliprdr_context(CliprdrClientContext *cliprdr)
{
	if (!cliprdr || !cliprdr->custom)
		return nullptr;
	CliprdrFileContext *file = (CliprdrFileContext *)cliprdr->custom;
	return (mfContext *)cliprdr_file_context_get_context(file);
}

int mac_cliprdr_send_client_format_list(CliprdrClientContext *cliprdr)
{
	UINT32 formatId;
	UINT32 numFormats;
	UINT32 *pFormatIds;
	const char *formatName;
	CLIPRDR_FORMAT *formats;
	CLIPRDR_FORMAT_LIST formatList = WINPR_C_ARRAY_INIT;

	WINPR_ASSERT(cliprdr);
	mfContext *mfc = mac_cliprdr_context(cliprdr);
	WINPR_ASSERT(mfc);

	pFormatIds = nullptr;
	numFormats = ClipboardGetFormatIds(mfc->clipboard, &pFormatIds);

	formats = (CLIPRDR_FORMAT *)calloc(numFormats, sizeof(CLIPRDR_FORMAT));

	if (!formats)
		return -1;

	for (UINT32 index = 0; index < numFormats; index++)
	{
		formatId = pFormatIds[index];
		formatName = ClipboardGetFormatName(mfc->clipboard, formatId);

		formats[index].formatId = formatId;
		formats[index].formatName = nullptr;

		if ((formatId > CF_MAX) && formatName)
			formats[index].formatName = _strdup(formatName);
	}

	formatList.common.msgFlags = 0;
	formatList.numFormats = numFormats;
	formatList.formats = formats;
	formatList.common.msgType = CB_FORMAT_LIST;
	(void)cliprdr_file_context_notify_new_client_format_list(mfc->clipboardFile);

	mfc->cliprdr->ClientFormatList(mfc->cliprdr, &formatList);

	for (UINT32 index = 0; index < numFormats; index++)
	{
		free(formats[index].formatName);
	}

	free(pFormatIds);
	free(formats);

	return 1;
}

static int mac_cliprdr_send_client_format_list_response(CliprdrClientContext *cliprdr, BOOL status)
{
	CLIPRDR_FORMAT_LIST_RESPONSE formatListResponse;

	formatListResponse.common.msgType = CB_FORMAT_LIST_RESPONSE;
	formatListResponse.common.msgFlags = status ? CB_RESPONSE_OK : CB_RESPONSE_FAIL;
	formatListResponse.common.dataLen = 0;

	cliprdr->ClientFormatListResponse(cliprdr, &formatListResponse);

	return 1;
}

static UINT mac_cliprdr_send_client_format_data_request(CliprdrClientContext *cliprdr,
                                                        UINT32 formatId)
{
	CLIPRDR_FORMAT_DATA_REQUEST formatDataRequest = WINPR_C_ARRAY_INIT;
	WINPR_ASSERT(cliprdr);

	if (formatId == 0)
		return CHANNEL_RC_OK;

	mfContext *mfc = mac_cliprdr_context(cliprdr);
	WINPR_ASSERT(mfc);

	formatDataRequest.common.msgType = CB_FORMAT_DATA_REQUEST;
	formatDataRequest.common.msgFlags = 0;

	formatDataRequest.requestedFormatId = formatId;
	mfc->requestedFormatId = formatId;
	(void)ResetEvent(mfc->clipboardRequestEvent);

	return cliprdr->ClientFormatDataRequest(cliprdr, &formatDataRequest);
}

static int mac_cliprdr_send_client_capabilities(CliprdrClientContext *cliprdr)
{
	CLIPRDR_CAPABILITIES capabilities;
	CLIPRDR_GENERAL_CAPABILITY_SET generalCapabilitySet;

	capabilities.cCapabilitiesSets = 1;
	capabilities.capabilitySets = (CLIPRDR_CAPABILITY_SET *)&(generalCapabilitySet);

	generalCapabilitySet.capabilitySetType = CB_CAPSTYPE_GENERAL;
	generalCapabilitySet.capabilitySetLength = 12;

	generalCapabilitySet.version = CB_CAPS_VERSION_2;
	mfContext *mfc = mac_cliprdr_context(cliprdr);
	WINPR_ASSERT(mfc);
	generalCapabilitySet.generalFlags =
	    CB_USE_LONG_FORMAT_NAMES | cliprdr_file_context_current_flags(mfc->clipboardFile);

	cliprdr->ClientCapabilities(cliprdr, &capabilities);

	return 1;
}

/**
 * Function description
 *
 * @return 0 on success, otherwise a Win32 error code
 */
static UINT mac_cliprdr_monitor_ready(CliprdrClientContext *cliprdr,
                                      const CLIPRDR_MONITOR_READY *monitorReady)
{
	mfContext *mfc = mac_cliprdr_context(cliprdr);

	mfc->clipboardSync = TRUE;
	mac_cliprdr_send_client_capabilities(cliprdr);
	mac_cliprdr_send_client_format_list(cliprdr);

	return CHANNEL_RC_OK;
}

/**
 * Function description
 *
 * @return 0 on success, otherwise a Win32 error code
 */
static UINT mac_cliprdr_server_capabilities(CliprdrClientContext *cliprdr,
                                            const CLIPRDR_CAPABILITIES *capabilities)
{
	CLIPRDR_CAPABILITY_SET *capabilitySet;
	mfContext *mfc = mac_cliprdr_context(cliprdr);
	WINPR_ASSERT(mfc);
	(void)cliprdr_file_context_remote_set_flags(mfc->clipboardFile, 0);

	for (UINT32 index = 0; index < capabilities->cCapabilitiesSets; index++)
	{
		capabilitySet = &(capabilities->capabilitySets[index]);

		if ((capabilitySet->capabilitySetType == CB_CAPSTYPE_GENERAL) &&
		    (capabilitySet->capabilitySetLength >= CB_CAPSTYPE_GENERAL_LEN))
		{
			CLIPRDR_GENERAL_CAPABILITY_SET *generalCapabilitySet =
			    (CLIPRDR_GENERAL_CAPABILITY_SET *)capabilitySet;

			mfc->clipboardCapabilities = generalCapabilitySet->generalFlags;
			(void)cliprdr_file_context_remote_set_flags(mfc->clipboardFile,
			                                            generalCapabilitySet->generalFlags);
			break;
		}
	}

	return CHANNEL_RC_OK;
}

/**
 * Function description
 *
 * @return 0 on success, otherwise a Win32 error code
 */
static UINT mac_cliprdr_server_format_list(CliprdrClientContext *cliprdr,
                                           const CLIPRDR_FORMAT_LIST *formatList)
{
	WINPR_ASSERT(cliprdr);

	mfContext *mfc = mac_cliprdr_context(cliprdr);
	WINPR_ASSERT(mfc);

	if (mfc->serverFormats)
	{
		for (UINT32 index = 0; index < mfc->numServerFormats; index++)
		{
			free(mfc->serverFormats[index].formatName);
		}

		free(mfc->serverFormats);
		mfc->serverFormats = nullptr;
		mfc->numServerFormats = 0;
	}

	if (formatList->numFormats < 1)
		return CHANNEL_RC_OK;

	mfc->numServerFormats = formatList->numFormats;
	mfc->serverFormats = (CLIPRDR_FORMAT *)calloc(mfc->numServerFormats, sizeof(CLIPRDR_FORMAT));

	if (!mfc->serverFormats)
		return CHANNEL_RC_NO_MEMORY;

	for (UINT32 index = 0; index < mfc->numServerFormats; index++)
	{
		mfc->serverFormats[index].formatId = formatList->formats[index].formatId;
		mfc->serverFormats[index].formatName = nullptr;

		if (formatList->formats[index].formatName)
			mfc->serverFormats[index].formatName = _strdup(formatList->formats[index].formatName);
	}

	mac_cliprdr_send_client_format_list_response(cliprdr, TRUE);
	(void)cliprdr_file_context_notify_new_server_format_list(mfc->clipboardFile);

	uint32_t formatId = 0;
	for (UINT32 index = 0; index < mfc->numServerFormats; index++)
	{
		const CLIPRDR_FORMAT *format = &(mfc->serverFormats[index]);

		if (format->formatId == CF_UNICODETEXT)
			formatId = format->formatId;
		else if (format->formatId == CF_OEMTEXT)
		{
			if (formatId == 0)
				formatId = CF_OEMTEXT;
		}
		else if (format->formatId == CF_TEXT)
		{
			if (formatId == 0)
				formatId = CF_TEXT;
		}
	}

	return mac_cliprdr_send_client_format_data_request(cliprdr, formatId);
}

/**
 * Function description
 *
 * @return 0 on success, otherwise a Win32 error code
 */
static UINT
mac_cliprdr_server_format_list_response(CliprdrClientContext *cliprdr,
                                        const CLIPRDR_FORMAT_LIST_RESPONSE *formatListResponse)
{
	mfContext *mfc = mac_cliprdr_context(cliprdr);
	if (mfc && mfc->pendingFilePaste)
	{
		mfc->pendingFilePaste = FALSE;
		if ((formatListResponse->common.msgFlags & CB_RESPONSE_FAIL) == 0)
		{
			MRDPView *view = (MRDPView *)mfc->view;
			dispatch_async(dispatch_get_main_queue(), ^{
				[view sendWindowsPasteShortcut];
			});
		}
	}
	return CHANNEL_RC_OK;
}

/**
 * Function description
 *
 * @return 0 on success, otherwise a Win32 error code
 */
static UINT
mac_cliprdr_server_lock_clipboard_data(CliprdrClientContext *cliprdr,
                                       const CLIPRDR_LOCK_CLIPBOARD_DATA *lockClipboardData)
{
	return CHANNEL_RC_OK;
}

/**
 * Function description
 *
 * @return 0 on success, otherwise a Win32 error code
 */
static UINT
mac_cliprdr_server_unlock_clipboard_data(CliprdrClientContext *cliprdr,
                                         const CLIPRDR_UNLOCK_CLIPBOARD_DATA *unlockClipboardData)
{
	return CHANNEL_RC_OK;
}

/**
 * Function description
 *
 * @return 0 on success, otherwise a Win32 error code
 */
static UINT
mac_cliprdr_server_format_data_request(CliprdrClientContext *cliprdr,
                                       const CLIPRDR_FORMAT_DATA_REQUEST *formatDataRequest)
{
	BYTE *data;
	UINT32 size = 0;
	UINT32 formatId;
	CLIPRDR_FORMAT_DATA_RESPONSE response = WINPR_C_ARRAY_INIT;

	WINPR_ASSERT(cliprdr);

	mfContext *mfc = mac_cliprdr_context(cliprdr);
	WINPR_ASSERT(mfc);

	formatId = formatDataRequest->requestedFormatId;
	data = (BYTE *)ClipboardGetData(mfc->clipboard, formatId, &size);
	const UINT32 fileFormatId =
	    ClipboardGetFormatId(mfc->clipboard, "FileGroupDescriptorW");
	if (data && fileFormatId != 0 && formatId == fileFormatId)
	{
		BYTE *serialized = nullptr;
		UINT32 serializedSize = 0;
		const UINT32 flags = cliprdr_file_context_remote_get_flags(mfc->clipboardFile);
		const UINT error = cliprdr_serialize_file_list_ex(
		    flags, (const FILEDESCRIPTORW *)data, size / sizeof(FILEDESCRIPTORW),
		    &serialized, &serializedSize);
		free(data);
		data = nullptr;
		if (error == CHANNEL_RC_OK)
		{
			data = serialized;
			size = serializedSize;
		}
	}

	response.common.msgFlags = CB_RESPONSE_OK;
	response.common.dataLen = size;
	response.requestedFormatData = data;

	if (!data)
	{
		response.common.msgFlags = CB_RESPONSE_FAIL;
		response.common.dataLen = 0;
		response.requestedFormatData = nullptr;
	}

	cliprdr->ClientFormatDataResponse(cliprdr, &response);

	free(data);

	return CHANNEL_RC_OK;
}

/**
 * Function description
 *
 * @return 0 on success, otherwise a Win32 error code
 */
static UINT
mac_cliprdr_server_format_data_response(CliprdrClientContext *cliprdr,
                                        const CLIPRDR_FORMAT_DATA_RESPONSE *formatDataResponse)
{
	UINT32 formatId;
	CLIPRDR_FORMAT *format = nullptr;
	mfContext *mfc = mac_cliprdr_context(cliprdr);
	MRDPView *view = (MRDPView *)mfc->view;

	if (formatDataResponse->common.msgFlags & CB_RESPONSE_FAIL)
	{
		(void)SetEvent(mfc->clipboardRequestEvent);
		return ERROR_INTERNAL_ERROR;
	}

	for (UINT32 index = 0; index < mfc->numServerFormats; index++)
	{
		if (mfc->requestedFormatId == mfc->serverFormats[index].formatId)
			format = &(mfc->serverFormats[index]);
	}

	if (!format)
	{
		(void)SetEvent(mfc->clipboardRequestEvent);
		return ERROR_INTERNAL_ERROR;
	}

	if (format->formatName)
		formatId = ClipboardRegisterFormat(mfc->clipboard, format->formatName);
	else
		formatId = format->formatId;

	const size_t size = formatDataResponse->common.dataLen;

	ClipboardSetData(mfc->clipboard, formatId, formatDataResponse->requestedFormatData, size);

	(void)SetEvent(mfc->clipboardRequestEvent);

	if ((formatId == CF_TEXT) || (formatId == CF_OEMTEXT) || (formatId == CF_UNICODETEXT))
	{
		NSString *str = nil;
		if (formatId == CF_UNICODETEXT)
		{
			size_t textSize = size;
			while (textSize >= sizeof(uint16_t))
			{
				const BYTE *tail = formatDataResponse->requestedFormatData + textSize - sizeof(uint16_t);
				if (tail[0] != 0 || tail[1] != 0)
					break;
				textSize -= sizeof(uint16_t);
			}
			str = [[[NSString alloc] initWithBytes:formatDataResponse->requestedFormatData
			                              length:textSize
			                            encoding:NSUTF16LittleEndianStringEncoding] autorelease];
		}
		else
		{
			formatId = ClipboardRegisterFormat(mfc->clipboard, "text/plain");
			UINT32 dstSize = 0;
			char *data = ClipboardGetData(mfc->clipboard, formatId, &dstSize);
			if (data)
			{
				dstSize = (UINT32)strnlen(data, dstSize);
				str = [[[NSString alloc] initWithBytes:data
				                              length:dstSize
				                            encoding:NSUTF8StringEncoding] autorelease];
				free(data);
			}
		}

		if (str)
		{
			dispatch_async(dispatch_get_main_queue(), ^{
				NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
				[pasteboard clearContents];
				[pasteboard setString:str forType:NSPasteboardTypeString];
				view->pasteboard_changecount = (int)[pasteboard changeCount];
			});
		}
	}

	return CHANNEL_RC_OK;
}

/**
 * Function description
 *
 * @return 0 on success, otherwise a Win32 error code
 */
void mac_cliprdr_init(mfContext *mfc, CliprdrClientContext *cliprdr)
{
	mfc->cliprdr = cliprdr;

	mfc->clipboard = ClipboardCreate();
	mfc->clipboardRequestEvent = CreateEvent(nullptr, TRUE, FALSE, nullptr);
	mfc->clipboardFile = cliprdr_file_context_new(mfc);
	WINPR_ASSERT(mfc->clipboardFile);
	(void)cliprdr_file_context_set_locally_available(mfc->clipboardFile, TRUE);
	WINPR_ASSERT(cliprdr_file_context_init(mfc->clipboardFile, cliprdr));

	cliprdr->MonitorReady = mac_cliprdr_monitor_ready;
	cliprdr->ServerCapabilities = mac_cliprdr_server_capabilities;
	cliprdr->ServerFormatList = mac_cliprdr_server_format_list;
	cliprdr->ServerFormatListResponse = mac_cliprdr_server_format_list_response;
	cliprdr->ServerFormatDataRequest = mac_cliprdr_server_format_data_request;
	cliprdr->ServerFormatDataResponse = mac_cliprdr_server_format_data_response;
}

void mac_cliprdr_uninit(mfContext *mfc, CliprdrClientContext *cliprdr)
{
	(void)cliprdr_file_context_uninit(mfc->clipboardFile, cliprdr);
	cliprdr->custom = nullptr;
	mfc->cliprdr = nullptr;

	cliprdr_file_context_free(mfc->clipboardFile);
	mfc->clipboardFile = nullptr;
	ClipboardDestroy(mfc->clipboard);
	(void)CloseHandle(mfc->clipboardRequestEvent);
}
